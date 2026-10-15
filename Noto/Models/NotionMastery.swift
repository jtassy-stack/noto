import Foundation
import SwiftData

/// Leitner state of one notion for one child. Owned by `Child` (cascade delete).
/// The scheduling rules live in the pure `SpacedRepetition`; this model only
/// stores the result (see `apply(_:)`).
@Model
final class NotionMastery {
    var id: UUID
    var child: Child?
    /// `NotionKey.make(level:subject:theme:)`: "<level>|<subject>|<theme or notion>", folded.
    var notionKey: String
    /// 1...5
    var leitnerBox: Int
    /// Start of day.
    var nextReview: Date
    var streakCorrect: Int
    var lastReviewedAt: Date?

    /// Box 1, due today (`nextReview = startOfDay(now)`). `calendar` is passed
    /// in rather than read from `Calendar.current`, for testability.
    init(child: Child?, notionKey: String, now: Date, calendar: Calendar) {
        self.id = UUID()
        self.child = child
        self.notionKey = notionKey
        self.leitnerBox = 1
        self.nextReview = calendar.startOfDay(for: now)
        self.streakCorrect = 0
        self.lastReviewedAt = nil
    }
}
