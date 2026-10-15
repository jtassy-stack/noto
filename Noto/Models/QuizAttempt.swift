import Foundation
import SwiftData

/// One quiz played by a child. Owned by `Child` (cascade delete).
@Model
final class QuizAttempt {
    var id: UUID
    var child: Child?
    var date: Date
    /// Ordered item ids, as played.
    var itemIDs: [UUID]
    /// Sorted `questionKey`s: replay detection independent of item UUIDs.
    var questionKeys: [String]
    /// Chosen index per item, -1 = skipped.
    var answers: [Int]
    var correctCount: Int
    var totalCount: Int
    var durationSec: Int
    /// Base + bonus actually credited.
    var minutesEarned: Int
    var bonusApplied: Bool
    /// Bonus part of `minutesEarned`, as credited (the daily cap counts base
    /// minutes only and must not depend on the current config).
    var bonusMinutes: Int = 0
    /// `RewardDenial` raw value, for the parent screen (3.7).
    var denialReason: String?

    init(
        id: UUID = UUID(),
        child: Child? = nil,
        date: Date,
        itemIDs: [UUID],
        questionKeys: [String],
        answers: [Int],
        correctCount: Int,
        totalCount: Int,
        durationSec: Int,
        minutesEarned: Int,
        bonusApplied: Bool,
        bonusMinutes: Int = 0,
        denialReason: String? = nil
    ) {
        self.id = id
        self.child = child
        self.date = date
        self.itemIDs = itemIDs
        self.questionKeys = questionKeys.sorted()
        self.answers = answers
        self.correctCount = correctCount
        self.totalCount = totalCount
        self.durationSec = durationSec
        self.minutesEarned = minutesEarned
        self.bonusApplied = bonusApplied
        self.bonusMinutes = bonusMinutes
        self.denialReason = denialReason
    }
}
