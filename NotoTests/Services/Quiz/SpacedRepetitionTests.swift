import Testing
import Foundation
@testable import Noto

@Suite("SpacedRepetition")
struct SpacedRepetitionTests {

    private let now = QuizClock.now
    private let calendar = QuizClock.calendar
    private let key = "4e|francais|moliere et le theatre classique"

    private func mastery(box: Int, streak: Int = 0, nextReview: Date? = nil) -> MasterySnapshot {
        MasterySnapshot(notionKey: key, leitnerBox: box, nextReview: nextReview ?? QuizClock.date(day: 0),
                        streakCorrect: streak)
    }

    private func review(_ m: MasterySnapshot, correct: Bool,
                        failure: SpacedRepetition.FailureRule = .resetToBoxOne) -> MasterySnapshot {
        SpacedRepetition.review(m, correct: correct, now: now, calendar: calendar, failure: failure)
    }

    @Test("correct answer moves up one box, with that box's interval", arguments: [
        (1, 2, 2), (2, 3, 4), (3, 4, 8), (4, 5, 16),
    ])
    func correctPromotes(from: Int, to: Int, days: Int) {
        let r = review(mastery(box: from), correct: true)
        #expect(r.leitnerBox == to)
        #expect(r.nextReview == QuizClock.date(day: days))
        #expect(r.notionKey == key)
    }

    @Test("correct at box 5 stays at 5 (16 days)")
    func correctAtTop() {
        let r = review(mastery(box: 5), correct: true)
        #expect(r.leitnerBox == 5)
        #expect(r.nextReview == QuizClock.date(day: 16))
    }

    @Test("wrong answer resets to box 1 by default (1 day)", arguments: [1, 3, 5])
    func wrongResets(from: Int) {
        let r = SpacedRepetition.review(mastery(box: from, streak: 4), correct: false, now: now, calendar: calendar)
        #expect(r.leitnerBox == 1)
        #expect(r.nextReview == QuizClock.date(day: 1))
    }

    @Test(".demoteOne moves down one box, never below 1", arguments: [(3, 2), (1, 1), (5, 4)])
    func wrongDemotes(from: Int, to: Int) {
        #expect(review(mastery(box: from), correct: false, failure: .demoteOne).leitnerBox == to)
    }

    @Test("intervals are 1/2/4/8/16 days")
    func intervals() {
        #expect(SpacedRepetition.intervalsDays == [1, 2, 4, 8, 16])
    }

    @Test("out-of-range input box is clamped first", arguments: [(0, true, 2), (-3, false, 1), (6, true, 5), (9, false, 1)])
    func clamped(box: Int, correct: Bool, expected: Int) {
        #expect(review(mastery(box: box), correct: correct).leitnerBox == expected)
    }

    @Test("demote from an out-of-range high box clamps to 5 first")
    func clampedDemote() {
        #expect(review(mastery(box: 8), correct: false, failure: .demoteOne).leitnerBox == 4)
    }

    @Test("streak increments on correct and resets on wrong")
    func streak() {
        #expect(review(mastery(box: 2, streak: 3), correct: true).streakCorrect == 4)
        #expect(review(mastery(box: 2, streak: 3), correct: false).streakCorrect == 0)
        #expect(review(mastery(box: 2, streak: 3), correct: false, failure: .demoteOne).streakCorrect == 0)
    }

    @Test("nextReview counts from the start of the day, even at 23:59")
    func startOfDayAtLateHour() {
        let late = QuizClock.date(day: 0, hour: 23, minute: 59)
        let r = SpacedRepetition.review(mastery(box: 1), correct: true, now: late, calendar: calendar)
        #expect(r.nextReview == QuizClock.date(day: 2))
        #expect(calendar.component(.hour, from: r.nextReview) == 0)
    }

    @Test("interval crossing the end of daylight saving stays on local midnight")
    func dstCrossing() {
        // 2023-10-27 Paris; DST ends on 2023-10-29.
        let before = calendar.date(from: DateComponents(year: 2023, month: 10, day: 27, hour: 20))!
        let r = SpacedRepetition.review(mastery(box: 2), correct: true, now: before, calendar: calendar)
        #expect(r.nextReview == calendar.date(from: DateComponents(year: 2023, month: 10, day: 31))!)
    }

    @Test("initial: box 1, due today, no streak")
    func initial() {
        let m = SpacedRepetition.initial(notionKey: key, now: now, calendar: calendar)
        #expect(m == MasterySnapshot(notionKey: key, leitnerBox: 1, nextReview: QuizClock.date(day: 0), streakCorrect: 0))
        #expect(SpacedRepetition.isDue(m, now: now, calendar: calendar))
    }

    @Test("isDue before / at / after", arguments: [(-2, true), (0, true), (1, false)])
    func isDue(day: Int, expected: Bool) {
        let m = mastery(box: 2, nextReview: QuizClock.date(day: day))
        #expect(SpacedRepetition.isDue(m, now: now, calendar: calendar) == expected)
    }

    @Test("isMastered from box 4", arguments: [(3, false), (4, true), (5, true)])
    func isMastered(box: Int, expected: Bool) {
        #expect(SpacedRepetition.isMastered(mastery(box: box)) == expected)
    }

    @Test("notionOutcome: all correct / one wrong / no item", arguments: [
        ([true, true, true], true), ([true, false, true], false), ([Bool](), false),
    ])
    func notionOutcome(items: [Bool], expected: Bool) {
        #expect(SpacedRepetition.notionOutcome(itemsCorrect: items) == expected)
    }

    @Test("a pre-3.6 row already in box 4–5 keeps its mastery through a first miss (Codex #49)")
    func migratedMasteryPreservedOnMiss() {
        for box in [4, 5] {
            let migrated = MasterySnapshot(notionKey: key, leitnerBox: box, nextReview: QuizClock.date(day: 0),
                                           streakCorrect: 3, masteredAt: nil)
            let after = SpacedRepetition.review(migrated, correct: false, now: now, calendar: calendar)
            #expect(after.leitnerBox == 1)
            #expect(after.masteredAt == now)
        }
        let notYet = MasterySnapshot(notionKey: key, leitnerBox: 3, nextReview: QuizClock.date(day: 0),
                                     streakCorrect: 1, masteredAt: nil)
        #expect(SpacedRepetition.review(notYet, correct: false, now: now, calendar: calendar).masteredAt == nil)
    }
}
