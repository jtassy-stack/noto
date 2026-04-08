import Foundation
import SwiftData

/// Programme scolaire issu du Bulletin Officiel de l'Éducation Nationale.
/// Bundled dans l'app, mis à jour annuellement via JSON distant.
@Model
final class Curriculum {
    var level: String        // "6e", "CE1", "Terminale"
    var subject: String      // "Histoire", "Mathématiques"
    var theme: String        // "La Révolution française"
    var keywords: [String]   // ["1789", "Bastille", "Robespierre"] — pour matching culture-api
    var period: String?      // "Trimestre 2"

    init(level: String, subject: String, theme: String, keywords: [String], period: String? = nil) {
        self.level = level
        self.subject = subject
        self.theme = theme
        self.keywords = keywords
        self.period = period
    }
}
