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

    init(sender: String, subject: String, body: String, date: Date, source: MessageSource, kind: MessageKind = .conversation, link: String? = nil) {
        self.sender = sender
        self.subject = subject
        self.body = body
        self.date = date
        self.source = source
        self.kind = kind
        self.read = false
        self.link = link
    }
}
