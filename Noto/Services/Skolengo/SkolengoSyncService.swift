import Foundation
import SwiftData

/// Syncs Skolengo data into SwiftData models.
/// Mirrors EcoleDirecteSyncService's fetch-all-before-delete + gate pattern exactly.
@MainActor
final class SkolengoSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync for a Skolengo child: grades, schedule, homework, messages.
    /// Fetches all data BEFORE deleting anything — partial failure keeps old data intact.
    func sync(child: Child, client: SkolengoClient) async throws {
        guard let userId = child.skolengoUserId else {
            throw SkolengoError.invalidResponse("identifiant utilisateur manquant pour \(child.firstName)")
        }

        var grades: [SkolengoGrade] = []
        var lessons: [SkolengoLesson] = []
        var homework: [SkolengoHomework] = []
        var messages: [SkolengoMessage] = []
        var fetchErrors: [String] = []

        do { grades = try await client.fetchGrades(userId: userId) }
        catch { fetchErrors.append("notes: \(error.localizedDescription)") }

        do {
            let now = Date()
            let fourWeeksAgo = now.addingTimeInterval(-28 * 86_400)
            let twoWeeksAhead = now.addingTimeInterval(14 * 86_400)
            lessons = try await client.fetchSchedule(userId: userId, from: fourWeeksAgo, to: twoWeeksAhead)
        }
        catch { fetchErrors.append("emploi du temps: \(error.localizedDescription)") }

        do { homework = try await client.fetchHomework(userId: userId) }
        catch { fetchErrors.append("devoirs: \(error.localizedDescription)") }

        do { messages = try await client.fetchMessages(userId: userId) }
        catch { fetchErrors.append("messages: \(error.localizedDescription)") }

        let hasData = !grades.isEmpty || !lessons.isEmpty || !homework.isEmpty || !messages.isEmpty
        switch SyncGate.decide(hasData: hasData, fetchErrors: fetchErrors) {
        case .proceed:
            break
        case .preserve:
            NSLog("[noto][warn] Skolengo sync for %@ returned empty payload — preserving local data", child.firstName)
            child.markSynced()
            try modelContext.save()
            return
        case .fail(let detail):
            throw SkolengoError.invalidResponse("Aucune donnée récupérée (\(detail))")
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
        child.markSynced()

        try modelContext.save()
        NSLog("[noto] Skolengo sync OK for %@ — %d notes, %d cours, %d devoirs, %d messages",
              child.firstName, grades.count, lessons.count, homework.count, messages.count)
    }

    // MARK: - Private

    private func syncGrades(_ skoGrades: [SkolengoGrade], for child: Child) {
        for sg in skoGrades {
            guard let value = skoParseGradeValue(sg.rawValue) else { continue }
            let grade = Grade(
                subject: sg.subject,
                value: value,
                outOf: sg.outOf,
                coefficient: sg.coefficient,
                date: sg.date
            )
            if let avg = sg.classAverage { grade.classAverage = avg }
            grade.child = child
            modelContext.insert(grade)
        }
    }

    private func syncSchedule(_ lessons: [SkolengoLesson], for child: Child) {
        for lesson in lessons {
            let entry = ScheduleEntry(subject: lesson.subject, start: lesson.start, end: lesson.end, cancelled: lesson.cancelled)
            entry.room = lesson.room
            entry.teacher = lesson.teacher
            entry.child = child
            modelContext.insert(entry)
        }
    }

    private func syncHomework(_ skoHomework: [SkolengoHomework], for child: Child) {
        for hw in skoHomework {
            let homework = Homework(
                subject: hw.subject,
                description: hw.description,
                dueDate: hw.dueDate
            )
            homework.done = hw.done
            homework.child = child
            modelContext.insert(homework)
        }
    }

    private func syncMessages(_ skoMessages: [SkolengoMessage], for child: Child) {
        for sm in skoMessages {
            let msg = Message(
                sender: sm.from,
                subject: sm.subject,
                body: sm.body,
                date: sm.date,
                source: .ent       // reuses .ent source — no new MessageSource case needed
            )
            msg.read = sm.read
            msg.child = child
            modelContext.insert(msg)
        }
    }
}
