import Foundation
import Observation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "ParentQuizSession")

/// One question of a finished parent quiz, for the correction list.
struct ParentQuizReviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let subject: String?
    let theme: String?
    let rightAnswer: String
    /// The parent's choice, nil when skipped.
    let chosenAnswer: String?
    let isCorrect: Bool
    let explanation: String?
    /// Bank text may carry inline Markdown; generated text is shown verbatim.
    let isGenerated: Bool
}

/// Outcome of a finished parent quiz, for `ParentQuizView`.
struct ParentQuizResult: Equatable, Sendable {
    let correctCount: Int
    let totalCount: Int
    let durationSec: Int
    let review: [ParentQuizReviewItem]
    /// Where the child stands on the notions of this quiz.
    let comparison: ParentQuizComparison
}

/// Where the child stands on the notions a parent quiz covered, from the
/// child's `NotionMastery` rows (same thresholds as `RevisionSummary`:
/// mastered = `SpacedRepetition.isMastered`, en cours = box 3, fragile =
/// box ≤ 2). Pure.
///
/// V1 has no sync between devices: the masteries exist only on the device
/// where the child revises, so on the parent's own phone every notion is
/// « pas encore travaillée » and `hasChildData` is false.
struct ParentQuizComparison: Equatable, Sendable {
    let notionCount: Int
    let mastered: Int
    let inProgress: Int
    let fragile: Int
    var notStarted: Int { notionCount - mastered - inProgress - fragile }
    var hasChildData: Bool { mastered + inProgress + fragile > 0 }

    static func make(notionKeys: [String], masteries: [MasterySnapshot]) -> ParentQuizComparison {
        let keys = Set(notionKeys.filter { !$0.isEmpty })
        let byKey = Dictionary(masteries.map { ($0.notionKey, $0) }, uniquingKeysWith: { first, _ in first })
        var mastered = 0, inProgress = 0, fragile = 0
        for key in keys {
            guard let mastery = byKey[key] else { continue }
            if SpacedRepetition.isMastered(mastery) {
                mastered += 1
            } else if mastery.leitnerBox == 3 {
                inProgress += 1
            } else {
                fragile += 1
            }
        }
        return ParentQuizComparison(notionCount: keys.count, mastered: mastered,
                                    inProgress: inProgress, fragile: fragile)
    }

    /// Parent tone (vouvoiement), the child named by first name. Nil when
    /// the quiz had no notion (questions without a theme).
    func sentence(firstName: String) -> String? {
        guard notionCount > 0 else { return nil }
        guard hasChildData else {
            return "Les révisions de \(firstName) ne sont pas sur cet appareil : la comparaison "
                + "s'affiche sur l'appareil où votre enfant fait ses quiz."
        }
        var parts: [String] = []
        if mastered > 0 { parts.append("\(mastered) \(mastered == 1 ? "maîtrisée" : "maîtrisées")") }
        if inProgress > 0 { parts.append("\(inProgress) en cours") }
        if fragile > 0 { parts.append("\(fragile) \(fragile == 1 ? "fragile" : "fragiles")") }
        if notStarted > 0 {
            parts.append("\(notStarted) pas encore \(notStarted == 1 ? "travaillée" : "travaillées")")
        }
        let notions = notionCount == 1 ? "la notion de ce quiz" : "les \(notionCount) notions de ce quiz"
        return "Pour \(firstName), sur \(notions) : " + Self.joined(parts) + "."
    }

    private static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " et " + (parts.last ?? "")
    }
}

/// The parent's last results on one child's programme (`RevisionsView` card). Pure.
struct ParentQuizHistory: Equatable, Sendable {
    let quizCount: Int
    let lastDate: Date?
    let lastCorrect: Int
    let lastTotal: Int

    init(attempts: [(date: Date, correct: Int, total: Int)]) {
        let last = attempts.max { $0.date < $1.date }
        quizCount = attempts.count
        lastDate = last?.date
        lastCorrect = last?.correct ?? 0
        lastTotal = last?.total ?? 0
    }

    @MainActor
    init(child: Child) {
        self.init(attempts: child.parentQuizAttempts.map { (date: $0.date, correct: $0.correctCount, total: $0.totalCount) })
    }
}

/// A parent plays the child's quiz: same draw as `QuizSession` (homework due
/// within 72 h, the child's due notions, then the programme of the child's
/// level, on-device questions for homework the bank cannot fill), so the
/// parent is tested on exactly what the child is working on.
///
/// Nothing here touches the child's progress: no `RewardPolicy`, no reward
/// ledger, no XP, no série, no `NotionMastery` update, no `QuizAttempt`.
/// The only write is one `ParentQuizAttempt`.
@MainActor
@Observable
final class ParentQuizSession: QuizPlaying {
    enum Phase: Equatable {
        /// No reviewed question for this level (or level outside 6e → Tle).
        case empty
        case inProgress
        case finished
    }

    private(set) var phase: Phase
    private(set) var questions: [QuizQuestion]
    /// Chosen index per question, -1 = not answered.
    private(set) var answers: [Int]
    private(set) var currentIndex = 0
    private(set) var result: ParentQuizResult?
    let startedAt: Date

    private let child: Child
    private let modelContext: ModelContext
    private let now: @Sendable () -> Date

    /// Same parameters as `QuizSession.init`, minus the reward ones.
    init(
        child: Child,
        modelContext: ModelContext,
        curriculum: CurriculumSnapshot = .bundled,
        calendar: Calendar = .current,
        seed: UInt64 = UInt64.random(in: UInt64.min ... UInt64.max),
        now: @escaping @Sendable () -> Date = { Date() },
        generated: [String: QuizQuestion] = [:]
    ) {
        self.child = child
        self.modelContext = modelContext
        self.now = now
        let start = now()
        self.startedAt = start
        let drawn = QuizSession.draw(for: child, in: modelContext, curriculum: curriculum, calendar: calendar,
                                     seed: seed, now: start, generated: generated,
                                     playedKeys: ParentQuizSession.playedKeys(of: child))
        self.questions = drawn
        self.answers = Array(repeating: -1, count: drawn.count)
        self.phase = drawn.isEmpty ? .empty : .inProgress
    }

    /// Like `QuizSession.make`: on-device questions for the homework slots
    /// the bank cannot fill, silent fallback to the bank, no network.
    static func make(
        child: Child,
        modelContext: ModelContext,
        curriculum: CurriculumSnapshot = .bundled,
        calendar: Calendar = .current,
        seed: UInt64 = UInt64.random(in: UInt64.min ... UInt64.max),
        now: @escaping @Sendable () -> Date = { Date() },
        generator: (any QuizGenerating)?,
        generationTimeout: Duration = QuizGenerator.defaultTimeout
    ) async -> ParentQuizSession {
        var generated: [String: QuizQuestion] = [:]
        if let generator {
            let requests = QuizSession.generationRequests(
                for: child, in: modelContext, curriculum: curriculum, calendar: calendar, seed: seed, now: now(),
                minBankQuestions: RewardConfig.default.minQuestionCount, playedKeys: playedKeys(of: child))
            if !requests.isEmpty {
                generator.prewarm()
                generated = await QuizGenerator.questions(for: requests, using: generator,
                                                          timeout: generationTimeout)
            }
        }
        return ParentQuizSession(child: child, modelContext: modelContext, curriculum: curriculum,
                                 calendar: calendar, seed: seed, now: now, generated: generated)
    }

    /// Every question the parent already played on this child's programme.
    static func playedKeys(of child: Child) -> Set<String> {
        Set(child.parentQuizAttempts.flatMap(\.questionKeys))
    }

    // MARK: - Playing

    var currentQuestion: QuizQuestion? {
        guard phase == .inProgress, questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    var currentAnswer: Int? {
        guard answers.indices.contains(currentIndex), answers[currentIndex] >= 0 else { return nil }
        return answers[currentIndex]
    }

    var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    @discardableResult
    func answer(_ choice: Int) -> Bool? {
        guard let question = currentQuestion, currentAnswer == nil,
              question.choices.indices.contains(choice) else { return nil }
        answers[currentIndex] = choice
        return choice == question.answerIndex
    }

    func advance() {
        guard phase == .inProgress, currentAnswer != nil else { return }
        if isLastQuestion {
            finish()
        } else {
            currentIndex += 1
        }
    }

    // MARK: - Finishing

    private func finish() {
        guard phase == .inProgress else { return }
        let end = now()
        let duration = max(0, Int(end.timeIntervalSince(startedAt)))
        let correctFlags = zip(questions, answers).map { $0.answerIndex == $1 }
        let correct = correctFlags.filter { $0 }.count
        let notionKeys = questions.map { $0.notionKey ?? "" }

        modelContext.insert(ParentQuizAttempt(
            child: child, date: end, questionKeys: questions.map(\.questionKey), notionKeys: notionKeys,
            answers: answers, correctCount: correct, totalCount: questions.count, durationSec: duration
        ))
        do {
            try modelContext.save()
        } catch {
            logger.error("Saving parent quiz attempt failed: \(error.localizedDescription, privacy: .public)")
        }

        let review = zip(questions, answers).map { question, chosen in
            ParentQuizReviewItem(
                id: question.id, question: question.question, subject: question.subject, theme: question.theme,
                rightAnswer: question.choices[question.answerIndex],
                chosenAnswer: question.choices.indices.contains(chosen) ? question.choices[chosen] : nil,
                isCorrect: chosen == question.answerIndex, explanation: question.explanation,
                isGenerated: question.isGenerated
            )
        }
        result = ParentQuizResult(
            correctCount: correct, totalCount: questions.count, durationSec: duration, review: review,
            comparison: ParentQuizComparison.make(notionKeys: notionKeys,
                                                  masteries: child.notionMasteries.map { MasterySnapshot($0) })
        )
        phase = .finished
    }
}
