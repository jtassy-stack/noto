import Foundation
import SwiftData

/// One programme quiz played by a parent on a child's level (« Testez-vous
/// sur son programme »). Owned by `Child` (cascade delete).
///
/// Kept apart from `QuizAttempt` on purpose: rewards, XP, série, badges,
/// Leitner and the parent reports only read `Child.quizAttempts`, so a
/// parent quiz can never credit minutes or move the child's progress.
@Model
final class ParentQuizAttempt {
    var id: UUID
    var child: Child?
    var date: Date
    /// Sorted `questionKey`s: the next parent quiz prefers questions not
    /// played yet (`ParentQuizSession`).
    var questionKeys: [String]
    /// `NotionKey` per question, as played ("" when the question has none).
    var notionKeys: [String]
    /// Chosen index per question, as played.
    var answers: [Int]
    var correctCount: Int
    var totalCount: Int
    var durationSec: Int

    init(
        id: UUID = UUID(),
        child: Child? = nil,
        date: Date,
        questionKeys: [String],
        notionKeys: [String],
        answers: [Int],
        correctCount: Int,
        totalCount: Int,
        durationSec: Int
    ) {
        self.id = id
        self.child = child
        self.date = date
        self.questionKeys = questionKeys.sorted()
        self.notionKeys = notionKeys
        self.answers = answers
        self.correctCount = correctCount
        self.totalCount = totalCount
        self.durationSec = durationSec
    }
}
