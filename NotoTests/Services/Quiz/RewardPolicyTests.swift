import Testing
import Foundation
@testable import Noto

/// One test per branch of `RewardPolicy.evaluate` (design brief A.8).
@Suite("RewardPolicy")
struct RewardPolicyTests {

    private let now = QuizClock.now
    private let calendar = QuizClock.calendar
    private static let keys = ["k1", "k2", "k3", "k4", "k5"]

    private func attempt(correct: Int = 5, total: Int = 5, duration: Int = 60,
                         keys: [String] = RewardPolicyTests.keys) -> AttemptSnapshot {
        AttemptSnapshot(date: now, questionKeys: keys, correctCount: correct, totalCount: total, durationSec: duration)
    }

    /// A prior attempt, `day` days from today (0 = earlier today).
    /// `bonus: true` credits `bonusMinutes` (default 5) inside `minutes`.
    private func prior(day: Int = 0, keys: [String], minutes: Int = 10, passed: Bool = true,
                       bonus: Bool = false, bonusMinutes: Int = 5) -> AttemptSnapshot {
        AttemptSnapshot(date: QuizClock.date(day: day, hour: 18), questionKeys: keys, correctCount: 5, totalCount: 5,
                        durationSec: 60, minutesEarned: minutes, passed: passed, bonusApplied: bonus,
                        bonusMinutes: bonus ? bonusMinutes : 0)
    }

    /// Prior successful attempts today on distinct question sets.
    private func successes(_ minutes: [Int]) -> [AttemptSnapshot] {
        minutes.enumerated().map { prior(keys: ["other\($0.offset)"], minutes: $0.element) }
    }

    private func evaluate(_ attempt: AttemptSnapshot, history: [AttemptSnapshot] = [],
                          homework: [HomeworkSnapshot] = [], schedule: [ScheduleSnapshot] = [],
                          config: RewardConfig = .default) -> RewardDecision {
        RewardPolicy.evaluate(attempt: attempt, history: history, homeworkTomorrow: homework,
                              scheduleTomorrow: schedule, config: config, now: now, calendar: calendar)
    }

    private let controleTomorrow = [QuizClock.homework("MATHEMATIQUES", "Contrôle sur Pythagore", day: 1)]

    // MARK: 1–3. Empty, threshold, duration

    @Test("an empty quiz is denied")
    func emptyQuiz() {
        let d = evaluate(attempt(correct: 0, total: 0))
        #expect(d == .denied(.emptyQuiz))
        #expect(!d.countsAsSuccess)
    }

    @Test("3/5 is below the threshold")
    func belowThreshold() {
        #expect(evaluate(attempt(correct: 3)).denial == .belowThreshold)
    }

    @Test("exactly 4/5 passes")
    func exactlyFourOfFive() {
        let d = evaluate(attempt(correct: 4))
        #expect(d.denial == nil)
        #expect(d.base == 10)
        #expect(d.countsAsSuccess)
    }

    @Test("5/5 earns the first tier")
    func perfectScore() {
        #expect(evaluate(attempt()) == RewardDecision(base: 10, bonus: 0, denial: nil, countsAsSuccess: true))
    }

    @Test("29 s in total is too fast")
    func tooFast() {
        #expect(evaluate(attempt(duration: 29)).denial == .tooFast)
    }

    @Test("exactly 30 s passes")
    func exactlyThirtySeconds() {
        #expect(evaluate(attempt(duration: 30)).base == 10)
    }

    // MARK: 4. Identical replay

    @Test("identical replay the same day is denied")
    func replaySameDay() {
        #expect(evaluate(attempt(), history: [prior(keys: Self.keys)]).denial == .identicalReplay)
    }

    @Test("identical replay of a previous day is denied with .ever")
    func replayPreviousDayEver() {
        #expect(evaluate(attempt(), history: [prior(day: -1, keys: Self.keys)]).denial == .identicalReplay)
    }

    @Test("identical replay of a previous day is allowed with .sameDay")
    func replayPreviousDaySameDayWindow() {
        var config = RewardConfig.default
        config.replayWindow = .sameDay
        let d = evaluate(attempt(), history: [prior(day: -1, keys: Self.keys)], config: config)
        #expect(d.denial == nil)
        #expect(d.base == 10)
    }

    @Test(".sameDay window still denies a replay today")
    func replaySameDayWindowToday() {
        var config = RewardConfig.default
        config.replayWindow = .sameDay
        #expect(evaluate(attempt(), history: [prior(keys: Self.keys)], config: config).denial == .identicalReplay)
    }

    @Test("same keys in another order is a replay")
    func replayDifferentOrder() {
        #expect(evaluate(attempt(), history: [prior(keys: Self.keys.reversed())]).denial == .identicalReplay)
    }

    @Test("4 of 5 keys overlapping is not a replay")
    func partialOverlapIsNotReplay() {
        let d = evaluate(attempt(), history: [prior(keys: ["k1", "k2", "k3", "k4", "new"])])
        #expect(d.denial == nil)
        #expect(d.base == 5)
    }

    @Test("a prior failed identical attempt does not block")
    func failedPriorDoesNotBlock() {
        let d = evaluate(attempt(), history: [prior(keys: Self.keys, minutes: 0, passed: false)])
        #expect(d.denial == nil)
        #expect(d.base == 10)
    }

    // MARK: 5. Tiers

    @Test("tiers 10, 5, 5 then exhausted", arguments: [
        ([Int](), 10), ([10], 5), ([10, 5], 5),
    ])
    func tiers(prior minutes: [Int], expected: Int) {
        let d = evaluate(attempt(), history: successes(minutes))
        #expect(d.denial == nil)
        #expect(d.base == expected)
    }

    @Test("4th success of the day: tiers exhausted, still a success")
    func tiersExhausted() {
        let d = evaluate(attempt(), history: successes([10, 5, 5]))
        #expect(d == .denied(.tiersExhausted))
        #expect(d.countsAsSuccess)
    }

    @Test("denied attempts do not consume a tier")
    func deniedAttemptsDoNotConsumeTier() {
        let history = [
            prior(keys: ["a"], minutes: 0, passed: false),   // e.g. below threshold
            prior(keys: ["b"], minutes: 0, passed: false),   // e.g. too fast
            prior(keys: ["c"], minutes: 0, passed: true),    // passed, capped at 0 minutes
        ]
        #expect(evaluate(attempt(), history: history).base == 10)
    }

    @Test("attempts of previous days do not consume today's tiers")
    func previousDaysDoNotConsumeTier() {
        let history = (0..<3).map { prior(day: -1, keys: ["y\($0)"]) }
        #expect(evaluate(attempt(), history: history).base == 10)
    }

    // MARK: 6. Cap

    @Test("cap partially cuts the tier (tiers 15, 10, cap 20 → 15 then 5)")
    func capPartial() {
        var config = RewardConfig.default
        config.tiers = [15, 10]
        #expect(evaluate(attempt(), config: config).base == 15)
        let d = evaluate(attempt(), history: successes([15]), config: config)
        #expect(d.base == 5)
        #expect(d.denial == nil)
    }

    @Test("cap reached is denied, still a success")
    func capReached() {
        var config = RewardConfig.default
        config.tiers = [15, 5, 5]
        let d = evaluate(attempt(), history: successes([15, 5]), config: config)
        #expect(d == .denied(.capReached))
        #expect(d.countsAsSuccess)
    }

    @Test("cap lowered below what was already earned today is reached")
    func capLoweredMidDay() {
        var config = RewardConfig.default
        config.dailyCap = 10
        #expect(evaluate(attempt(), history: successes([10, 5]), config: config).denial == .capReached)
    }

    @Test("the bonus does not count against the cap")
    func bonusExcludedFromCap() {
        // 10 base + 5 bonus, then 5: base earned today = 15, so the 3rd tier still fits.
        let history = [prior(keys: ["a"], minutes: 15, bonus: true), prior(keys: ["b"], minutes: 5)]
        let d = evaluate(attempt(), history: history)
        #expect(d.denial == nil)
        #expect(d.base == 5)
    }

    @Test("the cap uses the stored bonus, not the current config", arguments: [0, 10])
    func bonusChangedMidDay(newBonus: Int) {
        // Credited earlier: 10 base + 5 bonus. The parent then changes the bonus.
        var config = RewardConfig.default
        config.examEveBonus = newBonus
        let history = [prior(keys: ["a"], minutes: 15, bonus: true), prior(keys: ["b"], minutes: 5)]
        let d = evaluate(attempt(), history: history, config: config)
        #expect(d.denial == nil)
        #expect(d.base == 5)   // base earned today = 15, whatever examEveBonus is now
        let full = history + [prior(keys: ["c"], minutes: 5)]
        config.tiers = [10, 5, 5, 5]
        #expect(evaluate(attempt(), history: full, config: config).denial == .capReached)
    }

    @Test("an inconsistent prior (bonus above minutes) counts as 0 base minutes")
    func baseClampedAtZero() {
        var config = RewardConfig.default
        config.tiers = [5, 5, 5, 5]
        config.dailyCap = 12
        let history = [prior(keys: ["a"], minutes: 3, bonus: true, bonusMinutes: 5),
                       prior(keys: ["b"], minutes: 5), prior(keys: ["c"], minutes: 5)]
        let d = evaluate(attempt(), history: history, config: config)
        #expect(d.denial == nil)
        #expect(d.base == 2)   // 0 + 5 + 5 earned; a -2 would leave room for 4
    }

    // MARK: 7. Exam-eve bonus

    @Test("bonus applied when a contrôle is due tomorrow")
    func bonusTomorrowControle() {
        let d = evaluate(attempt(), homework: controleTomorrow)
        #expect(d.base == 10)
        #expect(d.bonus == 5)
        #expect(d.total == 15)
    }

    @Test("bonus sits on top of the cap")
    func bonusOnTopOfCap() {
        let d = evaluate(attempt(), history: successes([10, 5]), homework: controleTomorrow)
        #expect(d.base == 5)
        #expect(d.bonus == 5)
    }

    @Test("no bonus when the exam is today or in 2 days", arguments: [0, 2])
    func bonusWrongDay(day: Int) {
        let homework = [QuizClock.homework("MATHEMATIQUES", "Contrôle sur Pythagore", day: day, hour: 8)]
        #expect(evaluate(attempt(), homework: homework).bonus == 0)
    }

    @Test("bonus only once per day")
    func bonusOncePerDay() {
        let d = evaluate(attempt(), history: [prior(keys: ["a"], minutes: 15, bonus: true)], homework: controleTomorrow)
        #expect(d.base == 5)
        #expect(d.bonus == 0)
    }

    @Test("a bonus applied yesterday does not block today's")
    func bonusYesterdayDoesNotBlock() {
        let d = evaluate(attempt(), history: [prior(day: -1, keys: ["a"], minutes: 15, bonus: true)],
                         homework: controleTomorrow)
        #expect(d.bonus == 5)
    }

    @Test("bonus disabled by config")
    func bonusDisabled() {
        var config = RewardConfig.default
        config.examEveBonusEnabled = false
        #expect(evaluate(attempt(), homework: controleTomorrow, config: config).bonus == 0)
    }

    @Test("no bonus on a denied quiz", arguments: [
        RewardDenial.belowThreshold, .tooFast, .identicalReplay, .tiersExhausted, .capReached, .tooShort,
    ])
    func noBonusWhenDenied(denial: RewardDenial) {
        var scored = self.attempt()
        var history: [AttemptSnapshot] = []
        var config = RewardConfig.default
        switch denial {
        case .belowThreshold: scored = self.attempt(correct: 2)
        case .tooFast: scored = self.attempt(duration: 5)
        case .identicalReplay: history = [prior(keys: Self.keys)]
        case .tiersExhausted: history = successes([10, 5, 5])
        case .capReached: config.dailyCap = 10; history = successes([10])
        case .emptyQuiz: scored = self.attempt(correct: 0, total: 0)
        case .tooShort: scored = self.attempt(correct: 3, total: 3, keys: ["k1", "k2", "k3"])
        }
        let d = evaluate(scored, history: history, homework: controleTomorrow, config: config)
        #expect(d.denial == denial)
        #expect(d.bonus == 0)
        #expect(d.total == 0)
    }

    @Test("bonus via a test lesson tomorrow in the timetable")
    func bonusViaScheduleTest() {
        let lesson = ScheduleSnapshot(subject: "MATHEMATIQUES", start: QuizClock.date(day: 1, hour: 10),
                                      end: QuizClock.date(day: 1, hour: 11), cancelled: false, isTest: true)
        #expect(evaluate(attempt(), schedule: [lesson]).bonus == 5)
    }

    @Test("a cancelled test lesson is ignored")
    func cancelledTestLessonIgnored() {
        let lesson = ScheduleSnapshot(subject: "MATHEMATIQUES", start: QuizClock.date(day: 1, hour: 10),
                                      end: QuizClock.date(day: 1, hour: 11), cancelled: true, isTest: true)
        #expect(evaluate(attempt(), schedule: [lesson]).bonus == 0)
    }

    // MARK: Config

    @Test("custom config: tiers, threshold 0.6, no minimum duration")
    func customConfig() {
        let config = RewardConfig(tiers: [8, 4], passThreshold: 0.6, dailyCap: 30, examEveBonus: 3,
                                  examEveBonusEnabled: true, minDurationSec: 0, replayWindow: .sameDay)
        let d = evaluate(attempt(correct: 3, duration: 0), homework: controleTomorrow, config: config)
        #expect(d == RewardDecision(base: 8, bonus: 3, denial: nil, countsAsSuccess: true))
        #expect(evaluate(attempt(correct: 2, duration: 0), config: config).denial == .belowThreshold)
    }

    @Test("default config matches the brief and round-trips through JSON")
    func defaultConfig() throws {
        let config = RewardConfig.default
        #expect(config.tiers == [10, 5, 5])
        #expect(config.passThreshold == 0.8)
        #expect(config.dailyCap == 20)
        #expect(config.examEveBonus == 5)
        #expect(config.examEveBonusEnabled)
        #expect(config.minDurationSec == 30)
        #expect(config.replayWindow == .ever)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(RewardConfig.self, from: data) == config)
    }

    // MARK: 8. countsAsSuccess

    @Test("countsAsSuccess per denial", arguments: [
        (RewardDenial.emptyQuiz, false), (.belowThreshold, false), (.tooFast, false),
        (.identicalReplay, false), (.tiersExhausted, true), (.capReached, true), (.tooShort, false),
    ])
    func countsAsSuccess(denial: RewardDenial, expected: Bool) {
        #expect(denial.countsAsSuccess == expected)
        #expect(RewardDecision.denied(denial).countsAsSuccess == expected)
    }

    // MARK: 1b. Minimum quiz length (3.7)

    @Test("fewer questions than minQuestionCount: tooShort, even when all right")
    func tooShort() {
        let short = attempt(correct: 3, total: 3, keys: ["k1", "k2", "k3"])
        let d = evaluate(short)
        #expect(d == .denied(.tooShort))
        #expect(!d.countsAsSuccess)
    }

    @Test("tooShort wins over the threshold (a 1/2 quiz is short, not failed)")
    func tooShortBeforeThreshold() {
        #expect(evaluate(attempt(correct: 1, total: 2, keys: ["k1", "k2"])).denial == .tooShort)
    }

    @Test("a lowered minimum lets a 3-question quiz earn its tier")
    func loweredMinimum() {
        var config = RewardConfig.default
        config.minQuestionCount = 3
        let d = evaluate(attempt(correct: 3, total: 3, keys: ["k1", "k2", "k3"]), config: config)
        #expect(d.denial == nil)
        #expect(d.base == 10)
    }

    @Test("a config saved before minQuestionCount existed decodes with the default")
    func decodesWithoutMinQuestionCount() throws {
        let json = #"{"tiers":[8,4],"passThreshold":0.6,"dailyCap":30,"examEveBonus":3,"#
            + #""examEveBonusEnabled":false,"minDurationSec":20,"replayWindow":"sameDay"}"#
        let config = try JSONDecoder().decode(RewardConfig.self, from: Data(json.utf8))
        #expect(config.tiers == [8, 4])
        #expect(config.passThreshold == 0.6)
        #expect(config.examEveBonusEnabled == false)
        #expect(config.replayWindow == .sameDay)
        #expect(config.minQuestionCount == 5)
    }

    @Test("sanitized clamps out-of-range values")
    func sanitized() {
        let wild = RewardConfig(tiers: [-5, 99], passThreshold: 3, dailyCap: -1, examEveBonus: 40,
                                minDurationSec: -3, minQuestionCount: 50).sanitized()
        #expect(wild.tiers == [0, 0]) // clamped to [0, 30], then a 0 ends the barème
        #expect(wild.passThreshold == 1)
        #expect(wild.dailyCap == 0)
        #expect(wild.examEveBonus == 15)
        #expect(wild.minDurationSec == 0)
        #expect(wild.minQuestionCount == 5)
        #expect(RewardConfig(tiers: []).sanitized().tiers == [10, 5, 5])
        #expect(RewardConfig.default.sanitized() == .default)
    }
}
