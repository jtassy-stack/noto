import Foundation
import SwiftData

enum RecoType: String, Codable {
    case event
    case podcast
    case oeuvre
}

@Model
final class CultureReco {
    var child: Child?
    var type: RecoType
    var title: String
    var descriptionText: String
    var cultureApiId: Int
    var linkedSubject: String?
    var linkedTheme: String?
    var linkedDifficulty: Bool
    var expiresAt: Date
    var imageURL: String?

    /// When a reco matches multiple children (e.g. family outing)
    var matchedChildrenNames: [String]

    var isFamily: Bool { matchedChildrenNames.count > 1 }

    init(
        type: RecoType,
        title: String,
        description: String,
        cultureApiId: Int,
        linkedSubject: String? = nil,
        linkedTheme: String? = nil,
        linkedDifficulty: Bool = false,
        expiresAt: Date
    ) {
        self.type = type
        self.title = title
        self.descriptionText = description
        self.cultureApiId = cultureApiId
        self.linkedSubject = linkedSubject
        self.linkedTheme = linkedTheme
        self.linkedDifficulty = linkedDifficulty
        self.expiresAt = expiresAt
        self.matchedChildrenNames = []
    }
}
