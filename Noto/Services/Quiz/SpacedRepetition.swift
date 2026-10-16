import Foundation

/// Leitner scheduling with 5 boxes (1, 2, 4, 8, 16 days). Pure.
///
/// Granularity: one `review` per notion per attempt, never per question,
/// otherwise a 5-question quiz on one theme would jump 5 boxes in one sitting.
/// Use `notionOutcome(itemsCorrect:)` to fold a notion's items into one result.
enum SpacedRepetition {
    /// Review interval in days for box 1 … 5.
    static let intervalsDays = [1, 2, 4, 8, 16]
    static let boxRange = 1...5

    /// What a wrong answer does to the box. Parent-configurable.
    enum FailureRule: String, Codable, Sendable {
        case resetToBoxOne
        case demoteOne
    }

    /// Correct: box + 1 (max 5), streak + 1. Wrong: box 1 (or one box down
    /// with `.demoteOne`, min 1), streak 0. The input box is clamped to 1...5
    /// first. `nextReview` = start of today + the new box's interval.
    static func review(_ mastery: MasterySnapshot, correct: Bool, now: Date, calendar: Calendar,
                       failure: FailureRule = .resetToBoxOne) -> MasterySnapshot {
        let box = clamp(mastery.leitnerBox)
        let newBox: Int
        let streak: Int
        if correct {
            newBox = min(boxRange.upperBound, box + 1)
            streak = mastery.streakCorrect + 1
        } else {
            switch failure {
            case .resetToBoxOne: newBox = boxRange.lowerBound
            case .demoteOne: newBox = max(boxRange.lowerBound, box - 1)
            }
            streak = 0
        }
        let next = calendar.quizStartOfDay(addingDays: intervalsDays[newBox - 1], to: now)
        // `masteredAt` is stamped on the first mastered box and carried
        // forward, never cleared by a miss (badge permanence, 3.6). A row
        // migrated from before 3.6 can sit in box 4–5 with no stamp: the
        // incoming box counts too, so a first post-upgrade miss keeps it.
        let masteredAt = mastery.masteredAt ?? ((box >= 4 || newBox >= 4) ? now : nil)
        return MasterySnapshot(notionKey: mastery.notionKey, leitnerBox: newBox,
                               nextReview: next, streakCorrect: streak, masteredAt: masteredAt)
    }

    /// A new notion: box 1, due today.
    static func initial(notionKey: String, now: Date, calendar: Calendar) -> MasterySnapshot {
        MasterySnapshot(notionKey: notionKey, leitnerBox: boxRange.lowerBound,
                        nextReview: calendar.startOfDay(for: now), streakCorrect: 0)
    }

    /// Due when `nextReview` is on or before the start of today.
    static func isDue(_ mastery: MasterySnapshot, now: Date, calendar: Calendar) -> Bool {
        mastery.nextReview <= calendar.startOfDay(for: now)
    }

    /// Badge rule (3.6): box 4 or 5.
    static func isMastered(_ mastery: MasterySnapshot) -> Bool {
        mastery.leitnerBox >= 4
    }

    /// A notion is correct in an attempt iff all of its items are correct
    /// (and it had at least one item).
    static func notionOutcome(itemsCorrect: [Bool]) -> Bool {
        !itemsCorrect.isEmpty && itemsCorrect.allSatisfy { $0 }
    }

    private static func clamp(_ box: Int) -> Int {
        min(max(box, boxRange.lowerBound), boxRange.upperBound)
    }
}
