import Foundation
import SwiftData

/// One "what was covered" signal for a child: a cahier de textes lesson
/// content or a homework item, kept across syncs (unlike `Homework`, which
/// connectors wipe on every sync). Feeds `ProgrammePositionTracker`.
///
/// Privacy: lesson text stays on the device, in this local SwiftData store.
/// It is never sent to any server (celyn / culture-api included, not even as
/// a search query), never logged in release builds and never exported. Only
/// on-device code (and on-device FoundationModels) may read it. Cascade-
/// deleted with its `Child`; rows older than the school year are purged
/// (`LessonContentStore.purge`).
///
/// Every stored field has an inline default so adding the entity stays a
/// SwiftData lightweight migration (see `NotoSchemaV1`).
@Model
final class LessonContent {
    var id: UUID = UUID()
    var child: Child?
    /// Raw connector subject label (e.g. "HISTOIRE-GEOGRAPHIE").
    var subject: String = ""
    /// Lesson start for lesson contents, due date for homework.
    var date: Date = Date.distantPast
    var title: String = ""
    /// Plain text: HTML stripped (and base64-decoded for École Directe).
    var text: String = ""
    /// Teacher-tagged Pronote themes (`ListeThemes`), empty otherwise.
    var themes: [String] = []
    /// `LessonContentSource.rawValue`.
    var sourceRaw: String = LessonContentSource.homework.rawValue
    /// Connector id when there is one (Pronote N, ED idDevoir, ENT id…).
    var externalID: String? = nil
    /// `LessonDedupKey.make(subject:date:text:)` over `title + " " + text`
    /// (empty parts dropped, so a homework row hashes exactly like
    /// `HomeworkSnapshot.dedupKey`). Upsert key per child.
    var dedupKey: String = ""
    var fetchedAt: Date = Date.now

    init(child: Child?, subject: String, date: Date, title: String, text: String,
         themes: [String], source: LessonContentSource, externalID: String?,
         calendar: Calendar, fetchedAt: Date = .now) {
        self.child = child
        self.subject = subject
        self.date = date
        self.title = title
        self.text = text
        self.themes = themes
        self.sourceRaw = source.rawValue
        self.externalID = externalID
        self.dedupKey = LessonDedupKey.make(subject: subject, date: date,
                                            text: LessonDedupKey.body(title: title, text: text),
                                            calendar: calendar)
        self.fetchedAt = fetchedAt
    }

    var source: LessonContentSource { LessonContentSource(rawValue: sourceRaw) ?? .homework }
}

enum LessonContentSource: String, Sendable, CaseIterable {
    /// Pronote `PageCahierDeTexte`, onglet 89 (contenus de cours).
    case pronoteLesson
    /// École Directe per-day `contenuDeSeance`.
    case ecoleDirecteSeance
    /// Any connector's homework (past + upcoming).
    case homework

    /// Direct evidence of teaching (vs homework, which can be review).
    var isLesson: Bool { self != .homework }
}
