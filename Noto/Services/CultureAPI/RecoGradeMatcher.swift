import Foundation

/// Pure rules tying a culture-api result's `curriculumTags` to the level of
/// the child it is shown for, in the Discover tab.
///
/// culture-api tags look like `"<niveau>-<matière>"`, with mixed case:
/// `"6eme-histoire"`, `"3eme-francais"`, `"2nde-histoire"`, `"1ere-arts"`,
/// `"terminale-philosophie"`, `"CE2-francais"`, `"GS-sciences"`. A single
/// result usually carries tags for several levels (a podcast tagged both
/// `CE2-francais` and `terminale-philosophie`).
///
/// Contract (retour TestFlight « Pas très cohérent entre enfant et classe
/// identifié ») :
/// - a level badge shown next to « Pour <enfant> » is always the child's own
///   level — never another level's tag as a fallback;
/// - a result whose tags are all for other levels is not attributed to the
///   child at all.
enum RecoGradeMatcher {

    /// Level code in culture-api format (`"6eme"`, `"2nde"`, `"1ere"`,
    /// `"terminale"`, `"ce2"`), lowercased, or nil when the child's grade is
    /// unknown (empty / unrecognised label).
    static func gradeCode(for childGrade: String?) -> String? {
        guard let childGrade else { return nil }
        let trimmed = childGrade.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let code = CurriculumService.apiGrade(for: trimmed).lowercased()
        // `apiGrade` passes unrecognised labels through (the "?" placeholder
        // from ENTLoginView, raw connector class names): only a real
        // culture-api level code may become a grade filter or a match key.
        return supportedGradeCodes.contains(code) ? code : nil
    }

    /// Level codes culture-api understands, lowercased.
    static let supportedGradeCodes: Set<String> = [
        "ps", "ms", "gs", "cp", "ce1", "ce2", "cm1", "cm2",
        "6eme", "5eme", "4eme", "3eme", "2nde", "1ere", "terminale",
    ]

    /// Level part of a tag (`"terminale"` for `"terminale-philosophie"`),
    /// lowercased, or nil for a malformed tag.
    static func tagLevel(_ tag: String) -> String? {
        let parts = tag.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0].lowercased()
    }

    /// Tags whose level is exactly the child's level, in original order.
    /// Empty when the grade is unknown or nothing matches — no fallback.
    static func matchingTags(_ tags: [String], childGrade: String?) -> [String] {
        guard let code = gradeCode(for: childGrade) else { return [] }
        return tags.filter { tagLevel($0) == code }
    }

    /// Whether a result can be presented « Pour <enfant> ». True when it has
    /// a tag for the child's level, and also when it cannot be judged (no
    /// level tags — events — or unknown grade): the request itself was
    /// already grade-filtered. False only when every level tag is for
    /// another level.
    static func isForChildLevel(tags: [String], childGrade: String?) -> Bool {
        guard let code = gradeCode(for: childGrade) else { return true }
        let levels = tags.compactMap(tagLevel)
        guard !levels.isEmpty else { return true }
        return levels.contains(code)
    }

    /// The (at most one) level badge to show for a result linked to a child.
    /// No linked level → no badge.
    static func badgeTags(_ tags: [String], linkedLevel: String?) -> [String] {
        Array(matchingTags(tags, childGrade: linkedLevel).prefix(1))
    }

    /// `"3eme-histoire"` → `"Histoire · 3e"`, `"1ere-francais"` →
    /// `"Francais · 1re"`, `"terminale-philosophie"` → `"Philosophie · Tle"`,
    /// `"CE2-francais"` → `"Francais · CE2"`. Malformed tags pass through.
    static func formatTag(_ tag: String) -> String {
        let parts = tag.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return tag }
        let subjectRaw = String(parts[1])
        let subject = subjectRaw.prefix(1).uppercased() + subjectRaw.dropFirst()
        return "\(subject) · \(displayLevel(String(parts[0])))"
    }

    /// Short French label for a culture-api level code.
    static func displayLevel(_ code: String) -> String {
        let c = code.lowercased()
        switch c {
        case "terminale", "tle": return "Tle"
        case "1ere", "1re": return "1re"
        case "2nde", "seconde": return "2nde"
        default:
            if let m = c.wholeMatch(of: /(\d)eme/) { return "\(m.1)e" }
            return code.uppercased()
        }
    }
}
