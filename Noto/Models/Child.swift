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
    }
}
