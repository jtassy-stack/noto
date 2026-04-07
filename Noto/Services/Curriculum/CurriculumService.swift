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
