import Foundation

/// Pure daily counters shown on the child home (cagnotte, série). No state,
/// no clock, no actor: `now` and `calendar` are passed in.
///
/// Since 3.6 the série with jokers lives in `Gamification.streak`; `current`
/// is the joker-free count kept for callers that have no joker history.
enum QuizStreak {
    /// Consecutive calendar days with at least one passed quiz
    /// (`AttemptSnapshot.passed`, so a quiz that only ran out of minutes still
    /// counts). Counted back from today; when nothing has passed yet today the
    /// count starts from yesterday, so the série is not shown as broken before
    /// the child has had a chance to play. No joker (`jokerBudget: 0`).
    static func current(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        Gamification.streak(attempts: attempts, jokers: [], now: now, calendar: calendar, jokerBudget: 0).days
    }

    /// Minutes credited today (base + bonus), as stored on the attempts.
    /// Before 3.4 these minutes are shown only; nothing is unlocked.
    static func minutesEarnedToday(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        attempts
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + max(0, $1.minutesEarned) }
    }
}
