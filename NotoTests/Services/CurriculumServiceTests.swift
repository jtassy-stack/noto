import Testing
import Foundation
@testable import Noto

/// CurriculumService: JSON decoding (old + track/specialty shape), spécialité
/// filtering, Pronote subject-label aliases, keyword matching, and the
/// coverage contract of the bundled `curriculum.json` (Phase 2).
@Suite("CurriculumService")
struct CurriculumServiceTests {

    // MARK: - Fixtures

    /// Pre-Phase-2 shape: no `track` / `specialty` keys.
    private static let oldShapeJSON = """
    {
      "version": "2025-2026",
      "lastUpdated": "2025-09-01",
      "programs": [
        {
          "level": "3e",
          "cycle": 4,
          "subjects": [
            {
              "name": "Histoire",
              "themes": [
                { "theme": "La Seconde Guerre mondiale", "keywords": ["guerre", "résistance", "shoah", "onu"], "period": "Trimestre 2" }
              ]
            },
            {
              "name": "Géographie",
              "themes": [
                { "theme": "Les espaces productifs", "keywords": ["industrie", "agriculture", "métropole", "pib"], "period": null }
              ]
            },
            {
              "name": "SVT",
              "themes": [
                { "theme": "Génétique", "keywords": ["adn", "chromosome", "gène", "allèle"], "period": "Trimestre 1" }
              ]
            }
          ]
        }
      ]
    }
    """

    /// Phase-2 shape with tronc commun + spécialités.
    private static let newShapeJSON = """
    {
      "version": "2026-2027",
      "lastUpdated": "2026-10-01",
      "programs": [
        {
          "level": "1re",
          "cycle": 0,
          "subjects": [
            {
              "name": "Histoire", "track": "tronc_commun", "specialty": null,
              "themes": [ { "theme": "La Révolution française", "keywords": ["révolution", "1789", "monarchie"], "period": "Trimestre 1" } ]
            },
            {
              "name": "Géographie", "track": "tronc_commun", "specialty": null,
              "themes": [ { "theme": "La métropolisation", "keywords": ["métropole", "urbain", "périurbanisation"], "period": "Trimestre 1" } ]
            },
            {
              "name": "Enseignement scientifique", "track": "tronc_commun", "specialty": null,
              "themes": [ { "theme": "Le Soleil, notre source d'énergie", "keywords": ["soleil", "rayonnement", "photosynthèse"], "period": "Trimestre 2" } ]
            },
            {
              "name": "HGGSP", "track": "specialite", "specialty": "HGGSP",
              "themes": [ { "theme": "Comprendre un régime politique : la démocratie", "keywords": ["démocratie", "athènes", "citoyenneté"], "period": "Trimestre 1" } ]
            },
            {
              "name": "Mathématiques", "track": "specialite", "specialty": "Mathématiques",
              "themes": [ { "theme": "Suites numériques", "keywords": ["suite", "récurrence", "arithmétique"], "period": "Trimestre 1" } ]
            },
            {
              "name": "NSI", "track": "specialite", "specialty": "NSI",
              "themes": [ { "theme": "Représentation des données", "keywords": ["binaire", "booléen", "algorithme"], "period": "Trimestre 1" } ]
            },
            {
              "name": "SI", "track": "specialite", "specialty": "SI",
              "themes": [ { "theme": "Modéliser un système", "keywords": ["système", "capteur", "cahier des charges"], "period": "Trimestre 1" } ]
            },
            {
              "name": "Physique-Chimie", "track": "specialite", "specialty": "Physique-Chimie",
              "themes": [ { "theme": "Mouvement et interactions", "keywords": ["force", "vitesse", "gravitation"], "period": "Trimestre 2" } ]
            }
          ]
        }
      ]
    }
    """

    private static func service(_ json: String) throws -> CurriculumService {
        let service = CurriculumService()
        try service.load(from: Data(json.utf8))
        return service
    }

    // MARK: - Decoding

    @Test("Old JSON shape (no track) decodes as tronc commun")
    func decodeOldShape() throws {
        let programs = try CurriculumService.decodePrograms(from: Data(Self.oldShapeJSON.utf8))
        #expect(programs.count == 1)
        let subjects = try #require(programs.first?.subjects)
        #expect(subjects.map(\.name) == ["Histoire", "Géographie", "SVT"])
        #expect(subjects.allSatisfy { $0.track == .troncCommun && $0.specialty == nil })
        #expect(subjects[1].themes.first?.period == nil)
    }

    @Test("New JSON shape decodes track + specialty")
    func decodeNewShape() throws {
        let programs = try CurriculumService.decodePrograms(from: Data(Self.newShapeJSON.utf8))
        let subjects = try #require(programs.first?.subjects)
        let hggsp = try #require(subjects.first { $0.name == "HGGSP" })
        #expect(hggsp.track == .specialite)
        #expect(hggsp.specialty == "HGGSP")
        let histoire = try #require(subjects.first { $0.name == "Histoire" })
        #expect(histoire.track == .troncCommun)
        #expect(histoire.specialty == nil)
    }

    @Test("Unknown track value decodes as tronc commun instead of failing the whole file")
    func decodeUnknownTrack() throws {
        let json = """
        {
          "version": "2027-2028",
          "programs": [
            {
              "level": "2nde",
              "cycle": 0,
              "subjects": [
                { "name": "Latin", "track": "option", "themes": [ { "theme": "Rome", "keywords": ["rome"], "period": null } ] },
                { "name": "Histoire", "themes": [ { "theme": "Antiquité", "keywords": ["athènes"], "period": null } ] }
              ]
            }
          ]
        }
        """
        let programs = try CurriculumService.decodePrograms(from: Data(json.utf8))
        let subjects = try #require(programs.first?.subjects)
        #expect(subjects.map(\.name) == ["Latin", "Histoire"])
        #expect(subjects.allSatisfy { $0.track == .troncCommun })
    }

    @Test("init(programs:) exposes the given programs")
    func initWithPrograms() throws {
        let programs = try CurriculumService.decodePrograms(from: Data(Self.oldShapeJSON.utf8))
        let service = CurriculumService(programs: programs)
        #expect(service.levels == ["3e"])
        #expect(service.subjects(for: "3e") == ["Histoire", "Géographie", "SVT"])
    }

    // MARK: - Spécialités filter

    @Test("Unknown specialties (nil/empty) keep every spécialité eligible")
    func specialtiesUnknown() throws {
        let service = try Self.service(Self.newShapeJSON)
        #expect(!service.themes(for: "1re", subject: "HGGSP").isEmpty)
        #expect(!service.themes(for: "1re", subject: "HGGSP", specialties: []).isEmpty)
        #expect(!service.themes(for: "1re", subject: "NSI", specialties: nil).isEmpty)
    }

    @Test("Known specialties filter spécialités, never tronc commun")
    func specialtiesKnown() throws {
        let service = try Self.service(Self.newShapeJSON)
        let picks = ["mathematiques", "NSI", "hggsp"]
        #expect(!service.themes(for: "1re", subject: "MATHEMATIQUES", specialties: picks).isEmpty)
        #expect(!service.themes(for: "1re", subject: "NUMERIQUE SC.INFORM.", specialties: picks).isEmpty)
        #expect(!service.themes(for: "1re", subject: "HIST.GEO.GEOPOL.&SC.POL.", specialties: picks).isEmpty)
        #expect(service.themes(for: "1re", subject: "PHYSIQUE-CHIMIE", specialties: picks).isEmpty)
        #expect(service.themes(for: "1re", subject: "SC. INGENIEUR", specialties: picks).isEmpty)
        // Tronc commun stays eligible whatever the spécialités.
        #expect(!service.themes(for: "1re", subject: "ENSEIGN.SCIENTIFIQUE", specialties: picks).isEmpty)
        #expect(!service.themes(for: "1re", subject: "HISTOIRE-GEOGRAPHIE", specialties: picks).isEmpty)
    }

    @Test("Specialty filter accepts Pronote-style labels for the child's spécialités")
    func specialtiesAliasLabels() throws {
        let service = try Self.service(Self.newShapeJSON)
        #expect(!service.themes(for: "1re", subject: "MATHS", specialties: ["Maths"]).isEmpty)
        #expect(!service.themes(for: "1re", subject: "PHYSIQUE-CHIMIE", specialties: ["SC.PHYSIQUES"]).isEmpty)
    }

    @Test("matchKeywords honours the specialties filter")
    func matchKeywordsSpecialties() throws {
        let service = try Self.service(Self.newShapeJSON)
        let text = "Exercices sur les suites et la récurrence"
        #expect(!service.matchKeywords(text: text, level: "1re", subject: "MATHEMATIQUES").isEmpty)
        #expect(!service.matchKeywords(text: text, level: "1re", subject: "MATHEMATIQUES", specialties: ["Mathématiques"]).isEmpty)
        #expect(service.matchKeywords(text: text, level: "1re", subject: "MATHEMATIQUES", specialties: ["SES", "HLP"]).isEmpty)
    }

    // MARK: - Subject resolution

    @Test("HISTOIRE-GEOGRAPHIE returns the union of Histoire + Géographie themes")
    func histoireGeographieUnion() throws {
        let service = try Self.service(Self.oldShapeJSON)
        for label in ["HISTOIRE-GEOGRAPHIE", "HIST.GEO.", "Histoire-Géographie", "histoire géographie"] {
            let themes = service.themes(for: "3e", subject: label).map(\.theme)
            #expect(Set(themes) == ["La Seconde Guerre mondiale", "Les espaces productifs"], "label: \(label)")
        }
    }

    @Test("Canonical names still resolve to themselves")
    func canonicalSelf() throws {
        let service = try Self.service(Self.oldShapeJSON)
        #expect(service.themes(for: "3e", subject: "Histoire").map(\.theme) == ["La Seconde Guerre mondiale"])
        #expect(service.themes(for: "3e", subject: "SVT").count == 1)
        #expect(service.themes(for: "3e", subject: "S.V.T.").count == 1)
        #expect(service.themes(for: "3e", subject: "SCIENCES VIE & TERRE").count == 1)
    }

    /// 6e has "Sciences et technologie" but no "Technologie" subject.
    private static let sixthJSON = """
    {
      "programs": [
        {
          "level": "6e",
          "cycle": 3,
          "subjects": [
            {
              "name": "Sciences et technologie",
              "themes": [ { "theme": "Matière et énergie", "keywords": ["énergie", "circuit", "signal", "mouvement", "électricité"], "period": null } ]
            }
          ]
        }
      ]
    }
    """

    @Test("Alias whose canonical subject is absent at the level falls back to label matching")
    func aliasFallsThroughWhenAbsent() throws {
        let service = try Self.service(Self.sixthJSON)
        #expect(service.themes(for: "6e", subject: "TECHNOLOGIE").map(\.theme) == ["Matière et énergie"])
        #expect(service.cultureTopics(for: "6e", subject: "TECHNOLOGIE") == ["Matière et énergie"])
    }

    @Test("Spécialité filtered out by the alias stays filtered out (no fall-through)")
    func aliasFilteredNoFallThrough() throws {
        let service = try Self.service(Self.newShapeJSON)
        #expect(service.matchingSubjects(for: "1re", subject: "SC. INGENIEUR", specialties: ["NSI"]).isEmpty)
    }

    @Test("Short subject names match as whole tokens inside a longer label")
    func shortNameWholeToken() throws {
        let service = try Self.service(Self.oldShapeJSON)
        #expect(service.matchingSubjects(for: "3e", subject: "SVT 1").map(\.name) == ["SVT"])
        #expect(service.matchingSubjects(for: "3e", subject: "SVT (groupe A)").map(\.name) == ["SVT"])
        #expect(service.matchingSubjects(for: "3e", subject: "SVTX").isEmpty)
    }

    @Test("Short subject names never substring-match (SI ⊄ PHYSIQUE)")
    func shortNamesNoSubstring() throws {
        let service = try Self.service(Self.newShapeJSON)
        let names = service.matchingSubjects(for: "1re", subject: "PHYSIQUE-CHIMIE").map(\.name)
        #expect(names == ["Physique-Chimie"])
        #expect(service.matchingSubjects(for: "1re", subject: "PHYSIQUE").map(\.name) == ["Physique-Chimie"])
        #expect(service.themes(for: "1re", subject: "Inconnue").isEmpty)
        #expect(service.themes(for: "Tle", subject: "Histoire").isEmpty) // level not loaded
    }

    @Test("Pronote alias table maps common labels to canonical names", arguments: [
        ("HISTOIRE-GEOGRAPHIE", ["Histoire", "Géographie"]),
        ("HIST.GEO.", ["Histoire", "Géographie"]),
        ("SCIENCES VIE & TERRE", ["SVT"]),
        ("S.V.T.", ["SVT"]),
        ("PHYSIQUE-CHIMIE", ["Physique-Chimie"]),
        ("SC.PHYSIQUES", ["Physique-Chimie"]),
        ("SC. ECONO.& SOCIALES", ["SES"]),
        ("ANGLAIS LV1", ["Anglais"]),
        ("LV1 ANGLAIS", ["Anglais"]),
        ("ESPAGNOL LV2", ["Espagnol"]),
        ("ENSEIGN.SCIENTIFIQUE", ["Enseignement scientifique"]),
        ("HIST.GEO.GEOPOL.&SC.POL.", ["HGGSP"]),
        ("HUMAN.LITTER.PHILO.", ["HLP"]),
        ("NUMERIQUE SC.INFORM.", ["NSI"]),
        ("SC. INGENIEUR", ["SI"]),
        ("LLC ANGL.MOND.CONT.", ["LLCER Anglais"]),
        ("ENS. MORAL & CIVIQUE", ["EMC"]),
        ("FRANCAIS", ["Français"]),
        ("Français", ["Français"]),
        ("MATHEMATIQUES", ["Mathématiques"]),
        ("MATHS", ["Mathématiques"]),
        ("PHILOSOPHIE", ["Philosophie"]),
        ("SC. NUMERIQ.TECHNOL.", ["SNT"]),
        ("TECHNOLOGIE", ["Technologie"]),
        ("EDUCATION MUSICALE", ["Éducation musicale"]),
        ("ARTS PLASTIQUES", ["Arts plastiques"]),
        ("ED.PHYSIQUE & SPORT.", ["EPS"]),
    ])
    func aliasTable(label: String, expected: [String]) {
        #expect(SubjectAlias.canonicalNames(for: label) == expected)
    }

    @Test("Unknown labels are not aliased")
    func aliasUnknown() {
        #expect(SubjectAlias.canonicalNames(for: "ATELIER THEATRE").isEmpty)
        #expect(SubjectAlias.canonicalNames(for: "").isEmpty)
    }

    @Test("Label normalisation folds case, accents and punctuation")
    func normalisation() {
        #expect(SubjectAlias.normalize("SC. ECONO.& SOCIALES") == "sc econo sociales")
        #expect(SubjectAlias.normalize("  Éducation   Musicale ") == "education musicale")
        #expect(SubjectAlias.compact("Hist.-Géo.") == "histgeo")
    }

    // MARK: - Keyword matching

    @Test("Short keywords match on whole words only")
    func shortKeywordWholeWord() throws {
        let service = try Self.service(Self.oldShapeJSON)
        #expect(!service.matchKeywords(text: "Contrôle ADN mardi", level: "3e", subject: "SVT").isEmpty)
        #expect(!service.matchKeywords(text: "Revoir l'ADN et la mitose", level: "3e", subject: "SVT").isEmpty)
        #expect(service.matchKeywords(text: "Lire la nouvelle de Radnor", level: "3e", subject: "SVT").isEmpty)
        #expect(service.matchKeywords(text: "Exposé sur le monument aux morts, bonus", level: "3e", subject: "Histoire").isEmpty)
        #expect(!service.matchKeywords(text: "Le rôle de l'ONU", level: "3e", subject: "Histoire").isEmpty)
        #expect(service.matchKeywords(text: "Pêche à la pibale", level: "3e", subject: "Géographie").isEmpty)
        #expect(!service.matchKeywords(text: "Calcul du PIB.", level: "3e", subject: "Géographie").isEmpty)
    }

    @Test("Long keywords keep substring matching")
    func longKeywordSubstring() throws {
        let service = try Self.service(Self.oldShapeJSON)
        // "chromosome" inside "chromosomes", accents folded on "gène".
        #expect(!service.matchKeywords(text: "Les chromosomes", level: "3e", subject: "SVT").isEmpty)
        #expect(!service.matchKeywords(text: "Les industries françaises", level: "3e", subject: "Géographie").isEmpty)
    }

    @Test("textMatches boundary helper")
    func textMatchesHelper() {
        #expect(CurriculumService.textMatches("controle adn", keyword: "adn"))
        #expect(CurriculumService.textMatches("adn", keyword: "adn"))
        #expect(!CurriculumService.textMatches("radnor", keyword: "adn"))
        #expect(!CurriculumService.textMatches("adnane", keyword: "adn"))
        #expect(CurriculumService.textMatches("radn adn", keyword: "adn"))
        #expect(!CurriculumService.textMatches("anything", keyword: ""))
    }

    // MARK: - Existing public behaviour

    @Test("apiGrade / ageRange unchanged")
    func apiGradeAgeRange() {
        let service = CurriculumService()
        #expect(service.apiGrade(for: "3e") == "3eme")
        #expect(service.apiGrade(for: "2nde") == "2nde")
        #expect(service.apiGrade(for: "1re") == "1ere")
        #expect(service.apiGrade(for: "Tle") == "terminale")
        #expect(service.apiGrade(for: "CM1") == "cm1")
        #expect(service.ageRange(for: "Tle").min == 17)
        #expect(service.ageRange(for: "Tle").max == 18)
        #expect(service.ageRange(for: "1re").min == 16)
    }

    @Test("revisionLevels is collège + lycée only")
    func revisionLevels() {
        #expect(CurriculumService.revisionLevels == ["6e", "5e", "4e", "3e", "2nde", "1re", "Tle"])
    }

    // MARK: - Bundled data contract

    @Test("Bundled curriculum.json covers every revision level (6e → Tle)")
    func bundledCoverage() {
        let service = CurriculumService()
        service.loadBundled()
        var failures: [String] = []

        for level in CurriculumService.revisionLevels {
            guard let program = service.program(for: level) else {
                failures.append("\(level): missing program")
                continue
            }
            let tronc = program.subjects.filter { $0.track == .troncCommun }
            if tronc.count < 6 {
                failures.append("\(level): \(tronc.count) tronc_commun subjects (< 6)")
            }
            for subject in program.subjects {
                let label = "\(level) / \(subject.name)\(subject.track == .specialite ? " [spé]" : "")"
                if subject.themes.count < 3 {
                    failures.append("\(label): \(subject.themes.count) themes (< 3)")
                }
                for theme in subject.themes where !(5...10).contains(theme.keywords.count) {
                    failures.append("\(label) / \(theme.theme): \(theme.keywords.count) keywords (expected 5–10)")
                }
            }
        }

        #expect(failures.isEmpty, "Curriculum coverage failures:\n\(failures.joined(separator: "\n"))")
    }

    @Test("Real homework labels match a curriculum theme (fixtures)")
    func homeworkFixtures() {
        let service = CurriculumService()
        service.loadBundled()
        var failures: [String] = []

        for fixture in CurriculumHomeworkFixtures.labels {
            let keywords = service.matchKeywords(text: fixture.text, level: fixture.level, subject: fixture.subject)
            if keywords.isEmpty {
                failures.append("[\(fixture.level)] \(fixture.subject): \"\(fixture.text)\"")
            }
        }

        #expect(
            failures.isEmpty,
            "\(failures.count)/\(CurriculumHomeworkFixtures.labels.count) homework fixtures unmatched:\n\(failures.joined(separator: "\n"))"
        )
    }
}
