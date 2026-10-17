import Foundation
import SwiftData

/// Syncs Pronote data into SwiftData models.
/// Uses PawnoteBridge (JSCore) for the Pronote protocol.
@MainActor
final class PronoteSyncService {
    private let modelContext: ModelContext
    /// Labels of categories that failed during the most recent `sync()` call.
    /// Accumulates across endpoints so callers see every failure, not just the last one.
    var failedCategories: [String] = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync using PawnoteBridge (pawnote via JavaScriptCore).
    func sync(child: Child, bridge: PawnoteBridge, childIndex: Int) async {
        NSLog("[noto] Starting sync for \(child.firstName) (index \(childIndex))")
        failedCategories = []

        bridge.setActiveChild(index: childIndex)

        let today = Date.now
        let calendar = Calendar.current
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!
        let twoWeeks = calendar.date(byAdding: .day, value: 14, to: today)!
        // Programme position (3.8): cahier de textes + past homework window.
        let lookback = calendar.date(byAdding: .day, value: -LessonContentStore.lookbackDays, to: today)!
        let lessonFetchDue = !LessonContentStore.isFresh(child, now: today)

        // Fetch all four categories concurrently — they are independent network
        // calls with no shared mutable state. Results are collected into local
        // arrays here; SwiftData writes happen afterward, sequentially, on the
        // MainActor (ModelContext is not Sendable, so it must not be touched
        // from these concurrent tasks).
        async let gradesTask = fetchSafe("Grades") { try await bridge.fetchGrades() }
        async let lessonsTask = fetchSafe("Timetable") { try await bridge.fetchTimetable(from: today, to: nextWeek) }
        async let homeworkTask = fetchSafe("Homework") { try await bridge.fetchHomework(from: today, to: twoWeeks) }
        async let discussionsTask = fetchSafe("Messages") { try await bridge.fetchDiscussions() }

        // Quiet, read-only fetches (onglet 89 PageCahierDeTexte + homework
        // already past due): a failure is logged, never added to
        // `failedCategories` (no "partial sync" for a still-unverified
        // feature), and never part of `hasData`. Past homework goes to
        // `LessonContent` only, never to `Homework` (the on-screen list does
        // not change). Skipped when fetched less than 24 h ago.
        async let contentsTask = fetchQuiet("LessonContents", enabled: lessonFetchDue) {
            try await bridge.fetchLessonContents(from: lookback, to: today)
        }
        async let pastHomeworkTask = fetchQuiet("PastHomework", enabled: lessonFetchDue) {
            try await bridge.fetchHomework(from: lookback, to: today)
        }

        let (grades, lessons, homework, discussions) = await (gradesTask, lessonsTask, homeworkTask, discussionsTask)
        let (contents, pastHomework) = await (contentsTask, pastHomeworkTask)

        NSLog("[noto] Fetched: \(grades.count) grades, \(lessons.count) lessons, \(homework.count) homework, \(discussions.count) messages")

        // Guard against wiping local data when the bridge returns nothing.
        // Mirrors ENTSyncGate logic: preserve on empty-no-errors, fail on
        // errors-with-no-data, proceed only when at least one category returned
        // real rows.
        let hasData = !grades.isEmpty || !lessons.isEmpty || !homework.isEmpty || !discussions.isEmpty
        switch PronoteSyncGate.decide(hasData: hasData, failedCategories: failedCategories) {
        case .proceed:
            break
        case .preserve:
            NSLog("[noto][warn] Pronote sync for \(child.firstName) returned all-empty — preserving existing local data")
            recordLessonContents(contents: contents, pastHomework: pastHomework, upcoming: [],
                                 fetched: lessonFetchDue, for: child, now: today, calendar: calendar)
            child.markSynced()
            try? modelContext.save()
            return
        case .fail(let detail):
            NSLog("[noto][error] Pronote sync for \(child.firstName) failed with no data — aborting wipe (\(detail))")
            return
        }

        // Keep the homework about to be wiped (it may have left the window).
        LessonContentStore.captureHomework(of: child, in: modelContext, calendar: calendar, now: today)
        clearExistingData(for: child)
        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(homework, for: child)
        syncMessages(discussions, for: child)
        recordLessonContents(contents: contents, pastHomework: pastHomework, upcoming: homework,
                             fetched: lessonFetchDue, for: child, now: today, calendar: calendar)
        child.markSynced()

        try? modelContext.save()
        NSLog("[noto] Sync complete for \(child.firstName)")
    }

    // MARK: - Clear

    private func clearExistingData(for child: Child) {
        for grade in child.grades { modelContext.delete(grade) }
        for entry in child.schedule { modelContext.delete(entry) }
        for hw in child.homework { modelContext.delete(hw) }
        for msg in child.messages { modelContext.delete(msg) }
    }

    // MARK: - Grades

    private func syncGrades(_ pronoteGrades: [PronoteGrade], for child: Child) {
        for pg in pronoteGrades where pg.kind == .grade {
            guard let value = pg.value else { continue }
            let grade = Grade(
                subject: pg.subjectName,
                value: value,
                outOf: pg.outOf,
                coefficient: pg.coefficient,
                date: pg.date,
                chapter: pg.chapter
            )
            grade.comment = pg.comment
            // Normalize class stats to /20 like normalizedValue
            if let ca = pg.classAverage, pg.outOf > 0 {
                grade.classAverage = (ca / pg.outOf) * 20
            }
            if let mn = pg.classMin, pg.outOf > 0 {
                grade.classMin = (mn / pg.outOf) * 20
            }
            if let mx = pg.classMax, pg.outOf > 0 {
                grade.classMax = (mx / pg.outOf) * 20
            }
            grade.child = child
            modelContext.insert(grade)
        }
    }

    // MARK: - Schedule

    private func syncSchedule(_ lessons: [PronoteLesson], for child: Child) {
        for pl in lessons {
            guard let subject = pl.subject else { continue }
            let entry = ScheduleEntry(
                subject: subject,
                start: pl.startDate,
                end: pl.endDate,
                cancelled: pl.cancelled,
                chapter: nil
            )
            entry.teacher = pl.teacherNames.first
            entry.room = pl.classrooms.first
            entry.child = child
            modelContext.insert(entry)
        }
    }

    // MARK: - Homework

    private func syncHomework(_ assignments: [PronoteAssignment], for child: Child) {
        for pa in assignments {
            let hw = Homework(
                subject: pa.subjectName,
                description: pa.description,
                dueDate: pa.deadline
            )
            hw.done = pa.done
            hw.child = child
            modelContext.insert(hw)
        }
    }

    // MARK: - Lesson contents (programme position, 3.8)

    /// Upserts the cahier de textes contents and the homework (past + upcoming,
    /// with Pronote's teacher-tagged themes, which `syncHomework` does not
    /// keep) into `LessonContent`, then captures the fresh `Homework` rows and
    /// purges. Stamps `lessonContentsFetchedAt` only when both quiet fetches
    /// ran and succeeded. Local only: nothing here is sent anywhere.
    private func recordLessonContents(contents: [PronoteLessonContentEntry]?, pastHomework: [PronoteAssignment]?,
                                      upcoming: [PronoteAssignment], fetched: Bool, for child: Child,
                                      now: Date, calendar: Calendar) {
        var incoming: [LessonContentStore.Incoming] = []
        for entry in contents ?? [] {
            guard let date = Self.parseISO(entry.startDate) else { continue }
            for item in entry.contents ?? [] {
                incoming.append(.init(subject: entry.subject ?? "?", date: date, title: item.title ?? "",
                                      text: item.description ?? "", themes: item.themes ?? [],
                                      source: .pronoteLesson, externalID: item.id))
            }
        }
        for a in (pastHomework ?? []) + upcoming {
            incoming.append(.init(subject: a.subjectName, date: a.deadline, title: "", text: a.description,
                                  themes: a.themes, source: .homework, externalID: a.id))
        }
        LessonContentStore.upsert(incoming, for: child, in: modelContext, calendar: calendar, now: now)
        LessonContentStore.recordSync(of: child, in: modelContext, now: now, calendar: calendar)
        if fetched, contents != nil, pastHomework != nil {
            child.lessonContentsFetchedAt = now
        }
    }

    private static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: - Messages

    private func syncMessages(_ discussions: [PronoteDiscussion], for child: Child) {
        for pd in discussions {
            let msg = Message(
                sender: pd.creator ?? "Inconnu",
                subject: pd.subject,
                body: "",
                date: pd.date,
                source: .pronote
            )
            msg.read = pd.unreadCount == 0
            msg.child = child
            modelContext.insert(msg)
        }
    }

    // MARK: - Safe Fetch

    /// Like `fetchSafe`, but a failure is only logged: it never lands in
    /// `failedCategories`. Returns nil when the fetch failed or was skipped.
    private func fetchQuiet<T>(_ label: String, enabled: Bool,
                               _ fetch: () async throws -> [T]) async -> [T]? {
        guard enabled else { return nil }
        do {
            let result = try await fetch()
            NSLog("[noto] ✅ \(label) (quiet): \(result.count) items")
            return result
        } catch {
            NSLog("[noto] ⚠️ \(label) (quiet) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSafe<T>(_ label: String, _ fetch: () async throws -> [T]) async -> [T] {
        do {
            let result = try await fetch()
            NSLog("[noto] ✅ \(label): \(result.count) items")
            return result
        } catch {
            NSLog("[noto] ❌ \(label) failed: \(error)")
            failedCategories.append(label)
            return []
        }
    }
}

// MARK: - Sync decision gate

/// Mirrors `ENTSyncGate`: prevents wiping SwiftData when the Pronote
/// bridge returns empty lists (stale session, network hiccup, JSCore
/// cold-start). Split from `sync()` for testability.
enum PronoteSyncGate {
    enum Decision: Equatable {
        /// Real data returned — safe to clear local rows and insert fresh ones.
        case proceed
        /// All categories empty, no errors — treat as no-op.
        case preserve
        /// All categories empty AND at least one category failed — abort.
        case fail(String)
    }

    static func decide(hasData: Bool, failedCategories: [String]) -> Decision {
        if hasData { return .proceed }
        if !failedCategories.isEmpty { return .fail(failedCategories.joined(separator: ", ")) }
        return .preserve
    }
}
