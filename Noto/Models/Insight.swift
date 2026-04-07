import Foundation
import SwiftData

enum InsightType: String, Codable {
    case trend       // progression ou régression
    case difficulty  // matière en difficulté
    case strength    // point fort
    case alert       // signal bien-être
}

@Model
final class Insight {
    var child: Child?
    var type: InsightType
    var subject: String
    var value: String       // description naturelle en français
    var confidence: Double  // 0...1
    var detectedAt: Date

    init(type: InsightType, subject: String, value: String, confidence: Double) {
        self.type = type
        self.subject = subject
        self.value = value
        self.confidence = confidence
        self.detectedAt = .now
    }
}
