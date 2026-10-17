import Foundation
import Observation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "QuizSession")

/// Small seeded generator (SplitMix64) so the item draw is reproducible in
/// tests. Not for anything security-related.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One question as played: a value copy of the `QuizItem` fields the views
/// need, so a bank sync deleting the row mid-quiz cannot crash the screen.
struct QuizQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let questionKey: String
    let question: String
    /// Stored order: celyn already places the right answer at a drawn
    /// position, so choices are never reshuffled (that would desync
    /// `answerIndex`).
    let choices: [String]
    let answerIndex: Int
    let explanation: String?
    let subject: String?
    let theme: String?
    /// `NotionKey` of the item's theme (Leitner granularity), nil when the
    /// item has no subject or theme.
    let notionKey: String?
    /// `QuizItem.difficulty` (1…3), for the XP bonus (`Gamification`).
    var difficulty: Int = 1
    /// Generated on device from the child's homework (3.3, `QuizGenerator`).
    /// Ephemeral: no `QuizItem` row backs it. Scored like any other question.
    var isGenerated = false
}

/// What the question screen needs from a quiz being played, shared by the
/// child's `QuizSession` and the parent's `ParentQuizSession` so both play
/// exactly the same questions the same way (`QuizQuestionScreen`).
@MainActor
protocol QuizPlaying: AnyObject, Observable {
    var questions: [QuizQuestion] { get }
    var currentIndex: Int { get }
    /// The answer chosen for the current question, nil until answered.
    var currentAnswer: Int? { get }
    var isLastQuestion: Bool { get }
    /// Records the choice for the current question (first tap only).
    /// Returns whether it was right, nil when ignored.
    @discardableResult func answer(_ choice: Int) -> Bool?
    /// Next question, or the end of the quiz after the last one.
    func advance()
}

/// What a quiz chosen by the child is about: one subject, or one theme of
/// it. Nil (the default) is the quiz of the day.
struct QuizFocus: Equatable, Hashable, Sendable {
    /// Curriculum subject name (or a Pronote label, alias-aware).
    let subject: String
    /// Exact `CurriculumTheme.theme`, nil = the whole subject.
    var theme: String?
}

/// Where a notion played in this quiz stands after it (`QuizResultView`,
/// « Tes notions »).
struct NotionOutcome: Equatable, Sendable, Identifiable {
    let notionKey: String
    let theme: String
    /// Leitner box after the quiz (4+ = mastered).
    let box: Int
    /// All of its items right in this quiz.
    let correct: Bool
    let nextReview: Date
    var id: String { notionKey }
    var isMastered: Bool { box >= 4 }
}

/// Outcome of a finished quiz, for `QuizResultView`.
struct QuizSessionResult: Equatable, Sendable {
    let correctCount: Int
    let totalCount: Int
    let durationSec: Int
    let decision: RewardDecision
    /// Right answers needed to earn minutes (`RewardConfig.passThreshold`).
    let requiredCorrect: Int
    /// Questions a quiz needs to earn minutes (`RewardConfig.minQuestionCount`),
    /// for the `.tooShort` message.
    var minQuestionCount: Int = RewardConfig.default.minQuestionCount
    /// XP of this quiz (`Gamification` table; 0 when a farming guard caught
    /// it: too fast, or an identical replay of any earlier attempt).
    var xpEarned: Int = 0
    /// Subject levels reached with this quiz.
    var levelUps: [SubjectLevelUp] = []
    /// Notions played, in quiz order.
    var notions: [NotionOutcome] = []
    /// Badges this quiz unlocked.
    var newBadges: [EarnedBadge] = []
    var minutesEarned: Int { decision.total }
}

/// One quiz run for one child: draws up to `questionCount` reviewed questions
/// of the child's level from the local bank (no network here, the bank is
/// filled by `QuizBankStore`), records answers, then on `finish()` scores the
/// attempt with `RewardPolicy`, updates `NotionMastery` through
/// `SpacedRepetition` and saves a `QuizAttempt`.
///
/// The minutes are recorded on the attempt, then handed to `onMinutesEarned`
/// (3.4: `QuizView` passes `RewardUnlockService.credit`, which alone decides
/// against the class-hours lock). Tests leave it nil, so no session ever
/// touches the app group ledger.
@MainActor
@Observable
final class QuizSession: QuizPlaying {
    static let questionCount = 5

    enum Phase: Equatable {
        /// No reviewed question for this level (or level outside 6e → Tle).
        case empty
        case inProgress
        case finished
    }

    private(set) var phase: Phase
    private(set) var questions: [QuizQuestion]
    /// Chosen index per question, -1 = not answered (stored as skipped).
    private(set) var answers: [Int]
    private(set) var currentIndex = 0
    private(set) var result: QuizSessionResult?
    let startedAt: Date

    private let child: Child
    private let modelContext: ModelContext
    private let curriculum: CurriculumSnapshot
    private let config: RewardConfig
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let onMinutesEarned: (@MainActor (Int, Date) -> Void)?

    /// - Parameters:
    ///   - seed: drives the draw among equally ranked items. Fixed in tests;
    ///     random by default so two quizzes in a row differ.
    ///   - config: the parent's rules. Callers pass `RewardConfigStore.load()`
    ///     (app group) explicitly; the default is `.default` so no caller
    ///     silently reads the shared suite (test isolation).
    ///   - onMinutesEarned: called once after the attempt is saved, with the
    ///     minutes earned (> 0 only) and the finish date. Nil by default for
    ///     the same isolation reason.
    ///   - generated: on-device questions keyed by `HomeworkSnapshot.dedupKey`
    ///     (`QuizSession.make`), used only for homework slots the bank cannot
    ///     fill. Empty by default: the synchronous init never generates.
    init(
        child: Child,
        modelContext: ModelContext,
        curriculum: CurriculumSnapshot = .bundled,
        config: RewardConfig = .default,
        calendar: Calendar = .current,
        seed: UInt64 = UInt64.random(in: UInt64.min ... UInt64.max),
        now: @escaping @Sendable () -> Date = { Date() },
        onMinutesEarned: (@MainActor (Int, Date) -> Void)? = nil,
        generated: [String: QuizQuestion] = [:],
        focus: QuizFocus? = nil
    ) {
        self.onMinutesEarned = onMinutesEarned
        self.child = child
        self.modelContext = modelContext
        self.curriculum = curriculum
        self.config = config
        self.calendar = calendar
        self.now = now
        let start = now()
        self.startedAt = start
        let drawn = Self.draw(for: child, in: modelContext, curriculum: curriculum, calendar: calendar,
                              seed: seed, now: start, generated: generated, focus: focus)
        self.questions = drawn
        self.answers = Array(repeating: -1, count: drawn.count)
        self.phase = drawn.isEmpty ? .empty : .inProgress
    }

    /// 3.3: like `init`, but first asks `generator` (on device) for a
    /// question on each homework slot (due ≤ 72 h) that has no bank item,
    /// within `generationTimeout` for the whole quiz. Any failure, refusal,
    /// rejected output or timeout falls back silently to the bank /
    /// programme draw. No network call on this path. Nothing is generated
    /// unless the bank alone already draws `config.minQuestionCount`
    /// questions (with no reviewed item the quiz stays `.empty`): generation
    /// completes a bank quiz, it never replaces the bank, and it can never
    /// turn a thin bank's `.tooShort` quiz into one that earns minutes.
    static func make(
        child: Child,
        modelContext: ModelContext,
        curriculum: CurriculumSnapshot = .bundled,
        config: RewardConfig = .default,
        calendar: Calendar = .current,
        seed: UInt64 = UInt64.random(in: UInt64.min ... UInt64.max),
        now: @escaping @Sendable () -> Date = { Date() },
        onMinutesEarned: (@MainActor (Int, Date) -> Void)? = nil,
        generator: (any QuizGenerating)?,
        generationTimeout: Duration = QuizGenerator.defaultTimeout,
        focus: QuizFocus? = nil
    ) async -> QuizSession {
        var generated: [String: QuizQuestion] = [:]
        if let generator {
            let requests = generationRequests(for: child, in: modelContext, curriculum: curriculum,
                                              calendar: calendar, seed: seed, now: now(),
                                              minBankQuestions: config.minQuestionCount, focus: focus)
            if !requests.isEmpty {
                generator.prewarm()
                generated = await QuizGenerator.questions(for: requests, using: generator,
                                                          timeout: generationTimeout)
            }
        }
        return QuizSession(child: child, modelContext: modelContext, curriculum: curriculum, config: config,
                           calendar: calendar, seed: seed, now: now, onMinutesEarned: onMinutesEarned,
                           generated: generated, focus: focus)
    }

    /// Generation requests for the homework slots the bank cannot fill, in
    /// slot order (tomorrow first), at most `QuizGenerator.maxGeneratedPerQuiz`.
    /// Empty when the bank-only draw has fewer than `minBankQuestions`.
    ///
    /// `playedKeys`: see `draw` (the parent quiz passes its own history).
    static func generationRequests(for child: Child, in context: ModelContext, curriculum: CurriculumSnapshot,
                                   calendar: Calendar, seed: UInt64, now: Date,
                                   minBankQuestions: Int = 1,
                                   playedKeys: Set<String>? = nil,
                                   focus: QuizFocus? = nil) -> [QuizGenerationRequest] {
        let selection = select(for: child, in: context, curriculum: curriculum, calendar: calendar,
                               seed: seed, now: now, generated: [:], playedKeys: playedKeys, focus: focus)
        guard !selection.unmatchedHomework.isEmpty,
              selection.questions.count >= max(1, minBankQuestions) else { return [] }
        let level = CurriculumService.canonicalLevel(child.grade)
        let homework = child.homework.map { HomeworkSnapshot($0, calendar: calendar) }
        return selection.unmatchedHomework.prefix(QuizGenerator.maxGeneratedPerQuiz).compactMap { gap in
            guard let key = gap.slot.homeworkKey,
                  let snapshot = homework.first(where: { $0.dedupKey == key }),
                  !snapshot.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return QuizGenerationRequest(level: level, slot: gap.slot, homework: snapshot,
                                         bankAnswers: gap.bankAnswers, calendar: calendar)
        }
    }

    // MARK: - Playing

    var currentQuestion: QuizQuestion? {
        guard phase == .inProgress, questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    /// The answer chosen for the current question, nil until answered.
    var currentAnswer: Int? {
        guard answers.indices.contains(currentIndex), answers[currentIndex] >= 0 else { return nil }
        return answers[currentIndex]
    }

    var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    /// Records the choice for the current question (first tap only: feedback
    /// is immediate, so the answer cannot be changed afterwards). Returns
    /// whether it was right, nil when ignored.
    @discardableResult
    func answer(_ choice: Int) -> Bool? {
        guard let question = currentQuestion, currentAnswer == nil,
              question.choices.indices.contains(choice) else { return nil }
        answers[currentIndex] = choice
        return choice == question.answerIndex
    }

    /// Next question, or `finish()` after the last one. A no-op until the
    /// current question is answered (a re-entrant tap or an accessibility
    /// action must not skip a question and score it wrong).
    func advance() {
        guard phase == .inProgress, currentAnswer != nil else { return }
        if isLastQuestion {
            finish()
        } else {
            currentIndex += 1
        }
    }

    // MARK: - Finishing

    /// Scores and persists the attempt. Runs once, only from `advance()` on
    /// the last answered question.
    private func finish() {
        guard phase == .inProgress else { return }
        let end = now()
        let duration = max(0, Int(end.timeIntervalSince(startedAt)))
        let correct = zip(questions, answers).filter { $0.answerIndex == $1 }.count
        let history = child.quizAttempts.map { AttemptSnapshot($0) }

        let snapshot = AttemptSnapshot(date: end, questionKeys: questions.map(\.questionKey),
                                       correctCount: correct, totalCount: questions.count,
                                       durationSec: duration)
        let decision = RewardPolicy.evaluate(
            attempt: snapshot,
            history: history,
            homeworkTomorrow: child.homework.map { HomeworkSnapshot($0, calendar: calendar) },
            scheduleTomorrow: child.schedule.map { ScheduleSnapshot($0) },
            config: config, now: end, calendar: calendar
        )

        // XP per question, frozen now (subject + difficulty are not kept on
        // the attempt otherwise). The farming guards are checked on their
        // own, not through `decision.denial` (a fast or replayed attempt
        // below the threshold is denied as `.belowThreshold` first).
        let itemXP = Gamification.questionXP(
            difficulties: questions.map(\.difficulty),
            correct: zip(questions, answers).map { $0.answerIndex == $1 },
            earnsXP: Gamification.earnsXP(attempt: snapshot, history: history, config: config,
                                          now: end, calendar: calendar)
        )
        let subjects = questions.map { $0.subject ?? "" }
        let xpBefore = Gamification.subjectXP(attempts: history)
        let badgesBefore = Set(GamificationStore.badges(for: child, now: end, calendar: calendar,
                                                        curriculum: curriculum).map(\.id))

        let attempt = QuizAttempt(
            child: child, date: end,
            itemIDs: questions.map(\.id), questionKeys: questions.map(\.questionKey),
            answers: answers, correctCount: correct, totalCount: questions.count, durationSec: duration,
            minutesEarned: decision.total, bonusApplied: decision.bonus > 0, bonusMinutes: decision.bonus,
            denialReason: decision.denial?.rawValue,
            itemSubjects: subjects, itemXP: itemXP
        )
        modelContext.insert(attempt)

        // A passed quiz closes the current gap: the jokers that bridge it are
        // spent now, in the same save (pending until then, `Gamification`).
        if decision.countsAsSuccess {
            let passedNow = AttemptSnapshot(date: end, questionKeys: snapshot.questionKeys,
                                            correctCount: correct, totalCount: questions.count,
                                            durationSec: duration, passed: true)
            GamificationStore.recordDueJokers(for: child, attempts: history + [passedNow], in: modelContext,
                                              now: end, calendar: calendar, save: false)
        }

        // Mastery moves whatever the reward decision (a rushed or replayed
        // quiz still tells us what the child knows).
        updateMastery(at: end)

        var saved = true
        do {
            try modelContext.save()
        } catch {
            saved = false
            logger.error("Saving quiz attempt failed: \(error.localizedDescription, privacy: .public)")
        }

        // Same tolerance as `RewardPolicy` (0.8 * 5 = 4.000000000000001).
        let required = Int((config.passThreshold * Double(questions.count) - 1e-9).rounded(.up))
        let thisAttempt = AttemptSnapshot(date: end, questionKeys: [], correctCount: correct,
                                          totalCount: questions.count, durationSec: duration,
                                          itemSubjects: subjects, itemXP: itemXP)
        let xpAfter = Gamification.subjectXP(attempts: history + [thisAttempt])
        result = QuizSessionResult(correctCount: correct, totalCount: questions.count,
                                   durationSec: duration, decision: decision,
                                   requiredCorrect: max(0, required),
                                   minQuestionCount: config.minQuestionCount,
                                   xpEarned: thisAttempt.xpEarned,
                                   levelUps: Gamification.levelUps(before: xpBefore, after: xpAfter),
                                   notions: notionOutcomes(),
                                   newBadges: GamificationStore.badges(for: child, now: end, calendar: calendar,
                                                                       curriculum: curriculum)
                                       .filter { !badgesBefore.contains($0.id) })
        phase = .finished

        // 3.4: credit the reward ledger only once the attempt is persisted —
        // an unsaved attempt is missing from the history RewardPolicy uses for
        // replay / tier / cap checks, so a retry could be credited again.
        if saved, decision.total > 0 {
            onMinutesEarned?(decision.total, end)
        }
    }

    /// One Leitner review per notion (never per question), all of its items
    /// folded with `SpacedRepetition.notionOutcome`. A notion only moves up
    /// when it is due (a new notion is due today): the top-up and « Un autre
    /// quiz » can replay a notion scheduled for later, and promoting it then
    /// would skip the 1/2/4/8/16-day spacing. A miss still counts.
    private func updateMastery(at date: Date) {
        var outcomes: [String: [Bool]] = [:]
        var order: [String] = []
        for (question, chosen) in zip(questions, answers) {
            guard let key = question.notionKey else { continue }
            if outcomes[key] == nil { order.append(key) }
            outcomes[key, default: []].append(chosen == question.answerIndex)
        }
        for key in order {
            let correct = SpacedRepetition.notionOutcome(itemsCorrect: outcomes[key] ?? [])
            let mastery: NotionMastery
            if let existing = child.notionMasteries.first(where: { $0.notionKey == key }) {
                mastery = existing
            } else {
                mastery = NotionMastery(child: child, notionKey: key, now: date, calendar: calendar)
                modelContext.insert(mastery)
            }
            let current = MasterySnapshot(mastery)
            if correct, !SpacedRepetition.isDue(current, now: date, calendar: calendar) { continue }
            let reviewed = SpacedRepetition.review(current, correct: correct,
                                                   now: date, calendar: calendar)
            mastery.apply(reviewed, reviewedAt: date)
        }
    }

    /// The notions of this quiz as they stand after `updateMastery`, in quiz
    /// order.
    private func notionOutcomes() -> [NotionOutcome] {
        var seen = Set<String>()
        var outcomes: [NotionOutcome] = []
        for question in questions {
            guard let key = question.notionKey, let theme = question.theme, seen.insert(key).inserted,
                  let mastery = child.notionMasteries.first(where: { $0.notionKey == key }) else { continue }
            let played = zip(questions, answers).filter { $0.0.notionKey == key }
            outcomes.append(NotionOutcome(
                notionKey: key, theme: theme, box: mastery.leitnerBox,
                correct: SpacedRepetition.notionOutcome(itemsCorrect: played.map { $0.0.answerIndex == $0.1 }),
                nextReview: mastery.nextReview))
        }
        return outcomes
    }

    // MARK: - Draw

    /// Reviewed, well-formed MCQ items of `level`, in a stable order.
    static func availableItems(level: String, in context: ModelContext, now: Date) -> [QuizItem] {
        let descriptor = FetchDescriptor<QuizItem>(predicate: #Predicate { $0.reviewed == true })
        let fetched = (try? context.fetch(descriptor)) ?? []
        return fetched
            .filter { item in
                item.level == level
                    && item.format == .mcq
                    && item.choices.count == 4
                    && item.choices.indices.contains(item.answerIndex)
                    && (item.validUntil.map { $0 >= now } ?? true)
            }
            .sorted { $0.questionKey < $1.questionKey }
    }

    /// Number of playable questions for a child's level (home screen empty state).
    /// With `focus`, only the items of that subject (or theme): the child app
    /// offers a subject or theme quiz only when it would not open empty.
    static func availableCount(for child: Child, in context: ModelContext, now: Date = Date(),
                               focus: QuizFocus? = nil) -> Int {
        let level = CurriculumService.canonicalLevel(child.grade)
        guard CurriculumService.revisionLevels.contains(level) else { return 0 }
        let items = availableItems(level: level, in: context, now: now)
        guard let focus else { return items.count }
        let slot = focusSlot(focus)
        return items.filter { matches($0, slot) }.count
    }

    /// `availableCount` for several focuses, with one fetch (the child app
    /// lists every subject / theme it can offer).
    static func availableCounts(for child: Child, in context: ModelContext, now: Date = Date(),
                                focuses: [QuizFocus]) -> [Int] {
        let level = CurriculumService.canonicalLevel(child.grade)
        guard CurriculumService.revisionLevels.contains(level) else { return focuses.map { _ in 0 } }
        let items = availableItems(level: level, in: context, now: now)
        return focuses.map { focus in
            let slot = focusSlot(focus)
            return items.filter { matches($0, slot) }.count
        }
    }

    /// Picks the questions:
    /// 1. `QuizSourceSelector` plans the slots (homework ≤ 72 h, due notions,
    ///    programme). One item per slot, matched on subject + theme (subject
    ///    only when the slot has no theme). A homework slot with no bank item
    ///    takes its on-device question from `generated` when there is one
    ///    (3.3, at most `QuizGenerator.maxGeneratedPerQuiz`).
    /// 2. Remaining places are topped up from the rest of the level's bank,
    ///    filtered by `QuizSourceSelector.programmeEligibility` (3.8: only
    ///    themes the child has seen when the subject has a position, else the
    ///    current and earlier periods).
    /// Within each pool, items never played in a passed attempt come first
    /// (a thin bank would otherwise make every quiz an identical replay), and
    /// ties are broken by the seeded shuffle.
    ///
    /// `playedKeys` replaces the « already played » set (the child's passed
    /// attempts when nil): the parent quiz passes the parent's own history,
    /// so it plans the same slots as the child but prefers questions the
    /// parent has not seen.
    static func draw(for child: Child, in context: ModelContext, curriculum: CurriculumSnapshot,
                     calendar: Calendar, seed: UInt64, now: Date,
                     generated: [String: QuizQuestion] = [:],
                     playedKeys: Set<String>? = nil,
                     focus: QuizFocus? = nil) -> [QuizQuestion] {
        select(for: child, in: context, curriculum: curriculum, calendar: calendar, seed: seed, now: now,
               generated: generated, playedKeys: playedKeys, focus: focus).questions
    }

    /// The slots the next quiz plans (homework, due notions, programme) and
    /// the programme position they were planned from. The child home shows
    /// both (« Quiz du jour » composition, « En classe en ce moment »); the
    /// draw fills the same slots from the bank, so a slot the bank cannot
    /// fill is topped up from the rest of the level.
    ///
    /// Programme position (3.8): computed here, on the device, from the
    /// cahier de textes rows and homework this device synced. Never stored.
    static func plan(for child: Child, curriculum: CurriculumSnapshot = .bundled,
                     calendar: Calendar = .current, now: Date = Date()) -> (plan: QuizPlan, position: ProgrammePosition) {
        let level = CurriculumService.canonicalLevel(child.grade)
        let homework = child.homework.map { HomeworkSnapshot($0, calendar: calendar) }
        let position = ProgrammePositionTracker.compute(
            level: level, specialties: child.specialties,
            lessons: child.lessonContents.map { LessonContentSnapshot($0) },
            homework: homework,
            curriculum: curriculum, now: now, calendar: calendar)
        let period = PeriodRank.currentPeriod(now: now, level: level, calendar: calendar)

        // `weakSubjects: []` for now: nothing computes them yet on the child device.
        let plan = QuizSourceSelector.plan(
            context: ChildRevisionContext(level: level, specialties: child.specialties, weakSubjects: []),
            homework: homework,
            masteries: child.notionMasteries.map { MasterySnapshot($0) },
            curriculum: curriculum, now: now, calendar: calendar,
            maxSlots: questionCount, currentPeriod: period, position: position
        )
        return (plan, position)
    }

    /// A homework slot no bank item could fill.
    struct HomeworkGap: Equatable {
        let slot: QuizPlanSlot
        /// Right answers of the bank items of the slot's level / subject /
        /// theme (already used ones included), for `QuizGenerationValidator`.
        let bankAnswers: [String]
    }

    private struct Selection {
        var questions: [QuizQuestion] = []
        var unmatchedHomework: [HomeworkGap] = []
    }

    private static func select(for child: Child, in context: ModelContext, curriculum: CurriculumSnapshot,
                               calendar: Calendar, seed: UInt64, now: Date,
                               generated: [String: QuizQuestion],
                               playedKeys playedOverride: Set<String>? = nil,
                               focus: QuizFocus? = nil) -> Selection {
        let level = CurriculumService.canonicalLevel(child.grade)
        guard CurriculumService.revisionLevels.contains(level) else { return Selection() }
        var items = availableItems(level: level, in: context, now: now)
        if items.isEmpty {
            // Offline fallback: the home seeds on appear, but a quiz opened
            // before that (or after a failed seed) still gets the bundled bank.
            let seeded = (try? QuizBankStore.seedBundledIfNeeded(level: level, in: context, now: now)) ?? 0
            if seeded > 0 {
                items = availableItems(level: level, in: context, now: now)
            }
        }
        // A chosen subject / theme: only its items, and only the plan slots
        // about it (its homework, its due notions, its programme).
        let focused = focus.map(focusSlot)
        if let focused {
            items = items.filter { matches($0, focused) }
        }
        guard !items.isEmpty else { return Selection() }

        let playedKeys = playedOverride
            ?? Set(child.quizAttempts.map { AttemptSnapshot($0) }.filter(\.passed).flatMap(\.questionKeys))
        var rng = SplitMix64(seed: seed)
        let shuffled = items.shuffled(using: &rng)
        let ordered = shuffled.filter { !playedKeys.contains($0.questionKey) }
            + shuffled.filter { playedKeys.contains($0.questionKey) }

        let (fullPlan, position) = Self.plan(for: child, curriculum: curriculum, calendar: calendar, now: now)
        let plan = focused.map { focused in
            QuizPlan(slots: fullPlan.slots.filter { slotMatches($0, focused) }, isEligible: fullPlan.isEligible)
        } ?? fullPlan
        let period = PeriodRank.currentPeriod(now: now, level: level, calendar: calendar)
        let eligible = QuizSourceSelector.programmeEligibility(
            level: level, position: position, currentPeriod: period,
            curriculum: curriculum, specialties: child.specialties)

        var selection = Selection()
        var usedKeys = Set<String>()
        var generatedCount = 0
        for slot in plan.slots where selection.questions.count < questionCount {
            if let item = ordered.first(where: { !usedKeys.contains($0.questionKey) && matches($0, slot) }) {
                selection.questions.append(question(from: item, level: level))
                usedKeys.insert(item.questionKey)
                continue
            }
            guard slot.isHomework, let key = slot.homeworkKey else { continue }
            if let question = generated[key], generatedCount < QuizGenerator.maxGeneratedPerQuiz,
               !usedKeys.contains(question.questionKey) {
                selection.questions.append(question)
                usedKeys.insert(question.questionKey)
                generatedCount += 1
            } else {
                let answers = ordered.filter { matches($0, slot) }.map { $0.choices[$0.answerIndex] }
                selection.unmatchedHomework.append(HomeworkGap(slot: slot, bankAnswers: answers))
            }
        }
        // Top-up: same rule as the programme fill (never a theme not taught
        // yet), unless the item matches a homework or due-notion slot. A thin
        // result stays `.tooShort` (`RewardPolicy`); the rule is not relaxed.
        let anchoredSlots = plan.slots.filter { $0.isHomework || $0.origin == .dueNotion }
        for item in ordered where selection.questions.count < questionCount && !usedKeys.contains(item.questionKey) {
            let theme = item.theme.flatMap { $0.isEmpty ? nil : $0 }
            // A theme the child picked is played even before the cahier de
            // textes mentions it (Parcours only offers themes already met).
            let picked = focus?.theme != nil && focused.map { matches(item, $0) } == true
            guard picked || eligible(item.subject ?? "", theme)
                    || anchoredSlots.contains(where: { matches(item, $0) })
            else { continue }
            selection.questions.append(question(from: item, level: level))
            usedKeys.insert(item.questionKey)
        }
        return selection
    }

    private static func question(from item: QuizItem, level: String) -> QuizQuestion {
        let notionKey: String? = {
            guard let subject = item.subject, let theme = item.theme, !theme.isEmpty else { return nil }
            return NotionKey.make(level: level, subject: subject, theme: theme)
        }()
        return QuizQuestion(id: item.id, questionKey: item.questionKey, question: item.question,
                            choices: item.choices, answerIndex: item.answerIndex,
                            explanation: item.explanation, subject: item.subject, theme: item.theme,
                            notionKey: notionKey, difficulty: item.difficulty)
    }

    private static func focusSlot(_ focus: QuizFocus) -> QuizPlanSlot {
        QuizPlanSlot(origin: .programme, subject: focus.subject, theme: focus.theme, keywords: [],
                     homeworkKey: nil, notionKey: nil)
    }

    /// A plan slot about the focused subject (and theme, when one is set).
    /// A homework slot with no theme matches a theme focus too: its bank
    /// items are filtered by the focus anyway.
    private static func slotMatches(_ slot: QuizPlanSlot, _ focused: QuizPlanSlot) -> Bool {
        let subjects = { (label: String) in
            Set([SubjectAlias.compact(label)] + SubjectAlias.canonicalNames(for: label).map(SubjectAlias.compact))
        }
        guard !subjects(slot.subject).isDisjoint(with: subjects(focused.subject)) else { return false }
        guard let theme = focused.theme, let slotTheme = slot.theme else { return true }
        return SubjectAlias.fold(slotTheme) == SubjectAlias.fold(theme)
    }

    /// Subject equality is folded and alias-aware (a homework slot keeps the
    /// raw Pronote label when no theme matched).
    private static func matches(_ item: QuizItem, _ slot: QuizPlanSlot) -> Bool {
        guard let subject = item.subject else { return false }
        let itemSubject = SubjectAlias.compact(subject)
        let slotSubjects = Set([SubjectAlias.compact(slot.subject)]
            + SubjectAlias.canonicalNames(for: slot.subject).map(SubjectAlias.compact))
        guard slotSubjects.contains(itemSubject) else { return false }
        guard let theme = slot.theme else { return true }
        return item.theme.map(SubjectAlias.fold) == SubjectAlias.fold(theme)
    }
}
