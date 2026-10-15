import Testing
import Foundation
import SwiftData
@testable import Noto

/// `QuizSession` end to end on an in-memory `NotoSchemaV1` container: draw
/// (selector order, reviewed + level only, determinism, replay preference,
/// thin and empty banks), scoring through `RewardPolicy`, the persisted
/// `QuizAttempt`, and `NotionMastery` updates. No network: the session only
/// reads local `QuizItem` rows.
///
/// With `QuizCurriculumFixtures` (4e), no homework and no mastery, the
/// selector plans F1, M1, H1, G1, F2 (round-robin, whole year).
@MainActor
@Suite("QuizSession")
struct QuizSessionTests {
    let context: ModelContext
    let clock = QuizTestClock(QuizClock.now)

    static let moliere = ("Français", "Molière et le théâtre classique")
    static let fantastique = ("Français", "Le récit fantastique")
    static let amour = ("Français", "Dire l'amour")
    static let pythagore = ("Mathématiques", "Théorème de Pythagore")
    static let calcul = ("Mathématiques", "Calcul littéral et équations")
    static let revolution = ("Histoire", "La Révolution française")
    static let urbanisation = ("Géographie", "L'urbanisation du monde")
    static let plannedThemes = [moliere.1, pythagore.1, revolution.1, urbanisation.1, fantastique.1]

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    // MARK: Helpers

    @discardableResult
    private func makeChild(grade: String = "4ème") -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: grade, schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    @discardableResult
    private func addItem(_ subjectTheme: (String, String), _ n: Int = 0, level: String = "4e",
                         reviewed: Bool = true, answer: Int = 1) -> QuizItem {
        let question = "Question \(n) sur \(subjectTheme.1) ?"
        let choices = ["Choix A\(n)", "Choix B\(n)", "Choix C\(n)", "Choix D\(n)"]
        let key = QuizKey.make(question: question, choices: choices)
        let item = QuizItem(id: QuizKey.deterministicID(for: key + level), questionKey: key, kind: "programme",
                            question: question, choices: choices, answerIndex: answer,
                            explanation: "Parce que.", domain: "programme", difficulty: 1,
                            level: level, subject: subjectTheme.0, theme: subjectTheme.1,
                            source: .celyn, sourceRef: "celyn/bank/\(level)", reviewed: reviewed,
                            fetchedAt: QuizClock.now)
        context.insert(item)
        return item
    }

    private func addPlannedBank(perTheme: Int = 1) {
        for theme in [Self.moliere, Self.pythagore, Self.revolution, Self.urbanisation, Self.fantastique,
                      Self.amour, Self.calcul] {
            for n in 0..<perTheme { addItem(theme, n) }
        }
    }

    /// `config` is always explicit (the init default is `.default`; only
    /// `QuizView` reads the app group, which the test host shares with the
    /// app installed on the simulator).
    private func makeSession(_ child: Child, seed: UInt64 = 7, config: RewardConfig = .default) -> QuizSession {
        let clock = self.clock
        return QuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                           config: config, calendar: QuizClock.calendar, seed: seed, now: { clock.now })
    }

    /// Answers every question (right unless its index is in `wrong`), then
    /// finishes `seconds` after the start.
    private func play(_ session: QuizSession, wrong: Set<Int> = [], seconds: TimeInterval = 60) {
        for index in session.questions.indices {
            let question = session.questions[index]
            let choice = wrong.contains(index) ? (question.answerIndex + 1) % 4 : question.answerIndex
            #expect(session.answer(choice) == !wrong.contains(index))
            if index < session.questions.count - 1 { session.advance() }
        }
        clock.now = QuizClock.now.addingTimeInterval(seconds)
        session.advance()   // last question → finish()
    }

    private func attempts() throws -> [QuizAttempt] {
        try context.fetch(FetchDescriptor<QuizAttempt>())
    }

    private func masteries() throws -> [NotionMastery] {
        try context.fetch(FetchDescriptor<NotionMastery>())
    }

    private func key(_ subjectTheme: (String, String)) -> String {
        NotionKey.make(level: "4e", subject: subjectTheme.0, theme: subjectTheme.1)
    }

    // MARK: Draw

    @Test("draws 5 reviewed items of the canonical level, in the selector's slot order")
    func selection() throws {
        let child = makeChild()
        addPlannedBank()
        addItem(Self.moliere, 9, reviewed: false)
        addItem(Self.moliere, 8, level: "3e")
        try context.save()

        let session = makeSession(child)
        #expect(session.phase == .inProgress)
        #expect(session.questions.count == QuizSession.questionCount)
        #expect(session.questions.compactMap(\.theme) == Self.plannedThemes)
        #expect(!session.questions.contains { $0.question.contains("Question 9") || $0.question.contains("Question 8") })
        #expect(session.questions[0].notionKey == key(Self.moliere))
        #expect(try attempts().isEmpty)
    }

    @Test("same seed, same quiz; the draw never touches the store")
    func deterministic() throws {
        let child = makeChild()
        addPlannedBank(perTheme: 3)
        try context.save()

        let first = makeSession(child, seed: 42).questions.map(\.id)
        let second = makeSession(child, seed: 42).questions.map(\.id)
        #expect(first == second)
        #expect(first.count == 5)
        #expect(Set(first).count == 5)
        #expect(try attempts().isEmpty)
        #expect(try masteries().isEmpty)
    }

    @Test("items already passed come after fresh ones of the same theme")
    func prefersFreshItems() throws {
        let child = makeChild()
        let seen = [Self.moliere, Self.pythagore, Self.revolution, Self.urbanisation, Self.fantastique]
            .map { addItem($0, 0) }
        for theme in [Self.moliere, Self.pythagore, Self.revolution, Self.urbanisation, Self.fantastique] {
            addItem(theme, 1)
        }
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: -3, hour: 18), itemIDs: seen.map(\.id),
                                   questionKeys: seen.map(\.questionKey), answers: [1, 1, 1, 1, 1],
                                   correctCount: 5, totalCount: 5, durationSec: 90, minutesEarned: 10,
                                   bonusApplied: false))
        try context.save()

        let session = makeSession(child)
        let seenKeys = Set(seen.map(\.questionKey))
        #expect(session.questions.count == 5)
        #expect(session.questions.allSatisfy { !seenKeys.contains($0.questionKey) })
    }

    @Test("a thin bank still makes a quiz: matched slots first, then top-up")
    func thinBank() throws {
        let child = makeChild()
        addItem(Self.calcul)       // not planned (6th programme slot)
        addItem(Self.pythagore)    // planned slot 2
        try context.save()

        let session = makeSession(child)
        #expect(session.phase == .inProgress)
        #expect(session.questions.count == 2)
        #expect(session.questions.compactMap(\.theme) == [Self.pythagore.1, Self.calcul.1])
    }

    @Test("no question for the level → empty state, nothing saved", arguments: [
        "noBank", "unreviewedOnly", "otherLevelOnly",
    ])
    func emptyBank(variant: String) throws {
        let child = makeChild()
        switch variant {
        case "unreviewedOnly": addItem(Self.moliere, reviewed: false)
        case "otherLevelOnly": addItem(Self.moliere, level: "3e")
        default: break
        }
        try context.save()

        let session = makeSession(child)
        #expect(session.phase == .empty)
        #expect(session.questions.isEmpty)
        #expect(session.currentQuestion == nil)
        #expect(session.answer(0) == nil)
        session.advance()
        #expect(session.phase == .empty)
        #expect(session.result == nil)
        #expect(try attempts().isEmpty)
        #expect(child.quizAttempts.isEmpty)
        #expect(QuizSession.availableCount(for: child, in: context, now: QuizClock.now) == 0)
    }

    @Test("primary level is never served, even with items tagged for it")
    func primaryLevel() throws {
        let child = makeChild(grade: "CM2")
        addItem(("Français", "Lire des contes"), level: "CM2")
        try context.save()

        let session = makeSession(child)
        #expect(session.phase == .empty)
        #expect(QuizSession.availableCount(for: child, in: context) == 0)
    }

    // MARK: Answering

    @Test("first tap only: the answer cannot be changed after feedback")
    func answerOnce() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        let question = try #require(session.currentQuestion)
        #expect(session.answer(question.answerIndex) == true)
        #expect(session.answer((question.answerIndex + 1) % 4) == nil)
        #expect(session.currentAnswer == question.answerIndex)
        #expect(session.answer(7) == nil)
    }

    // MARK: Scoring + persistence

    @Test("5/5 in 60 s: 10 min, attempt saved, every notion to box 2")
    func passEndToEnd() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        play(session)

        #expect(session.phase == .finished)
        let result = try #require(session.result)
        #expect(result.correctCount == 5)
        #expect(result.durationSec == 60)
        #expect(result.minutesEarned == 10)
        #expect(result.decision.denial == nil)
        #expect(result.requiredCorrect == 4)

        let saved = try attempts()
        #expect(saved.count == 1)
        let attempt = try #require(saved.first)
        #expect(attempt.child === child)
        #expect(attempt.correctCount == 5)
        #expect(attempt.totalCount == 5)
        #expect(attempt.durationSec == 60)
        #expect(attempt.minutesEarned == 10)
        #expect(attempt.bonusMinutes == 0)
        #expect(!attempt.bonusApplied)
        #expect(attempt.denialReason == nil)
        #expect(attempt.itemIDs == session.questions.map(\.id))
        #expect(attempt.questionKeys == session.questions.map(\.questionKey).sorted())
        #expect(attempt.answers == session.questions.map(\.answerIndex))

        let all = try masteries()
        #expect(all.count == 5)
        #expect(Set(all.map(\.notionKey)) == Set(session.questions.compactMap(\.notionKey)))
        for mastery in all {
            #expect(mastery.leitnerBox == 2)
            #expect(mastery.nextReview == QuizClock.date(day: 2))
            #expect(mastery.streakCorrect == 1)
            #expect(mastery.child === child)
        }
    }

    @Test("4/5 still passes; the missed notion goes back to box 1, due tomorrow")
    func oneWrong() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        play(session, wrong: [0])

        #expect(session.result?.minutesEarned == 10)
        #expect(try attempts().first?.answers.first != session.questions[0].answerIndex)
        let missed = try #require(try masteries().first { $0.notionKey == key(Self.moliere) })
        #expect(missed.leitnerBox == 1)
        #expect(missed.nextReview == QuizClock.date(day: 1))
        #expect(missed.streakCorrect == 0)
    }

    @Test("3/5: belowThreshold, 0 min, attempt kept, mastery still updated")
    func belowThreshold() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        play(session, wrong: [0, 1])

        #expect(session.result?.decision.denial == .belowThreshold)
        #expect(session.result?.minutesEarned == 0)
        let attempt = try #require(try attempts().first)
        #expect(attempt.minutesEarned == 0)
        #expect(attempt.denialReason == RewardDenial.belowThreshold.rawValue)
        #expect(try masteries().count == 5)
    }

    @Test("under 30 s: tooFast")
    func tooFast() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        play(session, seconds: 10)
        #expect(session.result?.decision.denial == .tooFast)
        #expect(try attempts().first?.denialReason == RewardDenial.tooFast.rawValue)
    }

    // MARK: Parent config (3.7)

    @Test("a thin bank draws fewer questions than the minimum: tooShort, progress still recorded")
    func tooShortQuiz() throws {
        let child = makeChild()
        for theme in [Self.moliere, Self.pythagore, Self.revolution] { addItem(theme) }
        try context.save()

        let session = makeSession(child)
        #expect(session.questions.count == 3)
        play(session)

        let result = try #require(session.result)
        #expect(result.decision.denial == .tooShort)
        #expect(result.minutesEarned == 0)
        #expect(result.minQuestionCount == 5)
        #expect(result.xpEarned > 0)
        let attempt = try #require(try attempts().first)
        #expect(attempt.denialReason == RewardDenial.tooShort.rawValue)
        #expect(attempt.minutesEarned == 0)
        #expect(try masteries().count == 3)
    }

    @Test("the session scores with the config it is given (minimum 3, cap 8)")
    func readsConfig() throws {
        let child = makeChild()
        for theme in [Self.moliere, Self.pythagore, Self.revolution] { addItem(theme) }
        try context.save()

        var config = RewardConfig.default
        config.minQuestionCount = 3
        config.dailyCap = 8
        let session = makeSession(child, config: config)
        play(session)
        #expect(session.result?.decision.denial == nil)
        #expect(session.result?.minutesEarned == 8)
        #expect(session.result?.minQuestionCount == 3)
    }

    @Test("a stored config round-trips into the session")
    func storedConfig() throws {
        let suite = "QuizSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var stored = RewardConfig.default
        stored.passThreshold = 0.6
        RewardConfigStore.save(stored, defaults: defaults)

        let child = makeChild()
        addPlannedBank()
        try context.save()
        let session = makeSession(child, config: RewardConfigStore.load(defaults: defaults))
        play(session, wrong: [0, 1])   // 3/5: passes at 3/5
        #expect(session.result?.decision.denial == nil)
        #expect(session.result?.requiredCorrect == 3)
    }

    @Test("second passed quiz of the day earns the second tier (5 min)")
    func secondTier() throws {
        let child = makeChild()
        addPlannedBank()
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: 0, hour: 17), itemIDs: [],
                                   questionKeys: ["other-a", "other-b"], answers: [0, 0], correctCount: 2,
                                   totalCount: 2, durationSec: 60, minutesEarned: 10, bonusApplied: false))
        try context.save()

        let session = makeSession(child)
        play(session)
        #expect(session.result?.minutesEarned == 5)
        #expect(try attempts().count == 2)
    }

    @Test("a due notion comes first and its mastery is updated in place")
    func dueNotionUpdatedInPlace() throws {
        let child = makeChild()
        addPlannedBank()
        let existing = NotionMastery(child: child, notionKey: key(Self.calcul), now: QuizClock.now,
                                     calendar: QuizClock.calendar)
        existing.leitnerBox = 2
        context.insert(existing)
        try context.save()

        let session = makeSession(child)
        #expect(session.questions.first?.theme == Self.calcul.1)
        play(session)

        let forCalcul = try masteries().filter { $0.notionKey == key(Self.calcul) }
        #expect(forCalcul.count == 1)
        #expect(forCalcul.first?.leitnerBox == 3)
        #expect(forCalcul.first?.nextReview == QuizClock.date(day: 4))
    }

    @Test("finish runs once")
    func finishOnce() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        play(session)
        session.advance()
        session.advance()
        #expect(try attempts().count == 1)
    }

    @Test("advance without an answer is a no-op")
    func advanceNeedsAnswer() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        let session = makeSession(child)
        session.advance()
        session.advance()
        #expect(session.currentIndex == 0)
        #expect(session.phase == .inProgress)
        #expect(session.answers.allSatisfy { $0 == -1 })
        #expect(try attempts().isEmpty)
    }

    @Test("two passed quizzes the same day: a notion not due yet stays in box 2")
    func notDueNotPromoted() throws {
        let child = makeChild()
        addPlannedBank()
        try context.save()

        play(makeSession(child))
        play(makeSession(child, seed: 99))

        let all = try masteries()
        #expect(Set(all.map(\.notionKey)).count == all.count)
        for mastery in all {
            #expect(mastery.leitnerBox == 2)
            #expect(mastery.nextReview == QuizClock.date(day: 2))
        }
    }
}

/// Série and cagnotte counters (`QuizStreak`).
@Suite("QuizStreak")
struct QuizStreakTests {
    private func attempt(day: Int, passed: Bool = true, minutes: Int = 10) -> AttemptSnapshot {
        AttemptSnapshot(date: QuizClock.date(day: day, hour: 18), questionKeys: ["k\(day)"],
                        correctCount: passed ? 5 : 1, totalCount: 5, durationSec: 60,
                        minutesEarned: passed ? minutes : 0, passed: passed)
    }

    private func streak(_ attempts: [AttemptSnapshot]) -> Int {
        QuizStreak.current(attempts: attempts, now: QuizClock.now, calendar: QuizClock.calendar)
    }

    @Test("no attempt → 0")
    func empty() { #expect(streak([]) == 0) }

    @Test("today, yesterday, the day before, then a gap → 3")
    func consecutiveFromToday() {
        #expect(streak([attempt(day: 0), attempt(day: -1), attempt(day: -2), attempt(day: -4)]) == 3)
    }

    @Test("nothing yet today: the série still counts from yesterday")
    func countsFromYesterday() {
        #expect(streak([attempt(day: -1), attempt(day: -2)]) == 2)
    }

    @Test("a failed quiz today does not count, nor break the série")
    func failedDoesNotCount() {
        #expect(streak([attempt(day: 0, passed: false), attempt(day: -1)]) == 1)
    }

    @Test("last passed quiz two days ago → broken (0)")
    func broken() {
        #expect(streak([attempt(day: -2), attempt(day: -3)]) == 0)
    }

    @Test("several quizzes on one day count once")
    func sameDayOnce() {
        #expect(streak([attempt(day: 0), attempt(day: 0), attempt(day: -1)]) == 2)
    }

    @Test("a capped success (passed, 0 min) keeps the série")
    func cappedSuccessCounts() {
        #expect(streak([attempt(day: 0, minutes: 0), attempt(day: -1)]) == 2)
    }

    @Test("cagnotte = today's credited minutes only")
    func minutesToday() {
        let attempts = [attempt(day: 0, minutes: 10), attempt(day: 0, minutes: 5),
                        attempt(day: 0, passed: false), attempt(day: -1, minutes: 10)]
        #expect(QuizStreak.minutesEarnedToday(attempts: attempts, now: QuizClock.now,
                                              calendar: QuizClock.calendar) == 15)
    }
}

/// Child-mode result copy: tutoiement, never a promise of unlocking.
@Suite("QuizResult copy")
struct QuizResultCopyTests {
    @Test("every denial has child-addressed copy with no unlock promise", arguments: [
        RewardDenial.belowThreshold, .tooFast, .identicalReplay, .tiersExhausted, .capReached, .emptyQuiz,
        .tooShort,
    ])
    @MainActor
    func copy(denial: RewardDenial) {
        let result = QuizSessionResult(correctCount: 2, totalCount: 5, durationSec: 40,
                                       decision: .denied(denial), requiredCorrect: 4)
        let text = QuizResultView.message(for: result).lowercased()
        #expect(!text.isEmpty)
        #expect(!text.contains("débloqu"))
        #expect(!text.contains("vous"))
        #expect(!text.contains("votre"))
        if denial == .belowThreshold { #expect(text.contains("4 bonnes réponses")) }
    }

    @Test("too short: says how many questions were played and how many are needed")
    @MainActor
    func tooShortCopy() {
        let result = QuizSessionResult(correctCount: 2, totalCount: 2, durationSec: 40,
                                       decision: .denied(.tooShort), requiredCorrect: 2, minQuestionCount: 5)
        let text = QuizResultView.message(for: result)
        #expect(text.contains("2 questions"))
        #expect(text.contains("il en faut 5"))
        #expect(QuizResultView.title(for: result) == "Sans faute, bravo !")
    }

    @Test("capped successes are celebrated, not framed as failures")
    @MainActor
    func cappedIsSuccess() {
        let result = QuizSessionResult(correctCount: 5, totalCount: 5, durationSec: 60,
                                       decision: .denied(.capReached), requiredCorrect: 4)
        #expect(QuizResultView.title(for: result) == "Sans faute, bravo !")
        #expect(QuizResultView.symbol(for: result) == "star.fill")
    }
}
