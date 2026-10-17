import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import Noto

/// `LessonContentStore` (3.8) on an in-memory `NotoSchemaV1` container.
/// Offline: no connector is involved.
@MainActor
@Suite("LessonContentStore")
struct LessonContentStoreTests {
    let context: ModelContext
    let calendar = QuizClock.calendar

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func makeChild(grade: String = "4e") -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: grade, schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func rows() throws -> [LessonContent] {
        try context.fetch(FetchDescriptor<LessonContent>())
    }

    private func incoming(_ text: String, day: Int = -2, themes: [String] = [],
                          source: LessonContentSource = .pronoteLesson) -> LessonContentStore.Incoming {
        .init(subject: "HISTOIRE-GEOGRAPHIE", date: QuizClock.date(day: day, hour: 9), title: "Chapitre 2",
              text: text, themes: themes, source: source, externalID: "C-1")
    }

    @Test("same key gives one row; text and fetchedAt refreshed, teacher themes kept")
    func upsertDedup() throws {
        let child = makeChild()
        LessonContentStore.upsert([incoming("la revolution francaise", themes: ["La Révolution française"])],
                                  for: child, in: context, calendar: calendar, now: QuizClock.now)
        let later = QuizClock.now.addingTimeInterval(3600)
        LessonContentStore.upsert([incoming("La Révolution française")], for: child, in: context,
                                  calendar: calendar, now: later)
        try context.save()

        let all = try rows()
        #expect(all.count == 1)
        #expect(all.first?.text == "La Révolution française")
        #expect(all.first?.themes == ["La Révolution française"])
        #expect(all.first?.fetchedAt == later)
        #expect(all.first?.source == .pronoteLesson)
        #expect(child.lessonContents.count == 1)
    }

    @Test("rows with an empty title and text are skipped")
    func emptySkipped() throws {
        let child = makeChild()
        LessonContentStore.upsert([.init(subject: "MATHS", date: QuizClock.now, title: "  ", text: "\n",
                                         source: .homework)], for: child, in: context, calendar: calendar)
        try context.save()
        #expect(try rows().isEmpty)
    }

    @Test("captureHomework before a wipe keeps past homework")
    func captureBeforeWipe() throws {
        let child = makeChild()
        let homework = Homework(subject: "MATHS", description: "Exercices sur Pythagore", dueDate: QuizClock.date(day: -3))
        context.insert(homework)
        homework.child = child
        try context.save()

        LessonContentStore.captureHomework(of: child, in: context, calendar: calendar, now: QuizClock.now)
        for hw in child.homework { context.delete(hw) }       // the connector wipe
        LessonContentStore.recordSync(of: child, in: context, now: QuizClock.now, calendar: calendar)
        try context.save()

        let kept = try rows()
        #expect(try context.fetch(FetchDescriptor<Homework>()).isEmpty)
        #expect(kept.count == 1)
        #expect(kept.first?.source == .homework)
        #expect(kept.first?.text == "Exercices sur Pythagore")
        #expect(kept.first?.dedupKey == HomeworkSnapshot(subject: "MATHS", descriptionText: "Exercices sur Pythagore",
                                                         dueDate: QuizClock.date(day: -3), done: false,
                                                         calendar: calendar).dedupKey)
    }

    @Test("purge drops rows from before 1 September, then everything on a level change")
    func purgeRolloverAndLevelChange() throws {
        let child = makeChild()
        let lastYear = QuizClock.calendar.date(from: DateComponents(year: 2023, month: 8, day: 20, hour: 10))!
        let thisYear = QuizClock.calendar.date(from: DateComponents(year: 2023, month: 10, day: 2, hour: 10))!
        LessonContentStore.upsert([
            .init(subject: "MATHS", date: lastYear, title: "", text: "Révisions de juin", source: .homework),
            .init(subject: "MATHS", date: thisYear, title: "", text: "Pythagore", source: .pronoteLesson),
        ], for: child, in: context, calendar: calendar, now: QuizClock.now)

        // First purge: no previous level recorded → only the school-year rule.
        LessonContentStore.purge(for: child, in: context, now: QuizClock.now, calendar: calendar)
        try context.save()
        #expect(try rows().map(\.text) == ["Pythagore"])
        #expect(child.programmeLevel == "4e")

        // Class change (4e → 3e): everything goes.
        child.grade = "3ème"
        child.lessonContentsFetchedAt = QuizClock.now
        LessonContentStore.purge(for: child, in: context, now: QuizClock.now, calendar: calendar)
        try context.save()
        #expect(try rows().isEmpty)
        #expect(child.programmeLevel == "3e")
        #expect(child.lessonContentsFetchedAt == nil)
    }

    @Test("school year starts on 1 September, Europe/Paris")
    func schoolYearStart() {
        let november = QuizClock.now
        let april = QuizClock.calendar.date(from: DateComponents(year: 2024, month: 4, day: 2))!
        let start2023 = QuizClock.calendar.date(from: DateComponents(year: 2023, month: 9, day: 1))!
        #expect(LessonContentStore.schoolYearStart(for: november) == start2023)
        #expect(LessonContentStore.schoolYearStart(for: april) == start2023)
    }

    @Test("24 h freshness gate")
    func freshness() {
        let child = makeChild()
        #expect(!LessonContentStore.isFresh(child, now: QuizClock.now))
        child.lessonContentsFetchedAt = QuizClock.now.addingTimeInterval(-23 * 3600)
        #expect(LessonContentStore.isFresh(child, now: QuizClock.now))
        child.lessonContentsFetchedAt = QuizClock.now.addingTimeInterval(-25 * 3600)
        #expect(!LessonContentStore.isFresh(child, now: QuizClock.now))
    }

    @Test("LessonDedupKey hashes exactly like the pre-3.8 HomeworkSnapshot recipe")
    func dedupKeyRegression() {
        let due = QuizClock.date(day: 1, hour: 17)
        // Pre-3.8 recipe, copied verbatim from `HomeworkSnapshot.init`.
        let day = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: due))
        let ymd = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let raw = SubjectAlias.fold("FRANCAIS") + "|" + ymd + "|" + SubjectAlias.fold("Lire Scapin")
        let legacy = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()

        let snapshot = HomeworkSnapshot(subject: "FRANCAIS", descriptionText: "Lire Scapin", dueDate: due,
                                        done: false, calendar: calendar)
        #expect(snapshot.dedupKey == legacy)
        #expect(LessonDedupKey.make(subject: "FRANCAIS", date: due, text: "Lire Scapin", calendar: calendar) == legacy)
        // A homework row (empty title) hashes as its bare description.
        let row = LessonContent(child: nil, subject: "FRANCAIS", date: due, title: "", text: "Lire Scapin",
                                themes: [], source: .homework, externalID: nil, calendar: calendar)
        #expect(row.dedupKey == legacy)
        #expect(LessonDedupKey.body(title: "Titre", text: "Texte") == "Titre Texte")
    }
}
