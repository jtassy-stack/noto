import Foundation
import SwiftData

/// Syncs École Directe data into SwiftData models.
/// Mirrors the ENTSyncService wipe-and-insert + SyncGate pattern exactly.
@MainActor
final class EcoleDirecteSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync for an École Directe child: grades, schedule, homework, messages.
    /// Fetches all data BEFORE deleting anything — partial failure keeps old data intact.
    func sync(child: Child, client: EcoleDirecteClient) async throws {
        guard let eleveIdStr = child.entChildId, let eleveId = Int(eleveIdStr) else {
            throw EcoleDirecteError.invalidResponse("eleveId manquant pour \(child.firstName)")
        }
        let familleId = child.edAccountId.flatMap(Int.init)

        var grades: [EDGrade] = []
        var lessons: [EDLesson] = []
        var homework: [EDHomework] = []
        var messages: [EDMessage] = []
        var fetchErrors: [String] = []

        do { grades = try await client.fetchGrades(eleveId: eleveId) }
        catch { fetchErrors.append("notes: \(error.localizedDescription)") }

        // The timetable is fetched from −42 days (3.8) so the past lesson days
        // can be listed; only the usual −28 days go to `ScheduleEntry`.
        let now = Date()
        let calendar = Calendar.current
        let fourWeeksAgo = now.addingTimeInterval(-28 * 86_400)
        var allLessons: [EDLesson] = []
        do {
            let lookback = calendar.date(byAdding: .day, value: -LessonContentStore.lookbackDays,
                                         to: calendar.startOfDay(for: now))!
            let twoWeeksAhead = now.addingTimeInterval(14 * 86_400)
            allLessons = try await client.fetchSchedule(eleveId: eleveId, from: lookback, to: twoWeeksAhead)
            lessons = allLessons.filter { $0.date >= fourWeeksAgo }
        }
        catch { fetchErrors.append("emploi du temps: \(error.localizedDescription)") }

        do { homework = try await client.fetchHomework(eleveId: eleveId) }
        catch { fetchErrors.append("devoirs: \(error.localizedDescription)") }

        if let familleId {
            do { messages = try await client.fetchMessages(familleId: familleId) }
            catch { fetchErrors.append("messages: \(error.localizedDescription)") }
        }

        // 3.8: cahier de textes per day. Quiet (never in `fetchErrors` nor in
        // `hasData`), read-only (`verbe=get`), at most every 24 h.
        let seances = await fetchSeances(client: client, eleveId: eleveId, lessons: allLessons, child: child,
                                         now: now, calendar: calendar)

        let hasData = !grades.isEmpty || !lessons.isEmpty || !homework.isEmpty || !messages.isEmpty
        switch EDSyncGate.decide(hasData: hasData, fetchErrors: fetchErrors) {
        case .proceed:
            break
        case .preserve:
            NSLog("[noto][warn] ED sync for %@ returned empty payload — preserving local data", child.firstName)
            recordSeances(seances, for: child, now: now, calendar: calendar)
            LessonContentStore.recordSync(of: child, in: modelContext)
            child.markSynced()
            try modelContext.save()
            return
        case .fail(let detail):
            throw EcoleDirecteError.invalidResponse("Aucune donnée récupérée (\(detail))")
        }

        // Wipe and insert
        for grade in child.grades { modelContext.delete(grade) }
        for entry in child.schedule { modelContext.delete(entry) }
        LessonContentStore.captureHomework(of: child, in: modelContext)   // 3.8: keep before the wipe
        for hw in child.homework { modelContext.delete(hw) }
        for msg in child.messages { modelContext.delete(msg) }

        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(homework, for: child)
        syncMessages(messages, for: child)
        recordSeances(seances, for: child, now: now, calendar: calendar)
        LessonContentStore.recordSync(of: child, in: modelContext)
        child.markSynced()

        try modelContext.save()
        NSLog("[noto] ED sync OK for %@ — %d notes, %d cours, %d devoirs, %d messages",
              child.firstName, grades.count, lessons.count, homework.count, messages.count)
    }

    // MARK: - Cahier de textes (programme position, 3.8)

    /// Days to fetch: past non-cancelled lesson days in [today − 42, today],
    /// most recent first, at most this many.
    static let maxSeanceDays = 30
    /// Days older than this whose seance is already stored are not re-fetched
    /// (the past is immutable).
    static let refetchRecentDays = 7

    /// Result of the per-day loop. `complete` is false when it stopped early
    /// (token expired) or was skipped; `lessonContentsFetchedAt` is only
    /// stamped for a complete run.
    struct SeanceFetch {
        var seances: [EDSeance] = []
        var complete = false
        var ran = false
    }

    /// Distinct `startOfDay`s of the past, non-cancelled lessons in the
    /// window, most recent first, capped at `maxSeanceDays`. Days older than
    /// `refetchRecentDays` already in `storedDays` are skipped.
    static func seanceDays(lessons: [EDLesson], storedDays: Set<Date>, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -LessonContentStore.lookbackDays, to: today) ?? today
        let recent = calendar.date(byAdding: .day, value: -refetchRecentDays, to: today) ?? today
        let days = Set(lessons.filter { !$0.cancelled && $0.date <= now }.map { calendar.startOfDay(for: $0.date) })
            .filter { $0 >= start && $0 <= today }
            .filter { $0 >= recent || !storedDays.contains($0) }
        return Array(days.sorted(by: >).prefix(maxSeanceDays))
    }

    private func fetchSeances(client: EcoleDirecteClient, eleveId: Int, lessons: [EDLesson], child: Child,
                              now: Date, calendar: Calendar) async -> SeanceFetch {
        var result = SeanceFetch()
        guard !LessonContentStore.isFresh(child, now: now) else { return result }
        // Days already stored past their own end (immutable past).
        let storedDays = Set(child.lessonContents
            .filter { !$0.isDeleted && $0.source == .ecoleDirecteSeance }
            .compactMap { row -> Date? in
                let day = calendar.startOfDay(for: row.date)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return row.fetchedAt >= dayEnd ? day : nil
            })
        let days = Self.seanceDays(lessons: lessons, storedDays: storedDays, now: now, calendar: calendar)
        result.ran = true
        result.complete = true
        for (index, day) in days.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }   // one at a time, 300 ms apart
            do {
                result.seances += try await client.fetchDay(eleveId: eleveId, date: day)
            } catch EcoleDirecteError.tokenExpired {
                NSLog("[noto][warn] ED cahier de textes: token expired after %d day(s) — keeping what was fetched", index)
                result.complete = false
                break
            } catch {
                NSLog("[noto][warn] ED cahier de textes day fetch failed: %@", error.localizedDescription)
            }
        }
        return result
    }

    private func recordSeances(_ fetch: SeanceFetch, for child: Child, now: Date, calendar: Calendar) {
        guard fetch.ran else { return }
        var incoming: [LessonContentStore.Incoming] = []
        for seance in fetch.seances {
            if !seance.seanceText.isEmpty {
                incoming.append(.init(subject: seance.subject, date: seance.date, title: "", text: seance.seanceText,
                                      source: .ecoleDirecteSeance, externalID: seance.id))
            }
            if let homework = seance.homeworkText {
                incoming.append(.init(subject: seance.subject, date: seance.date, title: "", text: homework,
                                      source: .homework, externalID: seance.id))
            }
        }
        LessonContentStore.upsert(incoming, for: child, in: modelContext, calendar: calendar, now: now)
        if fetch.complete { child.lessonContentsFetchedAt = now }
    }

    // MARK: - Private

    private func syncGrades(_ edGrades: [EDGrade], for child: Child) {
        for eg in edGrades {
            // Parse raw value without normalizing — Grade.normalizedValue handles /20 conversion
            guard let value = parseGradeValue(eg.rawValue) else { continue }
            let grade = Grade(
                subject: eg.subject,
                value: value,
                outOf: eg.outOf,
                coefficient: eg.coefficient,
                date: eg.date
            )
            if let avg = eg.classAverage { grade.classAverage = avg }
            grade.child = child
            modelContext.insert(grade)
        }
    }

    private func syncSchedule(_ lessons: [EDLesson], for child: Child) {
        let cal = Calendar.current
        for lesson in lessons {
            // Compute absolute end date from the date + "HH:MM" end time string
            let endDate: Date
            let parts = lesson.endTime.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2,
               let end = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: lesson.date) {
                endDate = end
            } else {
                endDate = lesson.date.addingTimeInterval(3600)   // 1h fallback
            }
            let entry = ScheduleEntry(subject: lesson.subject, start: lesson.date, end: endDate, cancelled: lesson.cancelled)
            entry.room = lesson.room
            entry.teacher = lesson.teacher
            entry.child = child
            modelContext.insert(entry)
        }
    }

    private func syncHomework(_ edHomework: [EDHomework], for child: Child) {
        for hw in edHomework {
            let homework = Homework(
                subject: hw.subject,
                description: hw.description,
                dueDate: hw.dueDate
            )
            homework.child = child
            modelContext.insert(homework)
        }
    }

    private func syncMessages(_ edMessages: [EDMessage], for child: Child) {
        for em in edMessages {
            let msg = Message(
                sender: em.from,
                subject: em.subject,
                body: em.body,
                date: em.date,
                source: .ent       // reuses .ent source — no new MessageSource case needed
            )
            msg.read = em.read
            msg.child = child
            modelContext.insert(msg)
        }
    }
}

// MARK: - Sync gate (same pattern as ENTSyncGate)

enum EDSyncGate {
    enum Decision: Equatable {
        case proceed
        case preserve
        case fail(String)
    }

    static func decide(hasData: Bool, fetchErrors: [String]) -> Decision {
        if hasData { return .proceed }
        if !fetchErrors.isEmpty { return .fail(fetchErrors.joined(separator: ", ")) }
        return .preserve
    }
}
