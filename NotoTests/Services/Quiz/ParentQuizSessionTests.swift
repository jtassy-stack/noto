import Testing
import Foundation
import SwiftData
@testable import Noto

/// `ParentQuizSession` on an in-memory `NotoSchemaV1` container: the parent
/// gets the child's draw, and finishing writes one `ParentQuizAttempt` and
/// nothing the child's rewards, XP or Leitner read. Plus the pure
/// `ParentQuizComparison` / `ParentQuizHistory`. No network.
@MainActor
@Suite("ParentQuizSession")
struct ParentQuizSessionTests {
    let context: ModelContext
    let clock = QuizTestClock(QuizClock.now)

    static let themes = [
        ("Français", "Molière et le théâtre classique"),
        ("Mathématiques", "Théorème de Pythagore"),
        ("Histoire", "La Révolution française"),
        ("Géographie", "L'urbanisation du monde"),
        ("Français", "Le récit fantastique"),
        ("Français", "Dire l'amour"),
        ("Mathématiques", "Calcul littéral et équations"),
    ]

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
    }

    // MARK: Helpers

    private func makeChild() -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: "4ème", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    @discardableResult
    private func addItem(_ subjectTheme: (String, String), _ n: Int = 0) -> QuizItem {
        let question = "Question \(n) sur \(subjectTheme.1) ?"
        let choices = ["Choix A\(n)", "Choix B\(n)", "Choix C\(n)", "Choix D\(n)"]
        let key = QuizKey.make(question: question, choices: choices)
        let item = QuizItem(id: QuizKey.deterministicID(for: key + "4e"), questionKey: key, kind: "programme",
                            question: question, choices: choices, answerIndex: 1,
                            explanation: "Parce que.", domain: "programme", difficulty: 1,
                            level: "4e", subject: subjectTheme.0, theme: subjectTheme.1,
                            source: .celyn, sourceRef: "celyn/bank/4e", reviewed: true,
                            fetchedAt: QuizClock.now)
        context.insert(item)
        return item
    }

    private func addBank(perTheme: Int = 1) {
        for theme in Self.themes {
            for n in 0..<perTheme { addItem(theme, n) }
        }
    }

    private func makeParentSession(_ child: Child, seed: UInt64 = 7) -> ParentQuizSession {
        let clock = self.clock
        return ParentQuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                                 calendar: QuizClock.calendar, seed: seed, now: { clock.now })
    }

    private func makeChildSession(_ child: Child, seed: UInt64 = 7) -> QuizSession {
        let clock = self.clock
        return QuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                           config: .default, calendar: QuizClock.calendar, seed: seed, now: { clock.now })
    }

    private func play(_ session: ParentQuizSession, wrong: Set<Int> = [], seconds: TimeInterval = 60) {
        for index in session.questions.indices {
            let question = session.questions[index]
            let choice = wrong.contains(index) ? (question.answerIndex + 1) % 4 : question.answerIndex
            #expect(session.answer(choice) == !wrong.contains(index))
            if index < session.questions.count - 1 { session.advance() }
        }
        clock.now = QuizClock.now.addingTimeInterval(seconds)
        session.advance()
    }

    // MARK: Draw

    @Test("the parent gets the child's quiz: same seed, same questions")
    func sameDrawAsChild() throws {
        let child = makeChild()
        addBank(perTheme: 2)
        try context.save()

        let parent = makeParentSession(child, seed: 42)
        let kid = makeChildSession(child, seed: 42)
        #expect(parent.phase == .inProgress)
        #expect(parent.questions.count == QuizSession.questionCount)
        #expect(parent.questions.map(\.id) == kid.questions.map(\.id))
    }

    @Test("questions the parent already played come after fresh ones")
    func prefersQuestionsNotPlayedByParent() throws {
        let child = makeChild()
        // Five themes open in T1 (QuizClock.now is mid-November): T2 themes
        // are left out of the draw by the programme filter.
        let open = Self.themes.filter { $0.1 != "Le récit fantastique" && $0.1 != "Calcul littéral et équations" }
        let seen = open.map { addItem($0, 0) }
        for theme in open { addItem(theme, 1) }
        context.insert(ParentQuizAttempt(child: child, date: QuizClock.date(day: -1, hour: 20),
                                         questionKeys: seen.map(\.questionKey), notionKeys: [],
                                         answers: [1, 1, 1, 1, 1], correctCount: 5, totalCount: 5,
                                         durationSec: 90))
        try context.save()

        let session = makeParentSession(child)
        let seenKeys = Set(seen.map(\.questionKey))
        #expect(session.questions.count == 5)
        #expect(session.questions.allSatisfy { !seenKeys.contains($0.questionKey) })
    }

    @Test("no question for the level → empty state, nothing saved")
    func emptyBank() throws {
        let child = makeChild()
        try context.save()

        let session = makeParentSession(child)
        #expect(session.phase == .empty)
        #expect(session.answer(0) == nil)
        session.advance()
        #expect(session.result == nil)
        #expect(try context.fetch(FetchDescriptor<ParentQuizAttempt>()).isEmpty)
    }

    // MARK: Finish

    @Test("finishing saves one parent attempt and nothing of the child's progress")
    func finishDoesNotTouchChildProgress() throws {
        let child = makeChild()
        addBank()
        try context.save()

        let session = makeParentSession(child)
        play(session, wrong: [1, 3], seconds: 75)

        #expect(session.phase == .finished)
        let result = try #require(session.result)
        #expect(result.correctCount == 3)
        #expect(result.totalCount == 5)
        #expect(result.durationSec == 75)
        #expect(result.review.count == 5)
        #expect(result.review.map(\.isCorrect) == [true, false, true, false, true])
        #expect(result.review[1].chosenAnswer != result.review[1].rightAnswer)
        #expect(result.review[0].chosenAnswer == result.review[0].rightAnswer)

        let saved = try context.fetch(FetchDescriptor<ParentQuizAttempt>())
        #expect(saved.count == 1)
        #expect(saved.first?.correctCount == 3)
        #expect(saved.first?.questionKeys == session.questions.map(\.questionKey).sorted())
        #expect(child.parentQuizAttempts.count == 1)

        // The child's side is untouched: no attempt (rewards, XP, série) and
        // no Leitner row.
        #expect(try context.fetch(FetchDescriptor<QuizAttempt>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<NotionMastery>()).isEmpty)
        #expect(child.quizAttempts.isEmpty)
        #expect(child.notionMasteries.isEmpty)
    }

    @Test("advance is a no-op until the current question is answered")
    func advanceNeedsAnswer() throws {
        let child = makeChild()
        addBank()
        try context.save()

        let session = makeParentSession(child)
        session.advance()
        #expect(session.currentIndex == 0)
        #expect(session.answer(session.questions[0].answerIndex) == true)
        #expect(session.answer(0) == nil)   // first tap only
        session.advance()
        #expect(session.currentIndex == 1)
    }

    @Test("the result compares with the child's masteries on the same notions")
    func comparisonFromChildMasteries() throws {
        let child = makeChild()
        addBank()
        try context.save()

        let session = makeParentSession(child)
        let notionKeys = session.questions.compactMap(\.notionKey)
        #expect(notionKeys.count == 5)
        let mastered = NotionMastery(child: child, notionKey: notionKeys[0], now: QuizClock.now,
                                     calendar: QuizClock.calendar)
        mastered.leitnerBox = 4
        let fragile = NotionMastery(child: child, notionKey: notionKeys[1], now: QuizClock.now,
                                    calendar: QuizClock.calendar)
        context.insert(mastered)
        context.insert(fragile)
        try context.save()

        play(session)
        let comparison = try #require(session.result?.comparison)
        #expect(comparison == ParentQuizComparison(notionCount: 5, mastered: 1, inProgress: 0, fragile: 1))
        #expect(comparison.notStarted == 3)
        // The parent's quiz moved nothing.
        #expect(mastered.leitnerBox == 4)
        #expect(fragile.leitnerBox == 1)
    }

    // MARK: Pure

    @Test("comparison sentence, parent tone")
    func comparisonSentence() {
        let masteries = [
            MasterySnapshot(notionKey: "a", leitnerBox: 5, nextReview: QuizClock.now, streakCorrect: 3),
            MasterySnapshot(notionKey: "b", leitnerBox: 3, nextReview: QuizClock.now, streakCorrect: 1),
            MasterySnapshot(notionKey: "c", leitnerBox: 1, nextReview: QuizClock.now, streakCorrect: 0),
            MasterySnapshot(notionKey: "z", leitnerBox: 5, nextReview: QuizClock.now, streakCorrect: 3),
        ]
        let comparison = ParentQuizComparison.make(notionKeys: ["a", "b", "c", "d", "a", ""], masteries: masteries)
        #expect(comparison == ParentQuizComparison(notionCount: 4, mastered: 1, inProgress: 1, fragile: 1))
        #expect(comparison.sentence(firstName: "Léa")
            == "Pour Léa, sur les 4 notions de ce quiz : 1 maîtrisée, 1 en cours, 1 fragile et 1 pas encore travaillée.")
    }

    @Test("no child data on this device, or no notion at all")
    func comparisonWithoutData() {
        let none = ParentQuizComparison.make(notionKeys: ["a", "b"], masteries: [])
        #expect(!none.hasChildData)
        #expect(none.sentence(firstName: "Léa")?.hasPrefix("Les révisions de Léa ne sont pas sur cet appareil") == true)
        #expect(ParentQuizComparison.make(notionKeys: ["", ""], masteries: []).sentence(firstName: "Léa") == nil)
    }

    @Test("history keeps the latest score")
    func history() {
        let history = ParentQuizHistory(attempts: [
            (date: QuizClock.date(day: -3), correct: 2, total: 5),
            (date: QuizClock.date(day: -1), correct: 4, total: 5),
            (date: QuizClock.date(day: -2), correct: 5, total: 5),
        ])
        #expect(history.quizCount == 3)
        #expect(history.lastDate == QuizClock.date(day: -1))
        #expect(history.lastCorrect == 4)
        #expect(history.lastTotal == 5)
        #expect(ParentQuizHistory(attempts: []).lastDate == nil)
    }

    @Test("result copy addresses the parent")
    func resultCopy() {
        #expect(ParentQuizResultView.title(correct: 5, total: 5) == "Sans faute !")
        #expect(ParentQuizResultView.title(correct: 3, total: 5) == "Bien joué")
        #expect(ParentQuizResultView.title(correct: 2, total: 5) == "De quoi réviser ensemble")
        #expect(ParentQuizResultView.scoreSentence(correct: 4, total: 5)
            == "Vous avez répondu juste à 4 questions sur 5.")
    }
}
