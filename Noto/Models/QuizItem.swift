import Foundation
import SwiftData

/// Where a quiz item comes from. Stored as a discriminator, like `ExtractedItemKind`.
enum QuizSourceKind: String, Codable, Sendable {
    case celyn      // celyn quiz v2 (KoiQuizV2Dto)
    case bank       // bundled programme question bank
    case homework   // built on device from a homework label
    case generated  // on-device generation (FoundationModels)
}

/// Question format. V1 is MCQ only: the celyn contract is a 4-choice MCQ.
enum QuizFormat: String, Codable, Sendable {
    case mcq
}

/// One quiz question. Bank and celyn items are shared and non-personal, so
/// there is no `Child` link: per-child history lives in `QuizAttempt` /
/// `NotionMastery`. `.homework` / `.generated` items are derived from a
/// child's homework and are therefore personal: nothing creates them yet, and
/// before 3.3 does they need a `Child` owner with cascade delete or must stay
/// out of this entity (RGPD erasure, design brief C.4 item 15).
///
/// The first block mirrors celyn's `KoiQuizV2Dto` 1:1 (`src/lib/koi/read.ts`);
/// the second block is nōto-only.
@Model
final class QuizItem {
    // --- celyn KoiQuizV2Dto mirror ---
    /// celyn quiz uuid; bank / homework items get a deterministic UUID
    /// (`QuizKey.deterministicID(for:)`, v5 of `questionKey`).
    @Attribute(.unique) var id: UUID
    /// celyn `questionKey` (core.ts), recomputed on device for bank / homework
    /// items via `QuizKey.make(question:choices:)`. The only stable identity:
    /// celyn re-dates rows and bank items are regenerated.
    var questionKey: String
    /// celyn: actu | catalogue | bridge | filmo | fait (+ future "programme"); bank: "programme".
    var kind: String
    var question: String
    /// Exactly 4 choices.
    var choices: [String]
    /// 0...3
    var answerIndex: Int
    var explanation: String?
    /// celyn domain (culture, or a future school domain).
    var domain: String
    /// 1...3
    var difficulty: Int
    /// actu | histoire | fun
    var tone: String?
    /// jour | semaine | mois
    var horizon: String?
    /// nil = evergreen.
    var validUntil: Date?
    var promotedFrom: String?
    /// Links to the post-quiz recommendation.
    var oeuvreId: UUID?
    var oeuvreTitle: String?
    /// celyn `answerOeuvreId`: the work behind the CORRECT choice (e.g. a
    /// filmo / bridge quiz whose subject `oeuvreId` is another work). The
    /// post-quiz recommendation prefers it over `oeuvreId` when present.
    var answerOeuvreId: UUID?
    var imageUrl: String?

    // --- nōto-only ---
    var format: QuizFormat = QuizFormat.mcq
    /// Canonical level "6e" … "Tle".
    var level: String?
    /// Curriculum subject name.
    var subject: String?
    /// Exact `CurriculumTheme.theme` string.
    var theme: String?
    /// Finer key for Leitner; defaults to `theme` when absent.
    var notion: String?
    var source: QuizSourceKind
    /// celyn: lot date + app; bank: "<level>/<subject>.json#<idx>"; homework: dedup hash.
    var sourceRef: String?
    /// celyn: review_method != nil && confidence >= threshold; bank: JSON `reviewed`.
    var reviewed: Bool
    var fetchedAt: Date

    init(
        id: UUID,
        questionKey: String,
        kind: String,
        question: String,
        choices: [String],
        answerIndex: Int,
        explanation: String? = nil,
        domain: String,
        difficulty: Int,
        tone: String? = nil,
        horizon: String? = nil,
        validUntil: Date? = nil,
        promotedFrom: String? = nil,
        oeuvreId: UUID? = nil,
        oeuvreTitle: String? = nil,
        answerOeuvreId: UUID? = nil,
        imageUrl: String? = nil,
        format: QuizFormat = .mcq,
        level: String? = nil,
        subject: String? = nil,
        theme: String? = nil,
        notion: String? = nil,
        source: QuizSourceKind,
        sourceRef: String? = nil,
        reviewed: Bool,
        fetchedAt: Date
    ) {
        self.id = id
        self.questionKey = questionKey
        self.kind = kind
        self.question = question
        self.choices = choices
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.domain = domain
        self.difficulty = difficulty
        self.tone = tone
        self.horizon = horizon
        self.validUntil = validUntil
        self.promotedFrom = promotedFrom
        self.oeuvreId = oeuvreId
        self.oeuvreTitle = oeuvreTitle
        self.answerOeuvreId = answerOeuvreId
        self.imageUrl = imageUrl
        self.format = format
        self.level = level
        self.subject = subject
        self.theme = theme
        self.notion = notion
        self.source = source
        self.sourceRef = sourceRef
        self.reviewed = reviewed
        self.fetchedAt = fetchedAt
    }
}
