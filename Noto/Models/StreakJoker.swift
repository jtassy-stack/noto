import Foundation
import SwiftData

/// One série joker spent by a child on a missed day (Gamification 3.6, 2 per
/// calendar month). Owned by `Child` (cascade delete, RGPD erasure). Only
/// the covered day is stored: everything else is derived from `QuizAttempt`
/// by the pure `Gamification.streak`, which decides when a joker is spent;
/// `GamificationStore` persists it so the decision never changes later.
@Model
final class StreakJoker {
    var id: UUID
    var child: Child?
    /// Covered day, `CalendarDay.key` ("YYYY-MM-DD") in the device calendar
    /// when it was spent. A string, not a start-of-day `Date`, so a time-zone
    /// change does not move it to another day.
    var dayKey: String
    var createdAt: Date

    init(child: Child?, day: CalendarDay, createdAt: Date) {
        self.id = UUID()
        self.child = child
        self.dayKey = day.key
        self.createdAt = createdAt
    }

    var day: CalendarDay? { CalendarDay(key: dayKey) }
}
