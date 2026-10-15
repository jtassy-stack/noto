import Foundation

/// Pure helpers that map a Pronote / ENT `className` string to a canonical
/// `(grade, SchoolLevel)` pair used by CurriculumService and SwiftData.
///
/// Extracted from `PronoteQRLoginView` so the matching rules are covered by
/// unit tests instead of living inside a SwiftUI view.
///
/// Matching is token-based: the folded, lowercased label is split on every
/// non-alphanumeric character, so a pattern can only match at the start of a
/// token ("subtle" never yields "Tle", "16e" never yields "6e"). Runs of
/// consecutive single-character tokens are merged first so spaced-out
/// Pronote codes ("1 G 2", "T G 3") read as "1g2" / "tg3".
enum GradeInference {

    /// Canonical grade label (`"6e"`, `"3e"`, `"2nde"`, `"1re"`, `"Tle"`) or
    /// empty string when `className` does not mention a recognizable level —
    /// CurriculumService treats empty as "fall back to general recos"
    /// rather than storing a garbage prefix.
    static func grade(from className: String) -> String {
        let tokens = mergedTokens(className)
        // First token that matches any rule wins, so a trailing group or
        // trimester code ("3E T1", "5e - T2") never overrides the level
        // written first. Within a token, lycée rules run before collège ones.
        for (i, token) in tokens.enumerated() {
            if let lycee = lyceeGrade(token) { return lycee }
            if let college = collegeGrade(token) { return college }
            if i + 1 < tokens.count, let split = splitLyceeGrade(token, next: tokens[i + 1]) {
                return split
            }
        }
        return ""
    }

    /// `.college` or `.lycee` inferred from `className`. Derived from
    /// `grade(from:)` so both stay consistent; defaults to `.college` when
    /// nothing matches.
    static func level(from className: String) -> SchoolLevel {
        switch grade(from: className) {
        case "2nde", "1re", "Tle": return .lycee
        default: return .college
        }
    }

    // MARK: - Token rules

    /// Lycée technological series suffixes after "1"/"T" ("1STMG", "TSTI2D").
    private static let seriesPrefix = "st"

    private static func lyceeGrade(_ t: String) -> String? {
        // Seconde: "2nde", "2de", "2gt", "seconde" (+ optional class suffix: "2nde4", "2de3").
        if t == "seconde" || t.hasPrefix("2nde") || t.hasPrefix("2de") || t.hasPrefix("2gt") {
            return "2nde"
        }
        // Première: "1ere", "1re", "premiere", "1g", "1g3", "1stmg"…
        if t == "premiere" || t.hasPrefix("1ere") || t.hasPrefix("1re") {
            return "1re"
        }
        if t.hasPrefix("1") {
            let rest = t.dropFirst()
            if rest.first == "g", rest.dropFirst().allSatisfy(\.isNumber) { return "1re" }
            if rest.hasPrefix(seriesPrefix), rest.count > seriesPrefix.count { return "1re" }
        }
        // Terminale: "tle", "terminale", "tg", "tg2", "tstmg", "t1".
        if t == "terminale" || t.hasPrefix("tle") {
            return "Tle"
        }
        if t.hasPrefix("t") {
            let rest = t.dropFirst()
            if rest.first == "g", rest.dropFirst().allSatisfy(\.isNumber) { return "Tle" }
            if rest.hasPrefix(seriesPrefix), rest.count > seriesPrefix.count,
               rest.allSatisfy({ $0.isLetter || $0.isNumber }) { return "Tle" }
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return "Tle" }
        }
        return nil
    }

    /// Technological series codes written after a detached "1" / "T"
    /// ("T STMG", "1 STI2D 2", "T-STL").
    private static let seriesCodes = ["stmg", "sti2d", "stl", "st2s", "std2a", "sthr", "stav", "s2tmd"]

    /// A lone "1" / "t" followed by a series code or "g<digits>" ("T STMG",
    /// "1 STI2D", "T G3"). The single-character merge cannot catch these
    /// because the next token is longer than one character.
    private static func splitLyceeGrade(_ t: String, next: String) -> String? {
        let grade: String
        switch t {
        case "1": grade = "1re"
        case "t": grade = "Tle"
        default: return nil
        }
        if seriesCodes.contains(where: { next.hasPrefix($0) }) { return grade }
        if next.first == "g", next.count > 1, next.dropFirst().allSatisfy(\.isNumber) { return grade }
        return nil
    }

    private static func collegeGrade(_ t: String) -> String? {
        // Prefix-only (no suffix boundary): "6eA" is a plausible Pronote class name.
        for digit in ["6", "5", "4", "3"] where t.hasPrefix(digit + "e") {
            return digit + "e"
        }
        return nil
    }

    // MARK: - Tokenisation

    /// Folded, lowercased alphanumeric tokens, with runs of ≥ 2 consecutive
    /// single-character tokens merged ("1 g 2" → "1g2").
    static func mergedTokens(_ className: String) -> [String] {
        let folded = className.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "fr")
        ).lowercased()
        let raw = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        var result: [String] = []
        var run: [String] = []
        func flushRun() {
            if run.count >= 2 { result.append(run.joined()) } else { result.append(contentsOf: run) }
            run.removeAll()
        }
        for token in raw {
            if token.count == 1 {
                run.append(token)
            } else {
                flushRun()
                result.append(token)
            }
        }
        flushRun()
        return result
    }
}
