import Foundation
import SwiftData

/// Kind of item extracted from a meeting transcript. Kept as a single
/// model with a `kind` discriminator (like `Insight.type`) rather than
/// three separate models, so the review screen can list everything in
/// one query and one editable row type.
enum ExtractedItemKind: String, Codable {
    case agenda   // a dated to-do or deadline for the briefing
    case contact  // a person/role to reach out to
    case policy   // a rule or fact about the school, no date attached
}

/// A recorded parent meeting (réunion de rentrée, conseil de classe, etc.).
/// The audio itself is not modeled here — see `MeetingRecorder`, which
/// writes it to disk and reports back only the file URL; `audioRetained`
/// tracks whether that file still exists.
@Model
final class MeetingNote {
    var id: UUID
    var title: String
    var date: Date
    /// Not cascaded and no inverse on `Child` — a meeting can outlive a
    /// deleted child (it may cover siblings too), unlike the child-owned
    /// data in SchoolData.swift.
    var children: [Child]
    var rawTranscript: String
    var audioRetained: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ExtractedItem.meetingNote)
    var items: [ExtractedItem]

    init(title: String, date: Date, children: [Child], rawTranscript: String) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.children = children
        self.rawTranscript = rawTranscript
        self.audioRetained = false
        self.createdAt = .now
        self.items = []
    }
}

/// One structured fact pulled from a `MeetingNote`'s transcript.
/// `confirmedByUser` is the gate: nothing here is surfaced to
/// `BriefingEngine` (or any other view) until a parent has reviewed it —
/// extraction, on-device or rule-based, is expected to occasionally
/// misread a name or a date.
@Model
final class ExtractedItem {
    var id: UUID
    var meetingNote: MeetingNote?
    var kind: ExtractedItemKind
    /// Free-text name as extracted — not resolved to a `Child` reference,
    /// since a meeting may mention children not yet added to the family
    /// or refer to a child ambiguously ("les deux").
    var childName: String?
    var title: String
    var detail: String?
    /// Only meaningful for `.agenda`.
    var dueDate: Date?
    /// 0...1. Low confidence (rule-based fallback, or a model unsure of a
    /// name/date) should surface first in the review screen.
    var confidence: Double
    var confirmedByUser: Bool

    init(
        kind: ExtractedItemKind,
        childName: String? = nil,
        title: String,
        detail: String? = nil,
        dueDate: Date? = nil,
        confidence: Double
    ) {
        self.id = UUID()
        self.kind = kind
        self.childName = childName
        self.title = title
        self.detail = detail
        self.dueDate = dueDate
        self.confidence = confidence
        self.confirmedByUser = false
    }
}
