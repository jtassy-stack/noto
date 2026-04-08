import Foundation
import SwiftData

@Model
final class Family {
    var parentName: String
    @Relationship(deleteRule: .cascade, inverse: \Child.family)
    var children: [Child]
    var createdAt: Date

    init(parentName: String) {
        self.parentName = parentName
        self.children = []
        self.createdAt = .now
    }
}
