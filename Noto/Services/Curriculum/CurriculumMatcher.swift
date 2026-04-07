import Foundation

/// Connects school data (grades, schedule, homework) to culture-api queries
/// via the BO curriculum reference.
///
/// Flow: Chapter text → CurriculumService → keywords → culture-api search
struct CurriculumMatcher {
    let curriculumService: CurriculumService

    /// Build culture-api query parameters from a child's current school context.
    /// Aggregates keywords from recent schedule chapters and homework.
    func buildCultureQuery(
        level: String,
        recentChapters: [ChapterContext],
        difficulties: [DifficultyContext]
    ) -> CultureQuery {
        var allKeywords: [WeightedKeyword] = []

        // Keywords from current chapters (what they're studying)
        for chapter in recentChapters {
            let keywords = curriculumService.matchKeywords(
                text: chapter.text,
                level: level,
                subject: chapter.subject
            )
            for kw in keywords {
                allKeywords.append(WeightedKeyword(keyword: kw, weight: 1.0, isDifficulty: false))
            }
        }

        // Keywords from difficulties (where they struggle — boosted weight)
        for difficulty in difficulties {
            let keywords = curriculumService.matchKeywords(
                text: difficulty.subject,
                level: level,
                subject: difficulty.subject
            )
            for kw in keywords {
                allKeywords.append(WeightedKeyword(keyword: kw, weight: 1.5, isDifficulty: true))
            }
        }

        // Deduplicate, keep highest weight
        var keywordMap: [String: WeightedKeyword] = [:]
        for wk in allKeywords {
            if let existing = keywordMap[wk.keyword] {
                if wk.weight > existing.weight {
                    keywordMap[wk.keyword] = wk
                }
            } else {
                keywordMap[wk.keyword] = wk
            }
        }

        let sorted = keywordMap.values.sorted { $0.weight > $1.weight }
        let topKeywords = Array(sorted.prefix(10))

        return CultureQuery(
            topics: topKeywords.map(\.keyword),
            hasDifficultyContext: topKeywords.contains(where: \.isDifficulty),
            level: level
        )
    }
}

// MARK: - Supporting Types

struct ChapterContext {
    let subject: String
    let text: String     // Chapter name, homework description, etc.
}

struct DifficultyContext {
    let subject: String
    let trend: Double    // Negative = declining performance
}

struct CultureQuery {
    let topics: [String]
    let hasDifficultyContext: Bool
    let level: String

    /// Age range inferred from school level
    var ageRange: (min: Int, max: Int) {
        switch level {
        case "CP": (6, 7)
        case "CE1": (7, 8)
        case "CE2": (8, 9)
        case "CM1": (9, 10)
        case "CM2": (10, 11)
        case "6e": (11, 12)
        case "5e": (12, 13)
        case "4e": (13, 14)
        case "3e": (14, 15)
        case "2nde": (15, 16)
        case "1re", "1ère": (16, 17)
        case "Terminale", "Tle": (17, 18)
        default: (6, 18)
        }
    }

    /// Context hint for culture-api recommendation engine
    var context: String {
        hasDifficultyContext ? "educational_support" : "educational"
    }
}

struct WeightedKeyword {
    let keyword: String
    let weight: Double
    let isDifficulty: Bool
}
