import Foundation

/// Pure daily counters shown on the child home (cagnotte, série). No state,
/// no clock, no actor: `now` and `calendar` are passed in.
enum QuizStreak {
    /// Consecutive calendar days with at least one passed quiz
    /// (`AttemptSnapshot.passed`, so a quiz that only ran out of minutes still
    /// counts). Counted back from today; when nothing has passed yet today the
    /// count starts from yesterday, so the série is not shown as broken before
    /// the child has had a chance to play. Jokers come in 3.6.
    static func current(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        let passedDays = Set(attempts.filter(\.passed).map { calendar.startOfDay(for: $0.date) })
        guard !passedDays.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        var day = passedDays.contains(today) ? today : calendar.quizStartOfDay(addingDays: -1, to: now)
        var count = 0
        while passedDays.contains(day) {
            count += 1
            day = calendar.quizStartOfDay(addingDays: -1, to: day)
        }
        return count
    }

    /// Minutes credited today (base + bonus), as stored on the attempts.
    /// Before 3.4 these minutes are shown only; nothing is unlocked.
    static func minutesEarnedToday(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        attempts
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + max(0, $1.minutesEarned) }
    }
}
