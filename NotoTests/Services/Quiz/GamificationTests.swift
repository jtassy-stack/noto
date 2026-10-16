import Testing
import Foundation
import SwiftData
@testable import Noto

// Gamification (3.6): XP table, level curve, série with monthly jokers
// (month boundary, DST, time zone), badges on real milestones, family
// challenge flag. All pure except the `QuizSession` / `GamificationStore`
// suites, which run on an in-memory `NotoSchemaV1` container.

private let paris = QuizClock.calendar

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// A date in Europe/Paris.
private func parisDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 18, _ min: Int = 0) -> Date {
    paris.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func day(_ offset: Int) -> CalendarDay {
    CalendarDay(QuizClock.date(day: offset, hour: 12), calendar: paris)
}

private func played(_ date: Date, passed: Bool = true, total: Int = 5,
                    subjects: [String] = [], xp: [Int] = []) -> AttemptSnapshot {
    AttemptSnapshot(date: date, questionKeys: ["k\(date.timeIntervalSince1970)"],
                    correctCount: passed ? total : 0, totalCount: total, durationSec: 60,
                    passed: passed, itemSubjects: subjects, itemXP: xp)
}

private func played(day offset: Int, passed: Bool = true) -> AttemptSnapshot {
    played(QuizClock.date(day: offset, hour: 18), passed: passed)
}

// MARK: - XP

@Suite("Gamification XP")
struct GamificationXPTests {
    @Test("difficulty bonus table, clamped", arguments: [(0, 0), (1, 0), (2, 2), (3, 5), (4, 5)])
    func bonus(difficulty: Int, expected: Int) {
        #expect(Gamification.difficultyBonus(difficulty) == expected)
        #expect(Gamification.xp(correct: true, difficulty: difficulty) == 10 + expected)
    }

    @Test("a wrong answer earns nothing, whatever the difficulty", arguments: [1, 2, 3])
    func wrong(difficulty: Int) {
        #expect(Gamification.xp(correct: false, difficulty: difficulty) == 0)
    }

    private func attempt(keys: [String], correct: Int, seconds: Int, passed: Bool = false,
                         date: Date = QuizClock.now) -> AttemptSnapshot {
        AttemptSnapshot(date: date, questionKeys: keys, correctCount: correct, totalCount: 5,
                        durationSec: seconds, passed: passed)
    }

    private func earns(_ attempt: AttemptSnapshot, history: [AttemptSnapshot] = []) -> Bool {
        Gamification.earnsXP(attempt: attempt, history: history, config: .default,
                             now: QuizClock.now, calendar: paris)
    }

    @Test("farming guards are checked on their own, whatever the score", arguments: [0, 1, 3, 5])
    func guards(correct: Int) {
        let keys = ["a", "b", "c", "d", "e"]
        // Slow, new set: earns, below threshold included.
        #expect(earns(attempt(keys: keys, correct: correct, seconds: 60)))
        // Tapped through: nothing, even below the threshold (`.belowThreshold` wins in RewardPolicy).
        #expect(!earns(attempt(keys: keys, correct: correct, seconds: 5)))
        // Same set as a FAILED earlier attempt (order ignored): nothing.
        let failed = attempt(keys: Array(keys.reversed()), correct: 1, seconds: 60, date: QuizClock.date(day: -1, hour: 18))
        #expect(!earns(attempt(keys: keys, correct: correct, seconds: 60), history: [failed]))
        // Another set: earns.
        let other = attempt(keys: ["x", "y", "z", "w", "v"], correct: 1, seconds: 60)
        #expect(earns(attempt(keys: keys, correct: correct, seconds: 60), history: [other]))
    }

    @Test("a fast below-threshold attempt is denied as .belowThreshold yet earns no XP")
    func fastBelowThreshold() {
        let fast = attempt(keys: ["a", "b", "c", "d", "e"], correct: 2, seconds: 5)
        let decision = RewardPolicy.evaluate(attempt: fast, history: [], homeworkTomorrow: [], scheduleTomorrow: [],
                                             config: .default, now: QuizClock.now, calendar: paris)
        #expect(decision.denial == .belowThreshold)
        #expect(!earns(fast))
    }

    @Test("the replay window applies to the XP guard too")
    func replayWindow() {
        var sameDay = RewardConfig.default
        sameDay.replayWindow = .sameDay
        let keys = ["a", "b", "c", "d", "e"]
        let yesterday = attempt(keys: keys, correct: 1, seconds: 60, date: QuizClock.date(day: -1, hour: 18))
        #expect(Gamification.earnsXP(attempt: attempt(keys: keys, correct: 5, seconds: 60), history: [yesterday],
                                     config: sameDay, now: QuizClock.now, calendar: paris))
    }

    @Test("per-question XP in play order; zeros when a guard withholds it")
    func perQuestion() {
        let difficulties = [1, 2, 3, 1]
        let correct = [true, true, true, false]
        #expect(Gamification.questionXP(difficulties: difficulties, correct: correct, earnsXP: true) == [10, 12, 15, 0])
        #expect(Gamification.questionXP(difficulties: difficulties, correct: correct, earnsXP: false) == [0, 0, 0, 0])
    }

    @Test("attempt XP sums its questions, negatives ignored; pre-3.6 attempts are 0")
    func attemptXP() {
        let attempt = played(QuizClock.now, subjects: ["Maths", "Maths"], xp: [10, -3])
        #expect(attempt.xpEarned == 10)
        #expect(played(QuizClock.now).xpEarned == 0)
        #expect(Gamification.totalXP(attempts: [attempt, played(QuizClock.now, xp: [5])]) == 15)
    }
}

// MARK: - Levels

@Suite("Gamification levels")
struct GamificationLevelTests {
    @Test("level n starts at 50·n·(n−1)", arguments: [(0, 0), (1, 0), (2, 100), (3, 300), (4, 600), (5, 1000)])
    func thresholds(level: Int, xp: Int) {
        #expect(Gamification.xpThreshold(level: level) == xp)
    }

    @Test("level and progress at the boundaries", arguments: [
        (-5, 1, 0, 100), (0, 1, 0, 100), (99, 1, 99, 100), (100, 2, 0, 200),
        (299, 2, 199, 200), (300, 3, 0, 300), (1_000, 5, 0, 500),
    ])
    func level(xp: Int, level: Int, into: Int, span: Int) {
        let progress = Gamification.level(forXP: xp)
        #expect(progress.level == level)
        #expect(progress.xpIntoLevel == into)
        #expect(progress.xpForNextLevel == span)
    }

    @Test("progress fraction")
    func fraction() {
        #expect(Gamification.level(forXP: 50).fraction == 0.5)
        #expect(Gamification.level(forXP: 0).fraction == 0)
        let degenerate = Gamification.LevelProgress(level: 1, xpIntoLevel: 3, xpForNextLevel: 0)
        #expect(degenerate.fraction == 0)
    }

    @Test("XP grouped per subject (case / accents folded), chronological order, blanks skipped")
    func subjects() {
        let a = played(QuizClock.date(day: -1), subjects: ["Mathématiques", "Français", ""], xp: [10, 12, 15])
        let b = played(QuizClock.date(day: 0), subjects: ["MATHEMATIQUES", " ", "Histoire"], xp: [15, 10, 10])
        // Out of order on input: the earlier attempt names the subject.
        let result = Gamification.subjectXP(attempts: [b, a])
        #expect(result.map(\.subject) == ["Mathématiques", "Français", "Histoire"])
        #expect(result.map(\.xp) == [25, 12, 10])
        #expect(Gamification.xp(for: "mathematiques", in: result) == 25)
        #expect(Gamification.xp(for: "SVT", in: result) == 0)
        #expect(result[0].level.level == 1)
    }

    @Test("level-ups between two tallies: highest level reached, unchanged subjects skipped")
    func levelUps() {
        let before = [SubjectXP(subject: "Maths", xp: 95), SubjectXP(subject: "Français", xp: 40)]
        let after = [SubjectXP(subject: "Maths", xp: 305), SubjectXP(subject: "Français", xp: 50),
                     SubjectXP(subject: "Histoire", xp: 100)]
        #expect(Gamification.levelUps(before: before, after: after) == [
            SubjectLevelUp(subject: "Maths", level: 3), SubjectLevelUp(subject: "Histoire", level: 2),
        ])
        #expect(Gamification.levelUps(before: after, after: after).isEmpty)
    }
}

// MARK: - Calendar day

@Suite("CalendarDay")
struct CalendarDayTests {
    @Test("key round trip; malformed keys rejected")
    func keys() {
        let d = CalendarDay(year: 2026, month: 3, day: 7)
        #expect(d.key == "2026-03-07")
        #expect(CalendarDay(key: "2026-03-07") == d)
        for bad in ["", "2026-3-07", "2026-13-01", "2026-00-10", "2026-01-32", "abcd-ef-gh", "2026-01-01-01"] {
            #expect(CalendarDay(key: bad) == nil)
        }
    }

    @Test("calendar arithmetic across the October DST change (Paris)")
    func dst() {
        let saturday = CalendarDay(year: 2023, month: 10, day: 28)
        #expect(saturday.adding(days: 1, calendar: paris) == CalendarDay(year: 2023, month: 10, day: 29))
        #expect(saturday.adding(days: 2, calendar: paris) == CalendarDay(year: 2023, month: 10, day: 30))
        #expect(saturday.adding(days: 4, calendar: paris) == CalendarDay(year: 2023, month: 11, day: 1))
        let sunday = CalendarDay(year: 2023, month: 10, day: 29)
        #expect(sunday.startOfDay(in: paris) == paris.startOfDay(for: parisDate(2023, 10, 29, 12)))
    }

    @Test("ordering and month index")
    func ordering() {
        #expect(CalendarDay(year: 2023, month: 12, day: 31) < CalendarDay(year: 2024, month: 1, day: 1))
        #expect(CalendarDay(year: 2023, month: 10, day: 31).monthIndex + 1
                == CalendarDay(year: 2023, month: 11, day: 1).monthIndex)
    }
}

// MARK: - Série + jokers

@Suite("Gamification série + jokers")
struct GamificationStreakTests {
    private func streak(_ attempts: [AttemptSnapshot], jokers: [CalendarDay] = [],
                        now: Date = QuizClock.now, calendar: Calendar = paris,
                        budget: Int = Gamification.jokersPerMonth) -> StreakStatus {
        Gamification.streak(attempts: attempts, jokers: jokers, now: now, calendar: calendar, jokerBudget: budget)
    }

    @Test("no attempt: 0, nothing spent, 2 jokers left")
    func empty() {
        let s = streak([])
        #expect(s.days == 0)
        #expect(s.newJokers.isEmpty)
        #expect(s.jokersUsedThisMonth == 0)
        #expect(s.jokersLeftThisMonth == 2)
        #expect(!s.protectedByJoker)
    }

    @Test("no gap: no joker spent")
    func noGap() {
        let s = streak([played(day: 0), played(day: -1), played(day: -2)])
        #expect(s.days == 3)
        #expect(s.newJokers.isEmpty)
        // Nothing yet today, played yesterday: today stays open, no joker.
        let open = streak([played(day: -1), played(day: -2)])
        #expect(open.days == 2)
        #expect(open.newJokers.isEmpty)
    }

    @Test("yesterday missed: one joker covers it, the série goes on (joker days do not add)")
    func oneMissed() {
        let s = streak([played(day: -2), played(day: -3)])
        #expect(s.newJokers == [day(-1)])
        #expect(s.days == 2)
        #expect(s.jokersUsedThisMonth == 1)
        #expect(s.jokersLeftThisMonth == 1)
        #expect(s.protectedByJoker)

        let playedToday = streak([played(day: 0), played(day: -2)])
        #expect(playedToday.newJokers == [day(-1)])
        #expect(playedToday.days == 2)
        #expect(playedToday.protectedByJoker)
    }

    @Test("pending jokers: skipping the gap's next day too re-evaluates the longer gap, budget intact")
    func pendingThenSkipped() {
        // Played −3, missed −2 (pending joker on −2 seen on −1), skipped −1 too.
        let attempts = [played(day: -3)]
        let yesterdayView = streak(attempts, now: QuizClock.date(day: -1, hour: 20))
        #expect(yesterdayView.newJokers == [day(-2)])
        // Nothing persisted (no passed quiz closed the gap): today, both days are bridged.
        let today = streak(attempts)
        #expect(today.newJokers == [day(-2), day(-1)])
        #expect(today.days == 1)
    }

    @Test("two missed days in the month: both jokers")
    func twoMissed() {
        let s = streak([played(day: -3)])
        #expect(s.newJokers == [day(-2), day(-1)])
        #expect(s.days == 1)
        #expect(s.jokersLeftThisMonth == 0)
    }

    @Test("three missed days in one month: unbridgeable, no joker wasted, série broken")
    func threeMissed() {
        let s = streak([played(day: -4), played(day: -5)])
        #expect(s.newJokers.isEmpty)
        #expect(s.days == 0)
        #expect(s.jokersLeftThisMonth == 2)
        #expect(!s.protectedByJoker)
    }

    @Test("a gap longer than two months' budget is never bridged")
    func longGap() {
        #expect(streak([played(day: -6)]).newJokers.isEmpty)
        #expect(streak([played(day: -30)]).newJokers.isEmpty)
    }

    @Test("month budget already spent: no third joker")
    func budgetSpent() {
        // Jokers on 5 and 8 November (days −9, −6), série since.
        let attempts = (-8 ... -2).filter { $0 != -6 }.map { played(day: $0) } + [played(day: -10)]
        let s = streak(attempts, jokers: [day(-9), day(-6)])
        #expect(s.newJokers.isEmpty)
        #expect(s.days == 0)
        #expect(s.jokersUsedThisMonth == 2)
        #expect(s.jokersLeftThisMonth == 0)
    }

    @Test("persisted jokers keep covering: idempotent, nothing spent twice")
    func idempotent() {
        let attempts = [played(day: -3)]
        let first = streak(attempts)
        let second = streak(attempts, jokers: first.newJokers)
        #expect(second.newJokers.isEmpty)
        #expect(second.days == first.days)
        #expect(second.jokersUsedThisMonth == first.jokersUsedThisMonth)
        #expect(second.protectedByJoker)
    }

    @Test("a joker never covers today, even when one is stored for it")
    func neverToday() {
        let s = streak([played(day: -1)], jokers: [day(0), day(1)])
        #expect(s.days == 1)
        #expect(s.jokersUsedThisMonth == 0)
        #expect(s.newJokers.allSatisfy { $0 < day(0) })
    }

    @Test("nothing to save: no played day before the gap")
    func noAnchor() {
        #expect(streak([played(day: 0)]).newJokers.isEmpty)
        #expect(streak([played(day: -1, passed: false)]).newJokers.isEmpty)
    }

    @Test("an old broken gap is never resurrected")
    func oldGap() {
        // −10, gap −9…−7 (3 days), then −6…−1.
        let attempts = [played(day: -10)] + (-6 ... -1).map { played(day: $0) }
        let s = streak(attempts)
        #expect(s.newJokers.isEmpty)
        #expect(s.days == 6)
    }

    @Test("a failed quiz is not a played day")
    func failedDoesNotCount() {
        let s = streak([played(day: -1, passed: false), played(day: -2)])
        #expect(s.newJokers == [day(-1)])
        #expect(s.days == 1)
    }

    @Test("budget 0 disables jokers (QuizStreak.current)")
    func budgetZero() {
        let s = streak([played(day: -2)], budget: 0)
        #expect(s.newJokers.isEmpty)
        #expect(s.days == 0)
        #expect(s.jokersLeftThisMonth == 0)
        #expect(Gamification.jokersToSpend(played: [day(-2)], jokers: [], today: day(0),
                                           calendar: paris, budget: 0).isEmpty)
    }

    @Test("gap over a month boundary (and the DST change): one October + one November joker")
    func monthBoundary() {
        let now = parisDate(2023, 11, 2, 20)
        let attempts = [28, 29, 30].map { played(parisDate(2023, 10, $0)) }
        let s = streak(attempts, now: now)
        #expect(s.newJokers == [CalendarDay(year: 2023, month: 10, day: 31), CalendarDay(year: 2023, month: 11, day: 1)])
        #expect(s.days == 3)
        #expect(s.jokersUsedThisMonth == 1)     // November only
        #expect(s.jokersLeftThisMonth == 1)
    }

    @Test("October spent: its missed 31st cannot be covered, the série breaks")
    func monthBoundaryOctoberSpent() {
        let now = parisDate(2023, 11, 2, 20)
        let attempts = [28, 29, 30].map { played(parisDate(2023, 10, $0)) }
        let spent = [CalendarDay(year: 2023, month: 10, day: 10), CalendarDay(year: 2023, month: 10, day: 20)]
        let s = streak(attempts, jokers: spent, now: now)
        #expect(s.newJokers.isEmpty)
        #expect(s.days == 0)
        #expect(s.jokersLeftThisMonth == 2)     // November untouched
    }

    @Test("the longest bridgeable gap: 4 missed days over a month boundary, 2 jokers per month")
    func longestBridgeableGap() {
        let now = parisDate(2023, 11, 3, 20)
        let s = streak([played(parisDate(2023, 10, 29))], now: now)
        #expect(s.newJokers == [
            CalendarDay(year: 2023, month: 10, day: 30), CalendarDay(year: 2023, month: 10, day: 31),
            CalendarDay(year: 2023, month: 11, day: 1), CalendarDay(year: 2023, month: 11, day: 2),
        ])
        #expect(s.days == 1)
        #expect(s.jokersUsedThisMonth == 2)
        #expect(s.jokersLeftThisMonth == 0)
        // One more missed day (5) can never be bridged.
        let fiveMissed = streak([played(parisDate(2023, 10, 28))], now: now)
        #expect(fiveMissed.newJokers.isEmpty)
        #expect(fiveMissed.days == 0)
    }

    @Test("gap over a month boundary and the spring DST change (Paris, 31 March 2024)")
    func monthBoundarySpringDST() {
        let now = parisDate(2024, 4, 2, 20)
        let attempts = [28, 29, 30].map { played(parisDate(2024, 3, $0)) }
        let s = streak(attempts, now: now)
        #expect(s.newJokers == [CalendarDay(year: 2024, month: 3, day: 31), CalendarDay(year: 2024, month: 4, day: 1)])
        #expect(s.days == 3)
        #expect(s.jokersUsedThisMonth == 1)     // April only
        #expect(CalendarDay(year: 2024, month: 3, day: 30).adding(days: 1, calendar: paris)
                == CalendarDay(year: 2024, month: 3, day: 31))
        #expect(CalendarDay(year: 2024, month: 3, day: 31).adding(days: 1, calendar: paris)
                == CalendarDay(year: 2024, month: 4, day: 1))
    }

    @Test("the budget resets on the 1st")
    func monthlyReset() {
        let now = parisDate(2023, 11, 3, 20)
        let spent = [CalendarDay(year: 2023, month: 10, day: 30), CalendarDay(year: 2023, month: 10, day: 31)]
        let attempts = [played(parisDate(2023, 10, 29)), played(parisDate(2023, 11, 1))]
        let s = streak(attempts, jokers: spent, now: now)
        #expect(s.newJokers == [CalendarDay(year: 2023, month: 11, day: 2)])
        #expect(s.days == 2)
        #expect(s.jokersUsedThisMonth == 1)
        #expect(s.jokersLeftThisMonth == 1)
    }

    @Test("days follow the calendar's time zone; a stored joker keeps its day key")
    func timeZone() {
        // 00:30 Paris on the 13th is 23:30 UTC on the 12th.
        let attempts = [played(parisDate(2023, 11, 13, 0, 30)), played(parisDate(2023, 11, 14, 18))]
        let inParis = streak(attempts, calendar: paris)
        #expect(inParis.days == 2)
        #expect(inParis.newJokers.isEmpty)

        let inUTC = streak(attempts, calendar: utc)
        let thirteenth = CalendarDay(year: 2023, month: 11, day: 13)
        #expect(inUTC.newJokers == [thirteenth])
        #expect(inUTC.days == 2)
        #expect(inUTC.protectedByJoker)

        // Persisted as "2023-11-13": the same day in either zone.
        let restored = streak(attempts, jokers: [CalendarDay(key: thirteenth.key)!], calendar: utc)
        #expect(restored.newJokers.isEmpty)
        #expect(restored.days == 2)
    }

    @Test("QuizStreak.current is the joker-free count")
    func legacyFacade() {
        let attempts = [played(day: -2), played(day: -3)]
        #expect(QuizStreak.current(attempts: attempts, now: QuizClock.now, calendar: paris) == 0)
        #expect(streak(attempts).days == 2)
    }
}

// MARK: - Badges

@Suite("Gamification badges")
struct GamificationBadgeTests {
    private let curriculum = QuizCurriculumFixtures.curriculum

    private func badges(_ attempts: [AttemptSnapshot] = [], masteries: [MasterySnapshot] = [],
                        jokers: [CalendarDay] = [], level: String = "4e") -> [EarnedBadge] {
        Gamification.badges(attempts: attempts, masteries: masteries, jokers: jokers, level: level,
                            specialties: [], curriculum: curriculum, calendar: paris)
    }

    private func mastery(_ key: String, box: Int, masteredAt: Date? = nil) -> MasterySnapshot {
        MasterySnapshot(notionKey: key, leitnerBox: box, nextReview: QuizClock.now, streakCorrect: 0,
                        masteredAt: masteredAt)
    }

    private let pythagore = NotionKey.make(level: "4e", subject: "Mathématiques", theme: "Théorème de Pythagore")

    @Test("nothing played: no badge")
    func none() {
        #expect(badges().isEmpty)
    }

    @Test("first quiz, whatever the score; an empty attempt does not count")
    func firstQuiz() {
        let empty = played(QuizClock.date(day: -3), passed: false, total: 0)
        let failed = played(QuizClock.date(day: -2), passed: false)
        let result = badges([played(day: -1), failed, empty])
        #expect(result.map(\.kind) == [.firstQuiz])
        #expect(result.first?.earnedAt == failed.date)
        #expect(badges([empty]).isEmpty)
    }

    @Test("7-day série badge dated on the 7th day; 6 days earn nothing")
    func sevenDays() {
        let six = (-6 ... -1).map { played(day: $0) }
        #expect(!badges(six).contains { $0.kind == .streak(days: 7) })
        let seven = (-7 ... -1).map { played(day: $0) }
        let badge = badges(seven).first { $0.kind == .streak(days: 7) }
        #expect(badge?.earnedAt == day(-1).startOfDay(in: paris))
    }

    @Test("a joker bridges the run (joker day not counted); a broken série keeps its badge")
    func sevenWithJoker() {
        // Played −20…−18, joker −17, played −16…−13: 7 played days, then nothing.
        let attempts = ((-20 ... -18).map { played(day: $0) }) + ((-16 ... -13).map { played(day: $0) })
        #expect(!badges(attempts).contains { $0.kind == .streak(days: 7) })
        let badge = badges(attempts, jokers: [day(-17)]).first { $0.kind == .streak(days: 7) }
        #expect(badge?.earnedAt == day(-13).startOfDay(in: paris))
    }

    @Test("30-day série badge, with the 7-day one")
    func thirtyDays() {
        let attempts = (-30 ... -1).map { played(day: $0) }
        let kinds = badges(attempts).map(\.kind)
        #expect(kinds.contains(.streak(days: 7)))
        #expect(kinds.contains(.streak(days: 30)))
        let milestones = Gamification.streakMilestones(attempts: attempts, jokers: [], calendar: paris)
        #expect(milestones[7] == day(-24))
        #expect(milestones[30] == day(-1))
    }

    @Test("subject level badges, each dated by the attempt that crossed it")
    func levels() {
        let a = played(QuizClock.date(day: -2), subjects: ["Maths", "Maths"], xp: [50, 40])
        let b = played(QuizClock.date(day: -1), subjects: ["Maths", "Français"], xp: [15, 10])
        let c = played(QuizClock.date(day: 0), subjects: ["Maths"], xp: [250])
        let levelBadges = Gamification.subjectLevelBadges(attempts: [c, a, b])
        #expect(levelBadges.map(\.kind) == [
            .subjectLevel(subject: "Maths", level: 2), .subjectLevel(subject: "Maths", level: 3),
        ])
        #expect(levelBadges.map(\.earnedAt) == [b.date, c.date])
    }

    @Test("several levels gained in one attempt: one badge each, same date")
    func multiLevel() {
        let a = played(QuizClock.date(day: -1), subjects: ["Maths"], xp: [300])
        let levelBadges = Gamification.subjectLevelBadges(attempts: [a])
        #expect(levelBadges.map(\.kind) == [
            .subjectLevel(subject: "Maths", level: 2), .subjectLevel(subject: "Maths", level: 3),
        ])
        #expect(levelBadges.map(\.earnedAt) == [a.date, a.date])
    }

    @Test("theme mastered: box ≥ 4 on the theme notion")
    func themeMastered() {
        #expect(badges(masteries: [mastery(pythagore, box: 3)]).isEmpty)
        let result = badges(masteries: [mastery(pythagore, box: 4)])
        #expect(result.map(\.kind) == [.themeMastered(subject: "Mathématiques", theme: "Théorème de Pythagore")])
        #expect(result.first?.earnedAt == nil)
        #expect(badges(masteries: [mastery(pythagore, box: 5)]).count == 1)
    }

    @Test("a theme badge stays earned after a miss resets the box to 1")
    func themeMasteredIsPermanent() {
        let masteredOn = QuizClock.date(day: -3, hour: 18)
        let atFour = mastery(pythagore, box: 3)
        let promoted = SpacedRepetition.review(atFour, correct: true, now: masteredOn, calendar: paris)
        #expect(promoted.leitnerBox == 4)
        #expect(promoted.masteredAt == masteredOn)
        let missed = SpacedRepetition.review(promoted, correct: false, now: QuizClock.now, calendar: paris)
        #expect(missed.leitnerBox == 1)
        #expect(missed.masteredAt == masteredOn)

        let result = badges(masteries: [missed])
        #expect(result.map(\.kind) == [.themeMastered(subject: "Mathématiques", theme: "Théorème de Pythagore")])
        #expect(result.first?.earnedAt == masteredOn)
    }

    @Test("theme and subject de-duplication, curriculum order across subjects")
    func themeDedupAndOrder() {
        let revolution = NotionKey.make(level: "4e", subject: "Histoire", theme: "La Révolution française")
        let stub = DuplicatingCurriculum(subjectsList: ["Histoire", "Mathématiques", "Histoire"], themesBySubject: [
            "Histoire": ["La Révolution française", "La Révolution française"],
            "Mathématiques": ["Théorème de Pythagore", "Théorème de Pythagore"],
        ])
        let result = Gamification.themeMasteredBadges(
            masteries: [mastery(pythagore, box: 4), mastery(revolution, box: 5)],
            level: "4e", specialties: [], curriculum: stub)
        #expect(result.map(\.kind) == [
            .themeMastered(subject: "Histoire", theme: "La Révolution française"),
            .themeMastered(subject: "Mathématiques", theme: "Théorème de Pythagore"),
        ])
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test("finer notions: every notion of the theme must be mastered")
    func finerNotions() {
        let partial = [mastery(pythagore + "|reciproque", box: 5), mastery(pythagore + "|hypotenuse", box: 3)]
        #expect(!Gamification.isThemeMastered(themeKey: pythagore, masteries: partial))
        let full = [mastery(pythagore + "|reciproque", box: 5), mastery(pythagore + "|hypotenuse", box: 4)]
        #expect(Gamification.isThemeMastered(themeKey: pythagore, masteries: full))
        #expect(!Gamification.isThemeMastered(themeKey: pythagore, masteries: []))
    }

    @Test("a key that merely starts with the theme key belongs to another theme")
    func prefixIsNotNotion() {
        let other = [mastery(pythagore + " et triangles", box: 5)]
        #expect(!Gamification.isThemeMastered(themeKey: pythagore, masteries: other))
    }

    @Test("primary level: no theme badge")
    func primary() {
        let key = NotionKey.make(level: "CM2", subject: "Français", theme: "Lire des contes")
        #expect(badges(masteries: [mastery(key, box: 5)], level: "CM2").isEmpty)
    }

    @Test("stable ids per kind")
    func ids() {
        #expect(EarnedBadge(kind: .firstQuiz, earnedAt: nil).id == "first-quiz")
        #expect(EarnedBadge(kind: .streak(days: 7), earnedAt: nil).id == "streak-7")
        #expect(EarnedBadge(kind: .subjectLevel(subject: "Mathématiques", level: 2), earnedAt: nil).id
                == "level-mathematiques-2")
        #expect(EarnedBadge(kind: .themeMastered(subject: "Histoire", theme: "La Révolution"), earnedAt: nil).id
                == "theme-histoire-la revolution")
    }

    @Test("badge copy addresses the child", arguments: [
        BadgeKind.firstQuiz, .streak(days: 7), .subjectLevel(subject: "Maths", level: 2),
        .themeMastered(subject: "Histoire", theme: "La Révolution française"),
    ])
    func copy(kind: BadgeKind) {
        let text = (BadgeCopy.title(for: kind) + " " + BadgeCopy.detail(for: kind)).lowercased()
        #expect(!BadgeCopy.symbol(for: kind).isEmpty)
        #expect(!text.contains("vous"))
        #expect(!text.contains("votre"))
        #expect(!text.contains("encore"))   // no pressure wording
    }
}

/// Curriculum that lists a subject and its themes twice (badge de-duplication).
private struct DuplicatingCurriculum: CurriculumLookup {
    let subjectsList: [String]
    let themesBySubject: [String: [String]]

    func themes(for level: String, subject: String, specialties: [String]?) -> [CurriculumTheme] {
        (themesBySubject[subject] ?? []).map { CurriculumTheme(theme: $0, keywords: [], period: nil) }
    }

    func subjects(for level: String) -> [String] { subjectsList }

    func subjectThemes(for level: String, subject: String,
                       specialties: [String]?) -> [(name: String, themes: [CurriculumTheme])] {
        [(name: subject, themes: themes(for: level, subject: subject, specialties: specialties))]
    }
}

// MARK: - Family challenge

@Suite("Family weekly challenge")
struct FamilyChallengeTests {
    @Test("off by default, parent-controlled")
    func flag() throws {
        let suite = "FamilyChallengeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!FamilyChallengeSettings.isEnabled(defaults: defaults))
        #expect(!FamilyChallengeSettings.isEnabled(defaults: nil))
        FamilyChallengeSettings.setEnabled(true, defaults: defaults)
        #expect(FamilyChallengeSettings.isEnabled(defaults: defaults))
    }

    @Test("passed quizzes of the current week only")
    func weekCount() {
        // Paris calendar starts weeks on Monday: 2023-11-13 … 19.
        var calendar = paris
        calendar.firstWeekday = 2
        let attempts = [played(parisDate(2023, 11, 13, 9)), played(parisDate(2023, 11, 14, 9)),
                        played(parisDate(2023, 11, 14, 10), passed: false), played(parisDate(2023, 11, 12, 9))]
        #expect(Gamification.passedQuizzesThisWeek(attempts: attempts, now: QuizClock.now, calendar: calendar) == 2)
    }

    @MainActor
    @Test("card copy")
    func copy() {
        #expect(ChildHomeView.familyChallengeText(passed: 2, goal: 5) == "2 quiz réussis sur 5 cette semaine.")
        #expect(ChildHomeView.familyChallengeText(passed: 6, goal: 5).hasPrefix("Défi réussi"))
    }
}

// MARK: - Home copy

@MainActor
@Suite("Série card copy")
struct StreakCopyTests {
    private func status(days: Int, left: Int, protected: Bool = false) -> StreakStatus {
        StreakStatus(days: days, newJokers: [], jokersUsedThisMonth: 2 - left, jokersLeftThisMonth: left,
                     protectedByJoker: protected)
    }

    @Test("jokers line: only the positive note, never the stock")
    func jokers() {
        #expect(ChildHomeView.jokerText(status(days: 3, left: 2)) == nil)
        #expect(ChildHomeView.jokerText(status(days: 3, left: 0)) == nil)
        #expect(ChildHomeView.jokerText(status(days: 0, left: 2)) == nil)
        #expect(ChildHomeView.jokerText(status(days: 3, left: 0, protected: true)) == "Un joker a protégé ta série.")
        // Pending (not saved until a quiz is passed today): nothing said.
        let pending = StreakStatus(days: 3, newJokers: [day(-1)], jokersUsedThisMonth: 1, jokersLeftThisMonth: 1,
                                   protectedByJoker: true)
        #expect(ChildHomeView.jokerText(pending) == nil)
    }

    @Test("VoiceOver label")
    func label() {
        #expect(ChildHomeView.streakAccessibilityLabel(status(days: 0, left: 2)) == "Ta série : pas encore commencée.")
        #expect(ChildHomeView.streakAccessibilityLabel(status(days: 1, left: 2)) == "Ta série : 1 jour.")
        #expect(ChildHomeView.streakAccessibilityLabel(status(days: 2, left: 1, protected: true))
                == "Ta série : 2 jours d'affilée. Un joker a protégé ta série.")
        #expect(!ChildHomeView.streakAccessibilityLabel(status(days: 2, left: 0)).contains("joker"))
    }

    @Test("XP and level copy")
    func xpCopy() {
        let result = QuizSessionResult(correctCount: 5, totalCount: 5, durationSec: 60,
                                       decision: RewardDecision(base: 10, bonus: 0, denial: nil, countsAsSuccess: true),
                                       requiredCorrect: 4, xpEarned: 52,
                                       levelUps: [SubjectLevelUp(subject: "Histoire", level: 2)])
        #expect(QuizResultView.xpAccessibilityLabel(for: result)
                == "52 points d'expérience gagnés. Niveau 2 en Histoire !")
        #expect(SubjectLevelBar.accessibilityLabel(xp: 140)
                == "Niveau 2, 140 points d'expérience. Encore 160 pour le niveau 3.")
    }
}

// MARK: - QuizSession XP + GamificationStore (SwiftData)

@MainActor
@Suite("Gamification persistence")
struct GamificationPersistenceTests {
    let context: ModelContext
    let clock = QuizTestClock(QuizClock.now)

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func makeChild() -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: "4e", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func addBank(difficulty: Int = 1) {
        let themes: [(String, String)] = [
            ("Français", "Molière et le théâtre classique"), ("Mathématiques", "Théorème de Pythagore"),
            ("Histoire", "La Révolution française"), ("Géographie", "L'urbanisation du monde"),
            ("Français", "Le récit fantastique"),
        ]
        for (n, theme) in themes.enumerated() {
            let question = "Question \(n) sur \(theme.1) ?"
            let choices = ["A\(n)", "B\(n)", "C\(n)", "D\(n)"]
            let key = QuizKey.make(question: question, choices: choices)
            context.insert(QuizItem(id: QuizKey.deterministicID(for: key), questionKey: key, kind: "programme",
                                    question: question, choices: choices, answerIndex: 1, domain: "programme",
                                    difficulty: difficulty, level: "4e", subject: theme.0, theme: theme.1,
                                    source: .celyn, reviewed: true, fetchedAt: QuizClock.now))
        }
    }

    private func play(_ child: Child, wrong: Set<Int> = [], seconds: TimeInterval = 60) -> QuizSession {
        let clock = self.clock
        let session = QuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                                  config: .default, calendar: paris, seed: 7, now: { clock.now })
        for index in session.questions.indices {
            let q = session.questions[index]
            session.answer(wrong.contains(index) ? (q.answerIndex + 1) % 4 : q.answerIndex)
            if index < session.questions.count - 1 { session.advance() }
        }
        clock.now = QuizClock.now.addingTimeInterval(seconds)
        session.advance()
        return session
    }

    @Test("5/5 easy: 50 XP, stored per question with its subject")
    func xpStored() throws {
        let child = makeChild()
        addBank()
        try context.save()
        let session = play(child)
        let result = try #require(session.result)
        #expect(result.xpEarned == 50)
        let attempt = try #require(try context.fetch(FetchDescriptor<QuizAttempt>()).first)
        #expect(attempt.itemXP == [10, 10, 10, 10, 10])
        #expect(attempt.itemSubjects == session.questions.map { $0.subject ?? "" })
        #expect(AttemptSnapshot(attempt).xpEarned == 50)
        #expect(session.questions.allSatisfy { $0.difficulty == 1 })
    }

    @Test("difficulty 3 items: 15 XP each")
    func hardItems() throws {
        let child = makeChild()
        addBank(difficulty: 3)
        try context.save()
        #expect(play(child).result?.xpEarned == 75)
    }

    @Test("below threshold still earns its right answers; too fast earns none")
    func denials() throws {
        let child = makeChild()
        addBank()
        try context.save()
        let below = play(child, wrong: [0, 1])
        #expect(below.result?.decision.denial == .belowThreshold)
        #expect(below.result?.xpEarned == 30)

        let other = makeChild()
        try context.save()
        clock.now = QuizClock.now
        let fast = play(other, seconds: 10)
        #expect(fast.result?.decision.denial == .tooFast)
        #expect(fast.result?.xpEarned == 0)
        #expect(fast.result?.levelUps.isEmpty == true)
    }

    @Test("a fast quiz below the threshold earns no XP (guard checked on its own)")
    func fastBelowThreshold() throws {
        let child = makeChild()
        addBank()
        try context.save()
        let fast = play(child, wrong: [0, 1, 2], seconds: 5)
        #expect(fast.result?.decision.denial == .belowThreshold)
        #expect(fast.result?.xpEarned == 0)
        let attempt = try #require(try context.fetch(FetchDescriptor<QuizAttempt>()).first)
        #expect(attempt.itemXP.allSatisfy { $0 == 0 })
    }

    @Test("replaying the same failed question set earns no XP the second time")
    func failedReplay() throws {
        let child = makeChild()
        addBank()
        try context.save()
        let first = play(child, wrong: [0, 1])
        #expect(first.result?.decision.denial == .belowThreshold)
        #expect(first.result?.xpEarned == 30)

        clock.now = QuizClock.now
        let replay = play(child, wrong: [0, 1])
        #expect(Set(replay.questions.map(\.questionKey)) == Set(first.questions.map(\.questionKey)))
        #expect(replay.result?.decision.denial == .belowThreshold)
        #expect(replay.result?.xpEarned == 0)
    }

    @Test("a quiz crossing 100 XP in a subject reports the level-up")
    func levelUp() throws {
        let child = makeChild()
        addBank()
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: -1, hour: 18), itemIDs: [UUID()],
                                   questionKeys: ["prior"], answers: [0], correctCount: 1, totalCount: 1,
                                   durationSec: 60, minutesEarned: 10, bonusApplied: false,
                                   itemSubjects: ["Mathématiques"], itemXP: [95]))
        try context.save()
        let result = try #require(play(child).result)
        #expect(result.levelUps == [SubjectLevelUp(subject: "Mathématiques", level: 2)])
        #expect(GamificationStore.subjectXP(of: child).first { $0.subject == "Mathématiques" }?.xp == 105)
    }

    private func insertPassed(_ child: Child, day offset: Int, key: String = UUID().uuidString) {
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: offset, hour: 18), itemIDs: [],
                                   questionKeys: [key], answers: [1], correctCount: 1, totalCount: 1,
                                   durationSec: 60, minutesEarned: 10, bonusApplied: false))
    }

    @Test("pending jokers are not persisted while today has no passed quiz; budget intact")
    func jokersPendingUntilPlayed() throws {
        let child = makeChild()
        insertPassed(child, day: -3)
        try context.save()

        let status = GamificationStore.recordDueJokers(for: child, in: context, now: QuizClock.now, calendar: paris)
        #expect(status.newJokers == [day(-2), day(-1)])     // shown, pending
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).isEmpty)

        // A failed quiz today does not close the gap either.
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: 0, hour: 9), itemIDs: [],
                                   questionKeys: ["failed"], answers: [0], correctCount: 0, totalCount: 1,
                                   durationSec: 60, minutesEarned: 0, bonusApplied: false,
                                   denialReason: RewardDenial.belowThreshold.rawValue))
        try context.save()
        GamificationStore.recordDueJokers(for: child, in: context, now: QuizClock.now, calendar: paris)
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).isEmpty)
    }

    @Test("jokers are persisted once a passed quiz closes the gap, once, and go with the child")
    func jokersPersisted() throws {
        let child = makeChild()
        insertPassed(child, day: -3)
        insertPassed(child, day: 0)
        try context.save()

        let first = GamificationStore.recordDueJokers(for: child, in: context, now: QuizClock.now, calendar: paris)
        #expect(first.newJokers == [day(-2), day(-1)])
        let stored = try context.fetch(FetchDescriptor<StreakJoker>())
        #expect(Set(stored.map(\.dayKey)) == Set([day(-2).key, day(-1).key]))
        #expect(stored.allSatisfy { $0.child === child })

        let second = GamificationStore.recordDueJokers(for: child, in: context, now: QuizClock.now, calendar: paris)
        #expect(second.newJokers.isEmpty)
        #expect(second.days == 2)
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).count == 2)

        context.delete(child)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).isEmpty)
    }

    @Test("QuizSession.finish spends the gap joker; the série survives the next day without the home")
    func finishSavesJokers() throws {
        // Played −2, missed −1 (no home refresh at all), passed quiz today.
        let child = makeChild()
        addBank()
        insertPassed(child, day: -2, key: "earlier")
        try context.save()
        let session = play(child)
        #expect(session.result?.decision.countsAsSuccess == true)
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).map(\.dayKey) == [day(-1).key])

        // Tomorrow: yesterday (today) played, the gap day stays covered by the saved joker.
        let tomorrow = GamificationStore.streak(for: child, now: QuizClock.date(day: 1, hour: 20), calendar: paris)
        #expect(tomorrow.days == 2)
        #expect(tomorrow.newJokers.isEmpty)
        #expect(tomorrow.protectedByJoker == false)     // yesterday was played, not a joker
    }

    @Test("a failed quiz in finish spends no joker")
    func finishFailedSavesNothing() throws {
        let child = makeChild()
        addBank()
        insertPassed(child, day: -2, key: "earlier")
        try context.save()
        let session = play(child, wrong: [0, 1, 2])
        #expect(session.result?.decision.countsAsSuccess == false)
        #expect(try context.fetch(FetchDescriptor<StreakJoker>()).isEmpty)
    }

    @Test("masteredAt is stamped once on the model and survives a reset to box 1")
    func masteredAtPersisted() throws {
        let child = makeChild()
        let key = NotionKey.make(level: "4e", subject: "Mathématiques", theme: "Théorème de Pythagore")
        let mastery = NotionMastery(child: child, notionKey: key, now: QuizClock.now, calendar: paris)
        context.insert(mastery)
        let reachedOn = QuizClock.date(day: -1, hour: 18)
        mastery.apply(MasterySnapshot(notionKey: key, leitnerBox: 4, nextReview: QuizClock.now, streakCorrect: 3),
                      reviewedAt: reachedOn)
        #expect(mastery.masteredAt == reachedOn)
        mastery.apply(SpacedRepetition.review(MasterySnapshot(mastery), correct: false, now: QuizClock.now,
                                              calendar: paris), reviewedAt: QuizClock.now)
        try context.save()
        #expect(mastery.leitnerBox == 1)
        #expect(mastery.masteredAt == reachedOn)
        let kinds = GamificationStore.badges(for: child, now: QuizClock.now, calendar: paris,
                                             curriculum: QuizCurriculumFixtures.curriculum).map(\.kind)
        #expect(kinds.contains(.themeMastered(subject: "Mathématiques", theme: "Théorème de Pythagore")))
    }

    @Test("badges from the models")
    func storeBadges() throws {
        let child = makeChild()
        addBank()
        try context.save()
        _ = play(child)
        let kinds = GamificationStore.badges(for: child, now: QuizClock.now, calendar: paris,
                                             curriculum: QuizCurriculumFixtures.curriculum).map(\.kind)
        #expect(kinds == [.firstQuiz])
    }
}
