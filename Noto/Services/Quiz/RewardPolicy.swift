import Foundation

/// Which earlier attempts make an identical quiz a replay.
enum ReplayWindow: String, Codable, Sendable {
    case sameDay
    case ever
}

/// Parent-configurable reward rules, edited in « Révisions & récompenses »
/// (3.7) and persisted as JSON in the app group by `RewardConfigStore`.
/// Phase 3.4 moves the store next to `Shared/RewardLedger.swift` so the
/// DeviceActivity extension can read it too.
struct RewardConfig: Codable, Sendable, Equatable {
    /// Minutes for the 1st, 2nd, 3rd successful quiz of the day; later = 0.
    var tiers: [Int]
    /// 4/5 → correct / total >= 0.8.
    var passThreshold: Double
    /// Applies to base minutes only (the exam-eve bonus sits on top).
    var dailyCap: Int
    var examEveBonus: Int
    var examEveBonusEnabled: Bool
    /// Minimum total duration of the quiz.
    var minDurationSec: Int
    var replayWindow: ReplayWindow
    /// Fewest questions a quiz needs to earn minutes (a thin bank can draw
    /// fewer than `QuizSession.questionCount`). A shorter quiz still moves
    /// mastery and XP, but earns no minute (`.tooShort`).
    var minQuestionCount: Int

    static let `default` = RewardConfig()

    /// Values the parent editor offers.
    static let passThresholdChoices: [Double] = [0.8, 0.6]
    static let minQuestionCountRange = 3...5
    static let tierRange = 0...30
    static let dailyCapRange = 0...60
    static let examEveBonusRange = 0...15

    init(tiers: [Int] = [10, 5, 5], passThreshold: Double = 0.8, dailyCap: Int = 20,
         examEveBonus: Int = 5, examEveBonusEnabled: Bool = true, minDurationSec: Int = 30,
         replayWindow: ReplayWindow = .ever, minQuestionCount: Int = 5) {
        self.tiers = tiers
        self.passThreshold = passThreshold
        self.dailyCap = dailyCap
        self.examEveBonus = examEveBonus
        self.examEveBonusEnabled = examEveBonusEnabled
        self.minDurationSec = minDurationSec
        self.replayWindow = replayWindow
        self.minQuestionCount = minQuestionCount
    }

    /// Every field is optional on decode: a config saved by an older build
    /// (missing a later field) keeps its values and gets the default for the
    /// rest, instead of failing and resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RewardConfig()
        tiers = try c.decodeIfPresent([Int].self, forKey: .tiers) ?? d.tiers
        passThreshold = try c.decodeIfPresent(Double.self, forKey: .passThreshold) ?? d.passThreshold
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? d.dailyCap
        examEveBonus = try c.decodeIfPresent(Int.self, forKey: .examEveBonus) ?? d.examEveBonus
        examEveBonusEnabled = try c.decodeIfPresent(Bool.self, forKey: .examEveBonusEnabled) ?? d.examEveBonusEnabled
        minDurationSec = try c.decodeIfPresent(Int.self, forKey: .minDurationSec) ?? d.minDurationSec
        replayWindow = try c.decodeIfPresent(ReplayWindow.self, forKey: .replayWindow) ?? d.replayWindow
        minQuestionCount = try c.decodeIfPresent(Int.self, forKey: .minQuestionCount) ?? d.minQuestionCount
    }

    /// Clamped to what the editor allows, so a hand-edited or corrupted
    /// value can never make every quiz unwinnable (threshold > 1) or the
    /// cap negative.
    func sanitized() -> RewardConfig {
        var c = self
        c.tiers = Array(tiers.prefix(5)).map { min(max($0, Self.tierRange.lowerBound), Self.tierRange.upperBound) }
        if c.tiers.isEmpty { c.tiers = Self.default.tiers }
        c.passThreshold = passThreshold.isFinite ? min(max(passThreshold, 0.5), 1.0) : Self.default.passThreshold
        c.dailyCap = min(max(dailyCap, Self.dailyCapRange.lowerBound), Self.dailyCapRange.upperBound)
        c.examEveBonus = min(max(examEveBonus, Self.examEveBonusRange.lowerBound), Self.examEveBonusRange.upperBound)
        c.minDurationSec = min(max(minDurationSec, 0), 300)
        c.minQuestionCount = min(max(minQuestionCount, Self.minQuestionCountRange.lowerBound),
                                 Self.minQuestionCountRange.upperBound)
        return c
    }
}

enum RewardDenial: String, Codable, Sendable {
    case belowThreshold, tooFast, identicalReplay, tiersExhausted, capReached, emptyQuiz
    /// Fewer questions than `RewardConfig.minQuestionCount` (thin bank).
    case tooShort

    /// A passed quiz that only ran out of minutes still feeds XP and streak (3.6).
    var countsAsSuccess: Bool {
        self == .tiersExhausted || self == .capReached
    }
}

struct RewardDecision: Sendable, Equatable {
    let base: Int
    let bonus: Int
    var total: Int { base + bonus }
    let denial: RewardDenial?
    let countsAsSuccess: Bool

    static func denied(_ denial: RewardDenial) -> RewardDecision {
        RewardDecision(base: 0, bonus: 0, denial: denial, countsAsSuccess: denial.countsAsSuccess)
    }
}

/// Minutes of screen time a quiz earns. Pure: no state, no clock, no actor.
///
/// It only computes the minutes earned. Whether the credit goes to reserve
/// (class hours) or is consumed is decided in `RewardUnlockService` (3.4)
/// against `ClassScheduleShieldService`: the class lock stays absolute and
/// lives in one place, outside this layer.
enum RewardPolicy {
    /// Rules are evaluated in order; the first denial wins.
    /// 1. no question → `.emptyQuiz`
    /// 1b. fewer than `minQuestionCount` questions → `.tooShort` (checked
    ///    before the threshold, so a 1/2 quiz is « trop court », not failed;
    ///    not a success: a 1-question quiz must not feed the série)
    /// 2. correct / total below `passThreshold` → `.belowThreshold`
    /// 3. total duration below `minDurationSec` → `.tooFast`
    /// 4. a passed attempt with the same question-key set, inside
    ///    `replayWindow` → `.identicalReplay`
    /// 5. tier of the day, counting only today's credited successes →
    ///    `.tiersExhausted` when none is left
    /// 6. daily cap on base minutes → `.capReached` when nothing is left
    /// 7. exam-eve bonus on top of the cap, at most once per day.
    ///
    /// "Today" is the calendar day of `now` in `calendar`.
    /// - Parameters:
    ///   - attempt: the attempt being scored (`minutesEarned`, `passed`,
    ///     `bonusApplied` and `bonusMinutes` ignored).
    ///   - history: this child's prior attempts, any day.
    static func evaluate(attempt: AttemptSnapshot,
                         history: [AttemptSnapshot],
                         homeworkTomorrow: [HomeworkSnapshot],
                         scheduleTomorrow: [ScheduleSnapshot],
                         config: RewardConfig,
                         now: Date,
                         calendar: Calendar) -> RewardDecision {
        // 1.
        guard attempt.totalCount > 0 else { return .denied(.emptyQuiz) }

        // 1b.
        guard attempt.totalCount >= config.minQuestionCount else { return .denied(.tooShort) }

        // 2. Tolerance absorbs binary rounding (0.8 * 5 = 4.000000000000001).
        guard Double(attempt.correctCount) >= config.passThreshold * Double(attempt.totalCount) - 1e-9 else {
            return .denied(.belowThreshold)
        }

        // 3.
        guard !isTooFast(attempt, config: config) else { return .denied(.tooFast) }

        // 4. Only passed priors block (brief A.5 rule 4). Open question for
        //    Julien (brief C.4): a rushed or failed attempt reveals the answers,
        //    then a slow identical replay earns the full tier.
        guard !isReplay(attempt, history: history, passedOnly: true, config: config,
                        now: now, calendar: calendar) else { return .denied(.identicalReplay) }

        // 5. Denied attempts (minutesEarned == 0) never use up a tier slot.
        let today = history.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let successesToday = today.filter { $0.passed && $0.minutesEarned > 0 }.count
        let tierMinutes = successesToday < config.tiers.count ? config.tiers[successesToday] : 0
        guard tierMinutes > 0 else { return .denied(.tiersExhausted) }

        // 6. The cap counts base minutes only: the stored bonus is taken back
        //    out (never the current config, which the parent may change mid-day).
        let earnedBaseToday = today.reduce(0) { sum, prior in
            sum + max(0, prior.minutesEarned - prior.bonusMinutes)
        }
        let base = min(tierMinutes, config.dailyCap - earnedBaseToday)
        guard base > 0 else { return .denied(.capReached) }

        // 7. On top of the cap (with 10+5+5 the base alone reaches the cap of
        //    20, so a bonus inside the cap could never be earned). Default
        //    awaiting Julien's decision.
        let bonusDue = config.examEveBonusEnabled
            && !today.contains(where: \.bonusApplied)
            && ExamKeywordDetector.hasExamTomorrow(homework: homeworkTomorrow, schedule: scheduleTomorrow,
                                                   now: now, calendar: calendar)
        return RewardDecision(base: base, bonus: bonusDue ? config.examEveBonus : 0,
                              denial: nil, countsAsSuccess: true)
    }

    /// Rule 3 on its own: total duration below `minDurationSec`.
    static func isTooFast(_ attempt: AttemptSnapshot, config: RewardConfig) -> Bool {
        attempt.durationSec < config.minDurationSec
    }

    /// Rule 4 on its own: an earlier attempt with the same question-key set
    /// (compared as sets: same questions in another order is a replay),
    /// inside `replayWindow`. `passedOnly` restricts the priors to passed
    /// ones (the minutes rule); the XP guard (`Gamification.earnsXP`) checks
    /// every prior, failed ones included.
    static func isReplay(_ attempt: AttemptSnapshot, history: [AttemptSnapshot], passedOnly: Bool,
                         config: RewardConfig, now: Date, calendar: Calendar) -> Bool {
        let keys = Set(attempt.questionKeys)
        return history.contains { prior in
            (!passedOnly || prior.passed) && Set(prior.questionKeys) == keys
                && (config.replayWindow == .ever || calendar.isDate(prior.date, inSameDayAs: now))
        }
    }
}
