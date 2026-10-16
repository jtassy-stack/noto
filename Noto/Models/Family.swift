import Foundation
import SwiftData

@Model
final class Family {
    var parentName: String
    @Relationship(deleteRule: .cascade, inverse: \Child.family)
    var children: [Child]
    /// Parent lane: mail from an IMAP account assigned to "Parent"
    /// (`MailboxAssignment.parent`), not tied to one child. Additive to-many
    /// with an inline default — lightweight-migration compatible (see
    /// `NotoSchemaV1`). Cascade so "Effacer toutes les données" removes it.
    @Relationship(deleteRule: .cascade, inverse: \Message.family)
    var messages: [Message] = []
    var createdAt: Date

    init(parentName: String) {
        self.parentName = parentName
        self.children = []
        self.createdAt = .now
    }
}
