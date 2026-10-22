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
        let runs = mergedTokenRuns(className)
        let tokens = runs.map { $0.token }
        // First token that matches any rule wins, so a trailing group or
        // trimester code ("3E T1", "5e - T2") never overrides the level
        // written first. Within a token, lycée rules run before collège ones.
        for (i, token) in tokens.enumerated() {
            // A bare "1 G" / "T G" glued from spaced single letters is too
            // weak a signal ("Groupe 1 G") — require the class digit ("1 G 2").
            let weakMerge = runs[i].merged && token.count == 2 && token.last == "g"
            if !weakMerge, let lycee = lyceeGrade(token) { return lycee }
            if let college = collegeGrade(token) { return college }
            if let coded = numericClassCode(token) { return coded }
            // "2A", "2B": seconde + class letter, only as a token written
            // that way (a glued "Groupe 2 A" stays unrecognised).
            if !runs[i].merged, token.count == 2, token.first == "2", token.last?.isLetter == true {
                return "2nde"
            }
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

    /// New `(grade, level)` to store when a sync reads `className` for a child
    /// whose stored grade is `current`; nil when nothing should change. A
    /// label that is not recognised never erases a stored grade, and a
    /// recognised one replaces an empty or outdated grade (a child added
    /// before a class-code rule existed, or a new school year).
    static func refreshedGrade(current: String, className: String) -> (grade: String, level: SchoolLevel)? {
        let grade = grade(from: className)
        guard !grade.isEmpty, grade != current else { return nil }
        return (grade, level(from: className))
    }

    /// Primary-school codes, in the priority order of the legacy ENT /
    /// Skolengo / École Directe parsers.
    static let primaryGrades = ["PS", "MS", "GS", "CP", "CE1", "CE2", "CM1", "CM2"]

    /// Canonical `(grade, level)` for any connector's class label, or nil when
    /// nothing is recognised (callers keep their own legacy fallback then).
    ///
    /// Primary codes are checked first, on whole tokens only, so a primary
    /// label carrying a trimester / group code ("CM2 T1") never reads as a
    /// lycée level; then `grade(from:)` for collège / lycée.
    static func resolve(_ className: String) -> (grade: String, level: SchoolLevel)? {
        if let primary = primaryGrade(from: className) {
            let level: SchoolLevel = ["PS", "MS", "GS"].contains(primary) ? .maternelle : .elementaire
            return (primary, level)
        }
        let secondary = grade(from: className)
        guard !secondary.isEmpty else { return nil }
        return (secondary, level(from: className))
    }

    /// Primary-school code ("CP", "CE1", …, "PS") when one appears as a whole
    /// token ("CM1 - CM2 A", "CE1-B") or followed by a single class letter
    /// for the digit-ending codes ("CM2A"). Nil otherwise.
    static func primaryGrade(from className: String) -> String? {
        let folded = className.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "fr")
        ).lowercased()
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for code in primaryGrades {
            let c = code.lowercased()
            let endsWithDigit = c.last?.isNumber == true
            let hit = tokens.contains { t in
                if t == c { return true }
                guard endsWithDigit, t.hasPrefix(c), t.count == c.count + 1 else { return false }
                return t.last?.isLetter == true
            }
            if hit { return code }
        }
        return nil
    }

    // MARK: - Token rules

    /// Lycée technological series suffixes after "1"/"T" ("1STMG", "TSTI2D").
    private static let seriesPrefix = "st"

    private static func lyceeGrade(_ t: String) -> String? {
        // Seconde: "2nde", "2de", "2gt", "seconde" (+ optional class suffix: "2nde4", "2de3").
        if t == "seconde" || t.hasPrefix("2nde") || t.hasPrefix("2de") || t.hasPrefix("2gt") {
            return "2nde"
        }
        // "2e", "2eme", "2e3", "2eB": in a secondary school, a level written
        // "2e" can only be seconde (collège stops at 3e).
        if t.hasPrefix("2e") {
            let rest = t.dropFirst(2)
            let suffix = rest.hasPrefix("me") ? rest.dropFirst(2) : rest
            if suffix.allSatisfy(\.isNumber) || (suffix.count == 1 && suffix.first?.isLetter == true) {
                return "2nde"
            }
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
        // Terminale: "tle", "term", "terminale", "tg", "tg2", "tstmg", "t1".
        // "tle" / "term" only as a level code (bare, or + class digits / "g"
        // + digits / series code) — never as the start of a word or a
        // teacher name ("Termeau", "Tlemsani").
        if t == "terminale" || isLevelCode(t, stem: "tle") || isLevelCode(t, stem: "term") {
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

    /// `t` is `stem` alone or followed by a class suffix: digits ("tle3"),
    /// "g" + digits ("tleg1"), or a technological series code ("tlestmg").
    private static func isLevelCode(_ t: String, stem: String) -> Bool {
        guard t.hasPrefix(stem) else { return false }
        let rest = t.dropFirst(stem.count)
        if rest.allSatisfy(\.isNumber) { return true }
        if rest.first == "g", rest.dropFirst().allSatisfy(\.isNumber) { return true }
        return seriesCodes.contains(where: { rest.hasPrefix($0) })
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
        // Spelled-out levels (École Directe: "Troisième", "SIXIEME").
        switch t {
        case "sixieme": return "6e"
        case "cinquieme": return "5e"
        case "quatrieme": return "4e"
        case "troisieme": return "3e"
        default: break
        }
        // Prefix-only (no suffix boundary): "6eA" is a plausible Pronote class name.
        for digit in ["6", "5", "4", "3"] where t.hasPrefix(digit + "e") {
            return digit + "e"
        }
        return nil
    }

    /// Numeric Pronote class codes: level digit + two-digit class number
    /// ("201" = seconde 1, "604" = sixième 4, "103" = première 3). Exactly
    /// three digits, so a year ("2026") or a bare group number never matches.
    private static func numericClassCode(_ t: String) -> String? {
        guard t.count == 3, t.allSatisfy(\.isNumber), let first = t.first else { return nil }
        switch first {
        case "6": return "6e"
        case "5": return "5e"
        case "4": return "4e"
        case "3": return "3e"
        case "2": return "2nde"
        case "1": return "1re"
        default: return nil
        }
    }

    // MARK: - Tokenisation

    /// Folded, lowercased alphanumeric tokens, with runs of ≥ 2 consecutive
    /// single-character tokens merged ("1 g 2" → "1g2").
    static func mergedTokens(_ className: String) -> [String] {
        mergedTokenRuns(className).map { $0.token }
    }

    /// `mergedTokens` plus, per token, whether it was glued from a run of
    /// single-character tokens.
    private static func mergedTokenRuns(_ className: String) -> [(token: String, merged: Bool)] {
        let folded = className.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "fr")
        ).lowercased()
        let raw = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        var result: [(token: String, merged: Bool)] = []
        var run: [String] = []
        func flushRun() {
            if run.count >= 2 {
                result.append((run.joined(), true))
            } else {
                result.append(contentsOf: run.map { ($0, false) })
            }
            run.removeAll()
        }
        for token in raw {
            if token.count == 1 {
                run.append(token)
            } else {
                flushRun()
                result.append((token, false))
            }
        }
        flushRun()
        return result
    }
}
