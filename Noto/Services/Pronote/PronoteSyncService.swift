import Foundation
import SwiftData

/// Syncs Pronote data into SwiftData models.
/// Runs on-device, fetches from Pronote, writes to local store.
@MainActor
final class PronoteSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync for a Pronote child: grades, schedule, homework.
    /// Errors are caught per-resource so partial sync succeeds.
    func sync(child: Child, client: PronoteClient) async throws {
        print("[noto] Starting sync for \(child.firstName)")

        // Fetch all data in parallel, catch errors individually
        async let gradesResult = fetchSafe { try await client.fetchGrades() }
        async let timetableResult = fetchSafe { try await client.fetchTimetable(from: .now) }
        async let homeworkResult = fetchSafe { try await client.fetchHomework(from: .now) }
        async let messagesResult = fetchSafe { try await client.fetchDiscussions() }

        let grades = await gradesResult
        let lessons = await timetableResult
        let homework = await homeworkResult
        let discussions = await messagesResult

        print("[noto] Fetched: \(grades.count) grades, \(lessons.count) lessons, \(homework.count) homework, \(discussions.count) messages")

        // Clear existing data for this child (full refresh)
        clearExistingData(for: child)

        // Insert new data
        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(homework, for: child)
        syncMessages(discussions, for: child)

        try modelContext.save()
        print("[noto] Sync complete for \(child.firstName)")
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

    private func fetchSafe<T>(_ fetch: () async throws -> [T]) async -> [T] {
        do {
            return try await fetch()
        } catch {
            print("[noto] Sync fetch error: \(error)")
            return []
        }
    }
}
