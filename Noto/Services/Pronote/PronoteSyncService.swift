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
    func sync(child: Child, client: PronoteClient) async throws {
        async let gradesResult = client.fetchGrades()
        async let timetableResult = client.fetchTimetable(from: .now)
        async let homeworkResult = client.fetchHomework(from: .now)

        let (grades, lessons, assignments) = try await (gradesResult, timetableResult, homeworkResult)

        syncGrades(grades, for: child)
        syncSchedule(lessons, for: child)
        syncHomework(assignments, for: child)

        try modelContext.save()
    }

    // MARK: - Grades

    private func syncGrades(_ pronoteGrades: [PronoteGrade], for child: Child) {
        // Upsert: match by id to avoid duplicates
        let existingIds = Set(child.grades.map(\.subject)) // TODO: use proper Pronote ID

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
}
