import Testing
import Foundation
import SwiftData
@testable import Noto

/// The Révisions models live in `NotoSchemaV1` (no V2, no plan): this pins
/// that the full schema builds, the three models round-trip, and deleting a
/// `Child` cascades to its attempts and masteries but not to the shared bank.
@MainActor
@Suite("Quiz model persistence")
struct QuizModelPersistenceTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(NotoSchemaV1.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(in context: ModelContext) -> Child {
        let child = Child(firstName: "Test", level: .college, grade: "4e", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func makeItem() -> QuizItem {
        let question = "Qui a écrit « Les Fourberies de Scapin » ?"
        let choices = ["Molière", "Racine", "Corneille", "Marivaux"]
        let key = QuizKey.make(question: question, choices: choices)
        return QuizItem(id: QuizKey.deterministicID(for: key), questionKey: key, kind: "programme",
                        question: question, choices: choices, answerIndex: 0, domain: "francais",
                        difficulty: 1, level: "4e", subject: "Français",
                        theme: "Molière et le théâtre classique", source: .bank,
                        sourceRef: "4e/francais.json#0", reviewed: true, fetchedAt: QuizClock.now)
    }

    @Test("NotoSchemaV1 lists the Révisions models, StreakJoker and SchoolPhoto")
    func schemaListsModels() {
        let names = NotoSchemaV1.models.map { String(describing: $0) }
        for expected in ["QuizItem", "QuizAttempt", "NotionMastery", "StreakJoker", "SchoolPhoto"] {
            #expect(names.contains(expected))
        }
        #expect(NotoSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("insert and fetch the three models")
    func roundTrip() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        let item = makeItem()
        context.insert(item)
        let attempt = QuizAttempt(child: child, date: QuizClock.now, itemIDs: [item.id],
                                  questionKeys: ["b", "a"], answers: [0], correctCount: 1, totalCount: 1,
                                  durationSec: 42, minutesEarned: 15, bonusApplied: true)
        context.insert(attempt)
        let mastery = NotionMastery(child: child, notionKey: "4e|francais|moliere et le theatre classique",
                                    now: QuizClock.now, calendar: QuizClock.calendar)
        context.insert(mastery)
        try context.save()

        let items = try context.fetch(FetchDescriptor<QuizItem>())
        #expect(items.count == 1)
        #expect(items.first?.source == .bank)
        #expect(items.first?.format == .mcq)
        #expect(items.first?.choices.count == 4)

        let attempts = try context.fetch(FetchDescriptor<QuizAttempt>())
        #expect(attempts.count == 1)
        #expect(attempts.first?.questionKeys == ["a", "b"])
        #expect(attempts.first?.child === child)

        let masteries = try context.fetch(FetchDescriptor<NotionMastery>())
        #expect(masteries.count == 1)
        #expect(masteries.first?.leitnerBox == 1)
        #expect(masteries.first?.nextReview == QuizClock.date(day: 0))
        #expect(child.quizAttempts.count == 1)
        #expect(child.notionMasteries.count == 1)
    }

    @Test("deleting a Child cascades to attempts and masteries, not to the item bank")
    func cascade() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        context.insert(makeItem())
        context.insert(QuizAttempt(child: child, date: QuizClock.now, itemIDs: [], questionKeys: [], answers: [],
                                   correctCount: 0, totalCount: 0, durationSec: 0, minutesEarned: 0,
                                   bonusApplied: false, denialReason: RewardDenial.emptyQuiz.rawValue))
        context.insert(NotionMastery(child: child, notionKey: "k", now: QuizClock.now, calendar: QuizClock.calendar))
        try context.save()

        context.delete(child)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Child>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<QuizAttempt>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<NotionMastery>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<QuizItem>()).count == 1)
    }

    // MARK: Model ↔ snapshot

    @Test("AttemptSnapshot.passed follows the stored denial", arguments: [
        (nil as String?, 5, true), ("capReached", 5, true), ("tiersExhausted", 5, true),
        ("tooFast", 5, false), ("identicalReplay", 5, false), ("belowThreshold", 5, false),
        ("tooShort", 5, false),
        (nil as String?, 0, false), ("not-a-denial", 5, true),
    ])
    func attemptSnapshot(denial: String?, total: Int, passed: Bool) {
        let attempt = QuizAttempt(date: QuizClock.now, itemIDs: [], questionKeys: ["z", "y"], answers: [],
                                  correctCount: total, totalCount: total, durationSec: 40, minutesEarned: 5,
                                  bonusApplied: true, bonusMinutes: 5, denialReason: denial)
        let snapshot = AttemptSnapshot(attempt)
        #expect(snapshot.passed == passed)
        #expect(snapshot.questionKeys == ["y", "z"])
        #expect(snapshot.minutesEarned == 5)
        #expect(snapshot.bonusApplied)
        #expect(snapshot.bonusMinutes == 5)
    }

    @Test("mastery, homework and schedule snapshots mirror their models")
    func otherSnapshots() {
        let calendar = QuizClock.calendar
        let mastery = NotionMastery(child: nil, notionKey: "k", now: QuizClock.now, calendar: calendar)
        let reviewed = SpacedRepetition.review(MasterySnapshot(mastery), correct: true, now: QuizClock.now, calendar: calendar)
        mastery.apply(reviewed, reviewedAt: QuizClock.now)
        #expect(mastery.leitnerBox == 2)
        #expect(mastery.nextReview == QuizClock.date(day: 2))
        #expect(mastery.streakCorrect == 1)
        #expect(mastery.lastReviewedAt == QuizClock.now)

        let homework = Homework(subject: "FRANCAIS", description: "Lire Scapin", dueDate: QuizClock.date(day: 1, hour: 8))
        #expect(HomeworkSnapshot(homework, calendar: calendar)
                == QuizClock.homework("FRANCAIS", "Lire Scapin", day: 1, hour: 8))

        let entry = ScheduleEntry(subject: "MATHS", start: QuizClock.date(day: 1, hour: 8),
                                  end: QuizClock.date(day: 1, hour: 9), cancelled: true)
        let lesson = ScheduleSnapshot(entry)
        #expect(lesson.cancelled)
        #expect(!lesson.isTest)
        #expect(lesson.subject == "MATHS")
    }
}
