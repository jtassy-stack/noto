import Foundation
import SwiftData

/// Syncs Pronote data into SwiftData models.
/// Uses PawnoteBridge (JSCore) for the Pronote protocol.
@MainActor
final class PronoteSyncService {
    private let modelContext: ModelContext
    var lastSyncError: String?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync using PawnoteBridge (pawnote via JavaScriptCore).
    func sync(child: Child, bridge: PawnoteBridge, childIndex: Int) async {
        NSLog("[noto] Starting sync for \(child.firstName) (index \(childIndex))")
        lastSyncError = nil

        bridge.setActiveChild(index: childIndex)

        let grades = await fetchSafe("Grades") { try await bridge.fetchGrades() }
        let today = Date.now
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: today)!
        let twoWeeks = Calendar.current.date(byAdding: .day, value: 14, to: today)!
        let lessons = await fetchSafe("Timetable") { try await bridge.fetchTimetable(from: today, to: nextWeek) }
        let homework = await fetchSafe("Homework") { try await bridge.fetchHomework(from: today, to: twoWeeks) }
        let discussions = await fetchSafe("Messages") { try await bridge.fetchDiscussions() }

        NSLog("[noto] Fetched: \(grades.count) grades, \(lessons.count) lessons, \(homework.count) homework, \(discussions.count) messages")

        clearExistingData(for: child)
        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(homework, for: child)
        syncMessages(discussions, for: child)

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

    private func fetchSafe<T>(_ label: String, _ fetch: () async throws -> [T]) async -> [T] {
        do {
            let result = try await fetch()
            NSLog("[noto] ✅ \(label): \(result.count) items")
            return result
        } catch {
            NSLog("[noto] ❌ \(label) failed: \(error)")
            lastSyncError = "\(label): \(error)"
            return []
        }
    }
}
