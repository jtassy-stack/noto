import Testing
import Foundation
import SwiftData
@testable import Noto

@Suite("NotoSchemaV1")
struct NotoSchemaTests {
    @Test("models include LessonContent (3.8, appended in place)")
    func containsLessonContent() {
        #expect(NotoSchemaV1.models.contains { $0 == LessonContent.self })
        #expect(NotoSchemaV1.models.last.map { $0 == LessonContent.self } == true)
    }

    @MainActor
    @Test("an in-memory container opens with the full schema and stores a LessonContent")
    func containerOpens() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let child = Child(firstName: "Léa", level: .college, grade: "4e", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        let row = LessonContent(child: child, subject: "MATHS", date: QuizClock.now, title: "", text: "Pythagore",
                                themes: [], source: .homework, externalID: nil, calendar: QuizClock.calendar)
        context.insert(row)
        row.child = child
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LessonContent>()) == 1)
        #expect(child.programmeLevel == nil)
        #expect(child.lessonContentsFetchedAt == nil)

        // Cascade with the child (RGPD).
        context.delete(child)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LessonContent>()) == 0)
    }
}
