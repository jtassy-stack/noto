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

        do {
            let now = Date()
            let fourWeeksAgo = now.addingTimeInterval(-28 * 86_400)
            let twoWeeksAhead = now.addingTimeInterval(14 * 86_400)
            lessons = try await client.fetchSchedule(eleveId: eleveId, from: fourWeeksAgo, to: twoWeeksAhead)
        }
        catch { fetchErrors.append("emploi du temps: \(error.localizedDescription)") }

        do { homework = try await client.fetchHomework(eleveId: eleveId) }
        catch { fetchErrors.append("devoirs: \(error.localizedDescription)") }

        if let familleId {
            do { messages = try await client.fetchMessages(familleId: familleId) }
            catch { fetchErrors.append("messages: \(error.localizedDescription)") }
        }

        let hasData = !grades.isEmpty || !lessons.isEmpty || !homework.isEmpty
        switch EDSyncGate.decide(hasData: hasData, fetchErrors: fetchErrors) {
        case .proceed:
            break
        case .preserve:
            NSLog("[noto][warn] ED sync for %@ returned empty payload — preserving local data", child.firstName)
            return
        case .fail(let detail):
            throw EcoleDirecteError.invalidResponse("Aucune donnée récupérée (\(detail))")
        }

        // Wipe and insert
        for grade in child.grades { modelContext.delete(grade) }
        for entry in child.schedule { modelContext.delete(entry) }
        for hw in child.homework { modelContext.delete(hw) }
        for msg in child.messages { modelContext.delete(msg) }

        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(homework, for: child)
        syncMessages(messages, for: child)

        try modelContext.save()
        NSLog("[noto] ED sync OK for %@ — %d notes, %d cours, %d devoirs, %d messages",
              child.firstName, grades.count, lessons.count, homework.count, messages.count)
    }

    // MARK: - Private

    private func syncGrades(_ edGrades: [EDGrade], for child: Child) {
        for eg in edGrades {
            guard let value = parseGradeValue(eg.rawValue, outOf: eg.outOf) else { continue }
            let grade = Grade(
                subject: eg.subject,
                value: value,
                outOf: 20,
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
