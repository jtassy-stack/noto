import Foundation
import SwiftData

/// Loads and queries the BO curriculum reference data.
/// Bundled in app, updated annually via remote JSON.
final class CurriculumService {
    private var programs: [CurriculumProgram] = []

    // MARK: - Load

    /// Load curriculum from bundled JSON, then check for remote update.
    func load() async {
        loadBundled()
        await checkForUpdate()
    }

    private func loadBundled() {
        guard let url = Bundle.main.url(forResource: "curriculum", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(CurriculumRoot.self, from: data) else {
            return
        }
        programs = root.programs
    }

    private func checkForUpdate() async {
        // TODO: Fetch from remote URL (e.g. hosted on Vercel/S3)
        // Compare version, replace if newer
        // For now, bundled data is sufficient
    }

    // MARK: - Query

    /// Find curriculum themes matching a subject and level.
    func themes(for level: String, subject: String) -> [CurriculumTheme] {
        guard let program = programs.first(where: { $0.level == level }) else { return [] }

        let normalizedSubject = subject.lowercased().folding(options: .diacriticInsensitive, locale: .init(identifier: "fr"))

        for s in program.subjects {
            let normalizedName = s.name.lowercased().folding(options: .diacriticInsensitive, locale: .init(identifier: "fr"))
            if normalizedName.contains(normalizedSubject) || normalizedSubject.contains(normalizedName) {
                return s.themes
            }
        }
        return []
    }

    /// Match a chapter/homework description to curriculum keywords.
    /// Returns keywords suitable for querying culture-api.
    func matchKeywords(text: String, level: String, subject: String) -> [String] {
        let themes = themes(for: level, subject: subject)
        guard !themes.isEmpty else { return [] }

        let normalizedText = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "fr"))

        var matchedKeywords: [(keywords: [String], score: Int)] = []

        for theme in themes {
            var score = 0
            let normalizedTheme = theme.theme.lowercased()
                .folding(options: .diacriticInsensitive, locale: .init(identifier: "fr"))

            // Check if the text mentions the theme name
            if normalizedText.contains(normalizedTheme) {
                score += 10
            }

            // Check keyword matches
            for keyword in theme.keywords {
                let normalizedKeyword = keyword.lowercased()
                    .folding(options: .diacriticInsensitive, locale: .init(identifier: "fr"))
                if normalizedText.contains(normalizedKeyword) {
                    score += 3
                }
            }

            if score > 0 {
                matchedKeywords.append((keywords: theme.keywords, score: score))
            }
        }

        // Return keywords from the best matching theme(s)
        let sorted = matchedKeywords.sorted { $0.score > $1.score }
        let topKeywords = sorted.prefix(2).flatMap(\.keywords)
        return Array(Set(topKeywords)) // Deduplicate
    }

    /// Get all subjects for a given level.
    func subjects(for level: String) -> [String] {
        guard let program = programs.first(where: { $0.level == level }) else { return [] }
        return program.subjects.map(\.name)
    }

    /// Returns BO theme names for a given level and subject, suitable as culture-api search topics.
    /// Falls back to all themes for the level if the subject isn't found.
    func cultureTopics(for level: String, subject: String, maxPerSubject: Int = 2) -> [String] {
        let themes = themes(for: level, subject: subject)
        // Use theme names directly — they're rich BO phrases that match podcast content
        return Array(themes.map(\.theme).prefix(maxPerSubject))
    }

    /// Age range (min, max) for a given grade level.
    func ageRange(for level: String) -> (min: Int, max: Int) {
        switch level {
        case "CP": return (6, 7)
        case "CE1": return (7, 8)
        case "CE2": return (8, 9)
        case "CM1": return (9, 10)
        case "CM2": return (10, 11)
        case "6e": return (11, 12)
        case "5e": return (12, 13)
        case "4e": return (13, 14)
        case "3e": return (14, 15)
        case "2nde": return (15, 16)
        case "1re", "1ère": return (16, 17)
        case "Tle", "Terminale": return (17, 18)
        default: return (10, 18)
        }
    }

    /// Convert app grade (e.g. "3e", "6e") to celyn.io API format ("3eme", "6eme").
    func apiGrade(for grade: String) -> String {
        let g = grade.lowercased().trimmingCharacters(in: .whitespaces)
        // Already in API format
        if g.hasSuffix("eme") || g.hasSuffix("ème") { return g.replacingOccurrences(of: "ème", with: "eme") }
        // Short collège format: "6e" → "6eme", "3e" → "3eme"
        if let match = g.wholeMatch(of: /(\d)e/) {
            return "\(match.1)eme"
        }
        // Lycée
        if g == "2nde" || g == "seconde" { return "2nde" }
        if g == "1re" || g == "1ère" || g == "1ere" || g == "première" { return "1ere" }
        if g == "tle" || g == "terminale" { return "terminale" }
        // Primaire: CP, CE1, CE2, CM1, CM2 — already correct
        return g
    }

    /// Get all available levels.
    var levels: [String] {
        programs.map(\.level)
    }
}

// MARK: - Codable Types (for JSON parsing)

private struct CurriculumRoot: Codable {
    let version: String
    let lastUpdated: String
    let programs: [CurriculumProgram]
}

struct CurriculumProgram: Codable, Sendable {
    let level: String
    let cycle: Int
    let subjects: [CurriculumSubject]
}

struct CurriculumSubject: Codable, Sendable {
    let name: String
    let themes: [CurriculumTheme]
}

struct CurriculumTheme: Codable, Sendable {
    let theme: String
    let keywords: [String]
    let period: String?
}
