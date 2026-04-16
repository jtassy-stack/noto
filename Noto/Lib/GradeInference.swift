import Foundation

/// Pure helpers that map a Pronote `className` string to a canonical
/// `(grade, SchoolLevel)` pair used by CurriculumService and SwiftData.
///
/// Extracted from `PronoteQRLoginView` so the substring matching rules
/// are covered by unit tests instead of living inside a SwiftUI view.
enum GradeInference {

    /// Canonical grade label (`"6e"`, `"3e"`, `"1re"`, `"Tle"`, …) or
    /// empty string when `className` does not mention a recognizable level —
    /// CurriculumService treats empty as "fall back to general recos"
    /// rather than storing a garbage prefix.
    static func grade(from className: String) -> String {
        // Strip diacritics and lowercase in one pass so "3ème" / "1ère" /
        // "1re A" all collapse to the canonical forms CurriculumService keys on.
        let normalized = className.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "fr")
        )
        // Longest patterns first so a long form can't be stolen by its prefix
        // (e.g. "6eme" must match before "6e", "1ere" before "1re").
        let patterns: [(match: String, canonical: String)] = [
            ("2nde", "2nde"),
            ("1ere", "1re"),
            ("1re", "1re"),
            ("tle", "Tle"),
            ("6eme", "6e"), ("6e", "6e"),
            ("5eme", "5e"), ("5e", "5e"),
            ("4eme", "4e"), ("4e", "4e"),
            ("3eme", "3e"), ("3e", "3e"),
        ]
        for (match, canonical) in patterns where normalized.contains(match) {
            return canonical
        }
        return ""
    }

    /// `.college` or `.lycee` inferred from `className`. Defaults to
    /// `.college` when nothing matches.
    static func level(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        let collegePatterns = ["6e", "5e", "4e", "3e"]
        let lyceePatterns = ["2nde", "1re", "1ere", "tle"]
        if collegePatterns.contains(where: { hasWordBoundaryPrefix(lower, pattern: $0) }) {
            return .college
        }
        if lyceePatterns.contains(where: { hasWordBoundaryPrefix(lower, pattern: $0) }) {
            return .lycee
        }
        return .college
    }

    /// Returns true when `text` contains `pattern` preceded by a
    /// non-alphanumeric character or at the start of the string.
    /// No suffix boundary — `"6eA"` (no space after) is plausible
    /// in Pronote class names and must still match.
    private static func hasWordBoundaryPrefix(_ text: String, pattern: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                return true
            }
            let preceding = text[text.index(before: range.lowerBound)]
            if !preceding.isLetter && !preceding.isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}
