import Foundation
import SwiftData

enum SchoolType: String, Codable {
    case pronote
    case ent
}

enum SchoolLevel: String, Codable, CaseIterable {
    case maternelle
    case elementaire = "élémentaire"
    case college = "collège"
    case lycee = "lycée"
}

@Model
final class Child {
    var firstName: String
    var avatar: Data?
    var level: SchoolLevel
    var grade: String // "6e", "CE1", "PS", etc.
    var schoolType: SchoolType
    var establishment: String
    /// Stable identifier returned by pawnote for Pronote children.
    /// Used as the primary dedupe key when a parent re-runs QR login.
    /// Nil for ENT children and for synthetic fallback children.
    var pawnoteID: String?
    var entChildId: String?        // ENT user ID for schoolbook API
    var entProvider: ENTProvider?   // pcn or monlycee
    var entClassName: String?      // Full class name from ENT (e.g. "CM1 - CM2 A - M. Lucas") for message filtering
    var family: Family?
    var createdAt: Date

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Grade.child)
    var grades: [Grade]
    @Relationship(deleteRule: .cascade, inverse: \ScheduleEntry.child)
    var schedule: [ScheduleEntry]
    @Relationship(deleteRule: .cascade, inverse: \Homework.child)
    var homework: [Homework]
    @Relationship(deleteRule: .cascade, inverse: \Message.child)
    var messages: [Message]
    @Relationship(deleteRule: .cascade, inverse: \Insight.child)
    var insights: [Insight]
    @Relationship(deleteRule: .cascade, inverse: \SchoolPhoto.child)
    var photos: [SchoolPhoto]

    init(
        firstName: String,
        level: SchoolLevel,
        grade: String,
        schoolType: SchoolType,
        establishment: String,
        pawnoteID: String? = nil
    ) {
        self.firstName = firstName
        self.level = level
        self.grade = grade
        self.schoolType = schoolType
        self.establishment = establishment
        self.pawnoteID = pawnoteID
        self.createdAt = .now
        self.grades = []
        self.schedule = []
        self.homework = []
        self.messages = []
        self.insights = []
        self.photos = []
    }
}

extension Child {
    /// Generic fallback label when the stored establishment is URL-shaped.
    /// Prefers the ENT provider name when available, then a schoolType-derived label.
    private var genericSchoolLabel: String {
        if schoolType == .ent {
            return entProvider?.name ?? "ENT"
        }
        return "École"
    }

    /// Parent-facing label for the school. Masks raw URLs that leak from the
    /// refresh-token login path — parents should never see a server hostname.
    /// Case-insensitive on the scheme and host checks; RFC 3986 says both are.
    var displayEstablishment: String {
        let lowered = establishment.lowercased()
        // URL-shaped: mask the hostname regardless of parseability
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            if let host = URL(string: establishment)?.host?.lowercased(),
               host.contains("index-education") {
                return "Pronote"
            }
            return genericSchoolLabel
        }
        return establishment
    }

    /// Binary status used to paint per-child alert dots across the UI.
    /// Covers urgent homework (< 24h), unread messages, and recent low grades.
    /// Centralized so ChildSelectorBar and ChildStoryRing share the same rule.
    var hasAlert: Bool {
        let now = Date.now
        let in24h = now.addingTimeInterval(86_400)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
        let urgentHomework = homework.contains { !$0.done && $0.dueDate <= in24h }
        let unreadMessages = messages.contains { !$0.read }
        let recentLowGrade = grades.contains {
            $0.date >= sevenDaysAgo && $0.normalizedValue < 10
        }
        return urgentHomework || unreadMessages || recentLowGrade
    }
}
