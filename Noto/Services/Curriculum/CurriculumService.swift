import Foundation
import SwiftData

/// Loads and queries the BO curriculum reference data.
/// Bundled in app, updated annually via remote JSON.
final class CurriculumService {
    private var programs: [CurriculumProgram] = []

    /// Levels covered by the revisions path (collège + lycée). CP → CM2 stay
    /// in `curriculum.json` for the Discover tab but get no revision content.
    static let revisionLevels = ["6e", "5e", "4e", "3e", "2nde", "1re", "Tle"]

    init() {}

    /// Build a service from already-decoded programs (tests, previews).
    init(programs: [CurriculumProgram]) {
        self.programs = programs
    }

    // MARK: - Load

    /// Load curriculum from bundled JSON, then check for remote update.
    func load() async {
        loadBundled()
        await checkForUpdate()
    }

    /// Synchronously load the bundled `curriculum.json` (no-op on failure).
    func loadBundled() {
        guard let url = Bundle.main.url(forResource: "curriculum", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return
        }
        try? load(from: data)
    }

    /// Replace the loaded programs with the ones decoded from `data`.
    func load(from data: Data) throws {
        programs = try Self.decodePrograms(from: data)
    }

    /// Decode the `curriculum.json` root and return its programs.
    static func decodePrograms(from data: Data) throws -> [CurriculumProgram] {
        try JSONDecoder().decode(CurriculumRoot.self, from: data).programs
    }

    private func checkForUpdate() async {
        // TODO: Fetch from remote URL (e.g. hosted on Vercel/S3)
        // Compare version, replace if newer
        // For now, bundled data is sufficient
    }

    // MARK: - Query

    /// The program for a level, if loaded.
    func program(for level: String) -> CurriculumProgram? {
        programs.first(where: { $0.level == level })
    }

    /// Subjects of `level` matching a (Pronote) subject label, filtered by
    /// track: tronc commun subjects are always eligible; spécialités are
    /// eligible when `specialties` is nil/empty (unknown) or contains the
    /// subject's specialty.
    func matchingSubjects(for level: String, subject: String, specialties: [String]? = nil) -> [CurriculumSubject] {
        guard let program = program(for: level) else { return [] }
        let candidates = program.subjects.filter { isEligible($0, specialties: specialties) }

        // 1. Alias table → canonical names (may be several, e.g. HISTOIRE-GEOGRAPHIE).
        //    When none of the canonical names exists at this level (TECHNOLOGIE
        //    in 6e, where the BO subject is "Sciences et technologie"), fall
        //    through to the label-based steps instead of returning nothing.
        //    Existence is checked before the spécialité filter, so a subject
        //    filtered out by `specialties` stays filtered out.
        let canonical = SubjectAlias.canonicalNames(for: subject)
        if !canonical.isEmpty {
            let keys = Set(canonical.map(SubjectAlias.compact))
            let aliased = program.subjects.filter { subjectKeys($0).contains(where: keys.contains) }
            if !aliased.isEmpty {
                return aliased.filter { isEligible($0, specialties: specialties) }
            }
        }

        // 2. Exact normalised equality (LV1/LV2/SPE markers dropped).
        let labelTokens = SubjectAlias.meaningfulTokens(subject)
        let label = labelTokens.joined()
        guard !label.isEmpty else { return [] }
        let exact = candidates.filter { subjectKeys($0).contains(label) }
        if !exact.isEmpty { return exact }

        // 3. Whole-word containment. The subject name's tokens appearing as
        //    whole tokens in the label is accepted at any length ("SVT 1",
        //    "EMC (enseignement moral)"); the reverse direction (label inside
        //    the subject name) needs ≥ 4 chars on both sides. Never substrings
        //    inside a word ("si" must not match "physique").
        return candidates.filter { s in
            let nameTokens = SubjectAlias.tokens(s.name)
            if Self.containsSequence(labelTokens, nameTokens) { return true }
            guard SubjectAlias.compact(s.name).count >= 4, label.count >= 4 else { return false }
            return Self.containsSequence(nameTokens, labelTokens)
        }
    }

    /// Find curriculum themes matching a subject and level. When several
    /// subjects match the label, returns the union of their themes.
    func themes(for level: String, subject: String, specialties: [String]? = nil) -> [CurriculumTheme] {
        matchingSubjects(for: level, subject: subject, specialties: specialties).flatMap(\.themes)
    }

    /// Match a chapter/homework description to curriculum keywords.
    /// Returns keywords suitable for querying culture-api.
    func matchKeywords(text: String, level: String, subject: String, specialties: [String]? = nil) -> [String] {
        let themes = themes(for: level, subject: subject, specialties: specialties)
        guard !themes.isEmpty else { return [] }

        let normalizedText = SubjectAlias.fold(text)

        var matchedKeywords: [(keywords: [String], score: Int)] = []

        for theme in themes {
            var score = 0
            let normalizedTheme = SubjectAlias.fold(theme.theme)

            // Check if the text mentions the theme name
            if !normalizedTheme.isEmpty && normalizedText.contains(normalizedTheme) {
                score += 10
            }

            // Check keyword matches
            for keyword in theme.keywords where Self.textMatches(normalizedText, keyword: SubjectAlias.fold(keyword)) {
                score += 3
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

    // MARK: - Matching helpers

    private func isEligible(_ subject: CurriculumSubject, specialties: [String]?) -> Bool {
        guard subject.track == .specialite else { return true }
        guard let specialties, !specialties.isEmpty else { return true }
        // Spécialité row with no `specialty` value: fall back to its name.
        let own = subject.specialty ?? subject.name
        let ownKeys = Set([SubjectAlias.compact(own)] + SubjectAlias.canonicalNames(for: own).map(SubjectAlias.compact))
        return specialties.contains { wanted in
            let wantedKeys = [SubjectAlias.compact(wanted)] + SubjectAlias.canonicalNames(for: wanted).map(SubjectAlias.compact)
            return wantedKeys.contains(where: ownKeys.contains)
        }
    }

    /// Compact keys a subject answers to: its name and, for spécialités, its specialty.
    private func subjectKeys(_ subject: CurriculumSubject) -> [String] {
        var keys = [SubjectAlias.compact(subject.name)]
        if let specialty = subject.specialty { keys.append(SubjectAlias.compact(specialty)) }
        return keys
    }

    /// Short keywords (folded length < 4, e.g. "adn", "pib", "onu") match on
    /// whole-word boundaries only; longer keywords keep substring matching.
    static func textMatches(_ foldedText: String, keyword foldedKeyword: String) -> Bool {
        guard !foldedKeyword.isEmpty else { return false }
        if foldedKeyword.count >= 4 { return foldedText.contains(foldedKeyword) }
        var searchStart = foldedText.startIndex
        while let range = foldedText.range(of: foldedKeyword, range: searchStart..<foldedText.endIndex) {
            let beforeOK = range.lowerBound == foldedText.startIndex
                || !Self.isWordChar(foldedText[foldedText.index(before: range.lowerBound)])
            let afterOK = range.upperBound == foldedText.endIndex
                || !Self.isWordChar(foldedText[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = foldedText.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// True when `needle` appears as a contiguous run inside `haystack`.
    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// Get all subjects for a given level.
    func subjects(for level: String) -> [String] {
        guard let program = programs.first(where: { $0.level == level }) else { return [] }
        return program.subjects.map(\.name)
    }

    /// Returns BO theme names for a given level and subject, suitable as culture-api search topics.
    /// Falls back to all themes for the level if the subject isn't found.
    func cultureTopics(for level: String, subject: String, maxPerSubject: Int = 2, specialties: [String]? = nil) -> [String] {
        let themes = themes(for: level, subject: subject, specialties: specialties)
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

    /// Convert app grade to celyn.io API format.
    /// Collège: "3e" → "3eme". Lycée: "2nde", "1re" → "1ere", "Tle" → "terminale". Primaire: passed through.
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
    let version: String?
    let lastUpdated: String?
    let programs: [CurriculumProgram]
}

struct CurriculumProgram: Codable, Sendable {
    let level: String
    let cycle: Int
    let subjects: [CurriculumSubject]
}

enum CurriculumTrack: String, Codable, Sendable {
    case troncCommun = "tronc_commun"
    case specialite
}

struct CurriculumSubject: Codable, Sendable {
    let name: String
    /// Missing in the pre-lycée JSON shape, or an unknown value → `.troncCommun`.
    let track: CurriculumTrack
    /// Spécialité name ("HGGSP", "NSI", …) for `.specialite` rows, nil otherwise.
    let specialty: String?
    let themes: [CurriculumTheme]

    init(name: String, track: CurriculumTrack = .troncCommun, specialty: String? = nil, themes: [CurriculumTheme]) {
        self.name = name
        self.track = track
        self.specialty = specialty
        self.themes = themes
    }

    private enum CodingKeys: String, CodingKey {
        case name, track, specialty, themes
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        // Lenient: an unknown future value ("option", …) must not fail the
        // whole curriculum decode — it reads as tronc commun.
        track = (try? c.decodeIfPresent(CurriculumTrack.self, forKey: .track)) ?? .troncCommun
        specialty = try c.decodeIfPresent(String.self, forKey: .specialty)
        themes = try c.decode([CurriculumTheme].self, forKey: .themes)
    }
}

struct CurriculumTheme: Codable, Sendable {
    let theme: String
    let keywords: [String]
    let period: String?
}

// MARK: - Pronote subject-label aliases

/// Maps free-form Pronote / ENT subject labels ("HIST.GEO.", "SC. ECONO.& SOCIALES",
/// "ANGLAIS LV1", …) to the canonical subject names used in `curriculum.json`.
enum SubjectAlias {
    /// Raw Pronote label → canonical names. Keys go through `compact`, so
    /// punctuation/spacing/accents/case variants collapse onto one entry.
    private static let rawTable: [(label: String, canonical: [String])] = [
        ("HISTOIRE-GEOGRAPHIE", ["Histoire", "Géographie"]),
        ("HIST.GEO.", ["Histoire", "Géographie"]),
        ("HIST-GEO", ["Histoire", "Géographie"]),
        ("HISTOIRE GEOGRAPHIE EMC", ["Histoire", "Géographie", "EMC"]),
        ("HISTOIRE-GEOGRAPHIE-EMC", ["Histoire", "Géographie", "EMC"]),
        ("SCIENCES VIE & TERRE", ["SVT"]),
        ("SCIENCES DE LA VIE ET DE LA TERRE", ["SVT"]),
        ("S.V.T.", ["SVT"]),
        ("PHYSIQUE-CHIMIE", ["Physique-Chimie"]),
        ("SC.PHYSIQUES", ["Physique-Chimie"]),
        ("SCIENCES PHYSIQUES", ["Physique-Chimie"]),
        ("PHYS.CHIM.", ["Physique-Chimie"]),
        ("SC. ECONO.& SOCIALES", ["SES"]),
        ("SCIENCES ECONOMIQUES ET SOCIALES", ["SES"]),
        ("S.E.S.", ["SES"]),
        ("ANGLAIS", ["Anglais"]),
        ("ESPAGNOL", ["Espagnol"]),
        ("ENSEIGN.SCIENTIFIQUE", ["Enseignement scientifique"]),
        ("ENSEIGNEMENT SCIENTIFIQUE", ["Enseignement scientifique"]),
        ("HIST.GEO.GEOPOL.&SC.POL.", ["HGGSP"]),
        ("HISTOIRE GEOGRAPHIE GEOPOLITIQUE ET SCIENCES POLITIQUES", ["HGGSP"]),
        ("HUMAN.LITTER.PHILO.", ["HLP"]),
        ("HUMANITES LITTERATURE ET PHILOSOPHIE", ["HLP"]),
        ("NUMERIQUE SC.INFORM.", ["NSI"]),
        ("NUMERIQUE ET SCIENCES INFORMATIQUES", ["NSI"]),
        ("SC. INGENIEUR", ["SI"]),
        ("SCIENCES DE L'INGENIEUR", ["SI"]),
        ("LLC ANGL.MOND.CONT.", ["LLCER Anglais"]),
        ("LLCER ANGLAIS", ["LLCER Anglais"]),
        ("ENS. MORAL & CIVIQUE", ["EMC"]),
        ("ENSEIGNEMENT MORAL ET CIVIQUE", ["EMC"]),
        ("EDUCATION CIVIQUE", ["EMC"]),
        ("FRANCAIS", ["Français"]),
        ("MATHEMATIQUES", ["Mathématiques"]),
        ("MATHS", ["Mathématiques"]),
        ("MATH", ["Mathématiques"]),
        ("PHILOSOPHIE", ["Philosophie"]),
        ("PHILO", ["Philosophie"]),
        ("SC. NUMERIQ.TECHNOL.", ["SNT"]),
        ("SCIENCES NUMERIQUES ET TECHNOLOGIE", ["SNT"]),
        ("TECHNOLOGIE", ["Technologie"]),
        ("EDUCATION MUSICALE", ["Éducation musicale"]),
        ("ED. MUSICALE", ["Éducation musicale"]),
        ("ARTS PLASTIQUES", ["Arts plastiques"]),
        ("ED.PHYSIQUE & SPORT.", ["EPS"]),
        ("EDUCATION PHYSIQUE ET SPORTIVE", ["EPS"]),
        ("SCIENCES ET TECHNOLOGIE", ["Sciences et technologie"]),
    ]

    /// Tokens dropped before lookup: language-rank and spécialité markers
    /// ("ANGLAIS LV1", "LV2 ESPAGNOL", "SPE MATHS").
    private static let noiseTokens: Set<String> = ["lv1", "lv2", "lv3", "lva", "lvb", "lvc", "spe", "specialite"]

    private static let table: [String: [String]] = {
        var t: [String: [String]] = [:]
        for entry in rawTable {
            let key = compact(entry.label)
            if t[key] == nil { t[key] = entry.canonical }
        }
        return t
    }()

    /// Lowercase + fold diacritics.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
            .lowercased()
    }

    /// Folded alphanumeric tokens ("SC. ECONO.& SOCIALES" → ["sc", "econo", "sociales"]).
    static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Normalised label: folded tokens joined by a single space.
    static func normalize(_ s: String) -> String {
        tokens(s).joined(separator: " ")
    }

    /// Folded tokens concatenated with no separator — the lookup key.
    static func compact(_ s: String) -> String {
        tokens(s).joined()
    }

    /// Canonical curriculum subject names for a Pronote label, or `[]` when
    /// the label is not in the alias table.
    static func canonicalNames(for label: String) -> [String] {
        let all = tokens(label)
        if let hit = table[all.joined()] { return hit }
        let stripped = meaningfulTokens(label)
        if stripped.count != all.count, let hit = table[stripped.joined()] { return hit }
        return []
    }

    /// `tokens` without the LV1/LV2/SPE noise markers.
    static func meaningfulTokens(_ label: String) -> [String] {
        tokens(label).filter { !noiseTokens.contains($0) }
    }
}
