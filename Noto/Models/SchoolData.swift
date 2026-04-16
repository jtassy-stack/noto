import Foundation
import SwiftData

// MARK: - Grade

@Model
final class Grade {
    var child: Child?
    var subject: String
    var value: Double
    var outOf: Double
    var coefficient: Double
    var date: Date
    var chapter: String?
    var comment: String?
    var classAverage: Double?  // Moyenne de la classe (normalisée /20)
    var classMin: Double?
    var classMax: Double?

    var normalizedValue: Double {
        guard outOf > 0 else { return 0 }
        return (value / outOf) * 20
    }

    init(subject: String, value: Double, outOf: Double = 20, coefficient: Double = 1, date: Date, chapter: String? = nil) {
        self.subject = subject
        self.value = value
        self.outOf = outOf
        self.coefficient = coefficient
        self.date = date
        self.chapter = chapter
    }
}

// MARK: - Schedule Entry

@Model
final class ScheduleEntry {
    var child: Child?
    var subject: String
    var start: Date
    var end: Date
    var room: String?
    var teacher: String?
    var cancelled: Bool
    var chapter: String?

    init(subject: String, start: Date, end: Date, cancelled: Bool = false, chapter: String? = nil) {
        self.subject = subject
        self.start = start
        self.end = end
        self.cancelled = cancelled
        self.chapter = chapter
    }
}

// MARK: - Homework

@Model
final class Homework {
    var child: Child?
    var subject: String
    var descriptionText: String
    var dueDate: Date
    var done: Bool

    init(subject: String, description: String, dueDate: Date) {
        self.subject = subject
        self.descriptionText = description
        self.dueDate = dueDate
        self.done = false
    }
}

// MARK: - Message

enum MessageSource: String, Codable {
    case pronote
    case ent
    case imap
}

enum MessageKind: String, Codable {
    case conversation  // regular messages
    case schoolbook    // carnet de liaison (PCN)
}

// MARK: - School Photo

/// Metadata for a photo from PCN blogs or schoolbook.
/// Actual image data is cached on disk by ENTPhotoCache, keyed by `entPath`.
@Model
final class SchoolPhoto {
    var child: Child?
    var source: ENTPhotoSource
    @Attribute(.unique) var entPath: String  // /workspace/document/<id> — used as cache key
    var title: String?           // blog post title or schoolbook word title
    var authorName: String?
    var date: Date
    var synced: Date             // when this record was last updated

    /// The document ID portion of the ENT path.
    var photoId: String { entPath.components(separatedBy: "/").last ?? entPath }

    init(entPath: String, source: ENTPhotoSource, title: String? = nil, authorName: String? = nil, date: Date) {
        self.entPath = entPath
        self.source = source
        self.title = title
        self.authorName = authorName
        self.date = date
        self.synced = .now
    }
}

@Model
final class Message {
    var child: Child?
    var sender: String
    var subject: String
    var body: String
    var date: Date
    var source: MessageSource
    var kind: MessageKind
    var read: Bool
    var link: String?
    /// Stable IMAP UID used to dedupe across refetches.
    /// Optional for backward compat — legacy messages have nil and
    /// dedupe falls back to (sender, subject, day) composite.
    var imapUID: String?
    /// Provider the message was fetched from at insert time
    /// (e.g. "monlycee", "gmail"). Stamped by `IMAPSyncService` so
    /// the feed can label a message's origin without relying on the
    /// currently active IMAP config — which may have changed since.
    /// nil for non-IMAP sources and for messages stored before this
    /// field was introduced.
    var imapProvider: String?

    init(sender: String, subject: String, body: String, date: Date, source: MessageSource, kind: MessageKind = .conversation, link: String? = nil, imapUID: String? = nil, imapProvider: String? = nil) {
        self.sender = sender
        self.subject = subject
        self.body = body
        self.date = date
        self.source = source
        self.kind = kind
        self.read = false
        self.link = link
        self.imapUID = imapUID
        self.imapProvider = imapProvider
    }
}
