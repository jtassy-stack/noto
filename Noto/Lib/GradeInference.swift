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
    /// `.college` when nothing matches — preserves the historical
    /// behavior of `PronoteQRLoginView.inferLevel`.
    static func level(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        if lower.contains("6e") || lower.contains("5e") || lower.contains("4e") || lower.contains("3e") {
            return .college
        }
        if lower.contains("2nde") || lower.contains("1re") || lower.contains("1ere") || lower.contains("tle") {
            return .lycee
        }
        return .college
    }
}
