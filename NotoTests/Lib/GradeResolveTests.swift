import Testing
import Foundation
@testable import Noto

/// `GradeInference.resolve` (every Child-creation path) and
/// `CurriculumService.canonicalLevel` (read-side normalisation of grades
/// already persisted with a raw class label).
@Suite("Grade canonicalisation")
struct GradeResolveTests {

    // MARK: - resolve: collège / lycée

    @Test("Pronote lycée codes resolve to canonical grade + .lycee", arguments: [
        ("1G3", "1re"), ("TG2", "Tle"), ("1ère", "1re"), ("Première", "1re"),
        ("Terminale", "Tle"), ("Term", "Tle"), ("Term G2", "Tle"), ("2nde 4", "2nde"),
        ("Seconde", "2nde"), ("T STMG", "Tle"), ("TLE3", "Tle"), ("Term STMG", "Tle"),
    ])
    func lycee(label: String, expected: String) {
        let r = GradeInference.resolve(label)
        #expect(r?.grade == expected)
        #expect(r?.level == .lycee)
    }

    @Test("Collège labels, incl. École Directe spelled-out levels", arguments: [
        ("6e A", "6e"), ("3ème", "3e"), ("Troisième", "3e"), ("SIXIEME", "6e"),
        ("Cinquième", "5e"), ("Quatrième B", "4e"),
    ])
    func college(label: String, expected: String) {
        let r = GradeInference.resolve(label)
        #expect(r?.grade == expected)
        #expect(r?.level == .college)
    }

    // MARK: - resolve: primary keeps working

    @Test("Primary codes resolve to the same grade as the legacy parsers", arguments: [
        ("CP", "CP"), ("CE1-B", "CE1"), ("CM2A", "CM2"), ("CM1 - CM2 A - M. Lucas", "CM1"),
        ("CP - M. Tissot", "CP"),
    ])
    func elementaire(label: String, expected: String) {
        let r = GradeInference.resolve(label)
        #expect(r?.grade == expected)
        #expect(r?.level == .elementaire)
    }

    @Test("A trimester code on a primary label never reads as Terminale")
    func primaryWithTrimesterCode() {
        let r = GradeInference.resolve("CM2 T1")
        #expect(r?.grade == "CM2")
        #expect(r?.level == .elementaire)
    }

    @Test("Maternelle codes resolve to .maternelle", arguments: ["PS", "MS B", "GS"])
    func maternelle(label: String) {
        #expect(GradeInference.resolve(label)?.level == .maternelle)
    }

    @Test("Unrecognised labels resolve to nil (callers keep their legacy fallback)",
          arguments: ["", "?", "Groupe Bleu", "psychologie",
                      "ULIS - Mme Termeau", "Classe de Mme Tlemsani", "Groupe 1 G"])
    func unknown(label: String) {
        #expect(GradeInference.resolve(label)?.grade == nil)
    }

    // MARK: - canonicalLevel (read side)

    @Test("Raw persisted grades canonicalise to the curriculum level", arguments: [
        ("1ère", "1re"), ("Première", "1re"), ("Terminale", "Tle"), ("TG2", "Tle"),
        ("1G3", "1re"), ("3ème", "3e"), ("Tle", "Tle"), ("1re", "1re"), ("6e", "6e"),
    ])
    func canonicalLevel(raw: String, expected: String) {
        #expect(CurriculumService.canonicalLevel(raw) == expected)
    }

    @Test("Primary and unknown grades pass through", arguments: [
        ("CM1", "CM1"), ("cm1", "CM1"), ("PS", "PS"), ("", ""), ("?", "?"),
        ("ULIS - Mme Termeau", "ULIS - Mme Termeau"), ("Classe de Mme Tlemsani", "Classe de Mme Tlemsani"),
    ])
    func canonicalLevelPassThrough(raw: String, expected: String) {
        #expect(CurriculumService.canonicalLevel(raw) == expected)
    }

    @Test("program(for:) finds the programme from a raw persisted label")
    func programForRawLabel() {
        let service = CurriculumService(programs: [
            CurriculumProgram(level: "1re", cycle: 0, subjects: []),
            CurriculumProgram(level: "Tle", cycle: 0, subjects: []),
            CurriculumProgram(level: "CM1", cycle: 3, subjects: []),
        ])
        #expect(service.program(for: "1G3")?.level == "1re")
        #expect(service.program(for: "1ère")?.level == "1re")
        #expect(service.program(for: "Terminale")?.level == "Tle")
        #expect(service.program(for: "TG2")?.level == "Tle")
        #expect(service.program(for: "CM1")?.level == "CM1")
        #expect(service.program(for: "?") == nil)
    }

    @Test("ageRange and apiGrade accept raw labels")
    func ageRangeAndApiGrade() {
        let service = CurriculumService(programs: [])
        #expect(service.ageRange(for: "TG2").min == 17)
        #expect(service.ageRange(for: "1ère").min == 16)
        #expect(service.ageRange(for: "CM1").min == 9)
        #expect(service.apiGrade(for: "1G3") == "1ere")
        #expect(service.apiGrade(for: "Terminale") == "terminale")
        #expect(service.apiGrade(for: "3ème") == "3eme")
        #expect(service.apiGrade(for: "3e") == "3eme")
        #expect(service.apiGrade(for: "CM1") == "cm1")
    }
}
