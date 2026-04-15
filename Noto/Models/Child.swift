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
        establishment: String
    ) {
        self.firstName = firstName
        self.level = level
        self.grade = grade
        self.schoolType = schoolType
        self.establishment = establishment
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
    /// Parent-facing label for the school, hiding raw Pronote URLs
    /// that leak from the refresh-token login path.
    var displayEstablishment: String {
        guard establishment.hasPrefix("http"),
              let host = URL(string: establishment)?.host else {
            return establishment
        }
        return host.contains("index-education") ? "Pronote" : host
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
