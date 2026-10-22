import Testing
import Foundation
@testable import Noto

/// Truth table for `GradeInference`. The Pronote `className` field is
/// free-form text entered by school admins, so this helper absorbs the
/// messiness (accents, capitalization, long/short forms) before it
/// reaches CurriculumService. If this drifts, the grade-filtered culture
/// recommendations silently target the wrong level.
@Suite("GradeInference")
struct GradeInferenceTests {

    // MARK: - Collège, short form

    @Test("6e short form → 6e / college")
    func sixthShort() {
        #expect(GradeInference.grade(from: "6e A") == "6e")
        #expect(GradeInference.level(from: "6e A") == .college)
    }

    @Test("5e / 4e / 3e short form")
    func middleShort() {
        #expect(GradeInference.grade(from: "5e B") == "5e")
        #expect(GradeInference.grade(from: "4e C") == "4e")
        #expect(GradeInference.grade(from: "3e D") == "3e")
    }

    // MARK: - Collège, long form with diacritics

    @Test("3ème with accent → 3e")
    func thirdAccented() {
        #expect(GradeInference.grade(from: "3ème") == "3e")
    }

    @Test("6ème long form → 6e (not mis-ordered as 6e prefix of 6eme)")
    func sixthLong() {
        #expect(GradeInference.grade(from: "6ème 2") == "6e")
    }

    @Test("Capital letters handled (3EME)")
    func uppercase() {
        #expect(GradeInference.grade(from: "3EME") == "3e")
    }

    // MARK: - Lycée

    @Test("2nde → 2nde / lycee")
    func seconde() {
        #expect(GradeInference.grade(from: "2nde 7") == "2nde")
        #expect(GradeInference.level(from: "2nde 7") == .lycee)
    }

    @Test("1ère with accent → 1re")
    func firstAccented() {
        #expect(GradeInference.grade(from: "1ère S") == "1re")
    }

    @Test("1re ascii short form → 1re")
    func firstAscii() {
        #expect(GradeInference.grade(from: "1re A") == "1re")
    }

    @Test("1ere long ascii → 1re (longest-first prevents 1re stealing it)")
    func firstLongAscii() {
        #expect(GradeInference.grade(from: "1ere B") == "1re")
    }

    @Test("Tle → Tle / lycee")
    func terminale() {
        #expect(GradeInference.grade(from: "Tle 3") == "Tle")
        #expect(GradeInference.level(from: "Tle 3") == .lycee)
    }

    // MARK: - Unrecognized

    @Test("Empty string → empty grade, college level default")
    func empty() {
        #expect(GradeInference.grade(from: "") == "")
        #expect(GradeInference.level(from: "") == .college)
    }

    @Test("CM1 (primaire, not handled) → empty grade, college default")
    func primaire() {
        #expect(GradeInference.grade(from: "CM1") == "")
        #expect(GradeInference.level(from: "CM1") == .college)
    }

    // MARK: - Word boundary behavior (P4 fix)

    @Test("'subtle' no longer trips the tle substring → college default")
    func subtleFixed() {
        #expect(GradeInference.level(from: "subtle") == .college)
    }

    @Test("'16e' no longer trips the 6e substring → college default")
    func sixteenthFixed() {
        #expect(GradeInference.level(from: "16e") == .college)
    }

    @Test("'3e' at start of string still matches → college")
    func startOfString() {
        #expect(GradeInference.level(from: "3e") == .college)
    }

    @Test("'3e' after space matches → college")
    func afterSpace() {
        #expect(GradeInference.level(from: "Groupe 3e A") == .college)
    }

    @Test("'3e' after dash matches → college")
    func afterDash() {
        #expect(GradeInference.level(from: "G-3e") == .college)
    }

    @Test("'tle' at word boundary → lycee")
    func tleWordBoundary() {
        #expect(GradeInference.level(from: "Tle S") == .lycee)
    }

    @Test("'13e' does not match 3e → college default (digit prefix blocks)")
    func thirteenthNoMatch() {
        #expect(GradeInference.level(from: "13e") == .college)
    }

    // MARK: - Lycée labels from Pronote / ENT (Phase 2)

    @Test("Seconde labels → 2nde / lycee", arguments: ["SECONDE", "2NDE", "2DE", "2GT", "2nde 4", "2DE3", "Seconde générale"])
    func secondeLabels(label: String) {
        #expect(GradeInference.grade(from: label) == "2nde")
        #expect(GradeInference.level(from: label) == .lycee)
    }

    @Test("Première labels → 1re / lycee", arguments: ["PREMIERE", "1ERE", "1RE", "1G", "1G3", "1 G 2", "1STMG", "1 STMG", "1 STI2D 2", "1-G3", "Première générale", "1ère G4"])
    func premiereLabels(label: String) {
        #expect(GradeInference.grade(from: label) == "1re")
        #expect(GradeInference.level(from: label) == .lycee)
    }

    @Test("Terminale labels → Tle / lycee", arguments: ["TERMINALE", "TLE", "TG", "TG2", "T G 3", "TSTMG", "T STMG", "T-STI2D", "T G3", "T1", "Terminale générale", "Tle G1"])
    func terminaleLabels(label: String) {
        #expect(GradeInference.grade(from: label) == "Tle")
        #expect(GradeInference.level(from: label) == .lycee)
    }

    @Test("Words merely containing lycée codes do not match", arguments: [
        "Atelier Tango", "montgolfière", "Groupe 1", "T", "STG", "TGV", "subtle", "Outgoing", "test", "1st", "CM2",
    ])
    func lyceeNegatives(label: String) {
        #expect(GradeInference.grade(from: label) == "")
        #expect(GradeInference.level(from: label) == .college)
    }

    @Test("Spaced collège label still reads as collège")
    func spacedCollege() {
        #expect(GradeInference.grade(from: "6eA") == "6e")
        #expect(GradeInference.grade(from: "4 E") == "4e")
    }

    @Test("Collège label with a trailing group/trimester code stays collège", arguments: [
        ("3E T1", "3e"), ("5e - T2", "5e"), ("4E GR T1", "4e"), ("6E A T 2", "6e"),
    ])
    func collegeWithTrailingCode(label: String, expected: String) {
        #expect(GradeInference.grade(from: label) == expected)
        #expect(GradeInference.level(from: label) == .college)
    }

    @Test("16e / 13e no longer yield a grade (prefix boundary on grade too)")
    func digitPrefixGrade() {
        #expect(GradeInference.grade(from: "16e") == "")
        #expect(GradeInference.grade(from: "13e") == "")
    }

    // MARK: - Numeric and "2e" class codes

    @Test("Seconde class codes → 2nde / lycee", arguments: ["201", "212", "2E3", "2E", "2ème 4", "2EME", "2A", "Classe 204"])
    func secondeCodes(label: String) {
        #expect(GradeInference.grade(from: label) == "2nde")
        #expect(GradeInference.level(from: label) == .lycee)
    }

    @Test("Three-digit codes read the level digit", arguments: [
        ("604", "6e"), ("502", "5e"), ("401", "4e"), ("301", "3e"), ("103", "1re"),
    ])
    func numericCodes(label: String, expected: String) {
        #expect(GradeInference.grade(from: label) == expected)
    }

    @Test("Numbers that are not class codes stay unrecognised", arguments: [
        "2026", "20", "Groupe 2 A", "Salle 2", "701", "2eleves",
    ])
    func numericNegatives(label: String) {
        #expect(GradeInference.grade(from: label) == "")
    }

    @Test("Sync refresh fills an empty grade, never erases one")
    func refreshedGrade() {
        let filled = GradeInference.refreshedGrade(current: "", className: "201")
        #expect(filled?.grade == "2nde")
        #expect(filled?.level == .lycee)
        #expect(GradeInference.refreshedGrade(current: "2nde", className: "201") == nil)
        #expect(GradeInference.refreshedGrade(current: "2nde", className: "Atelier") == nil)
        #expect(GradeInference.refreshedGrade(current: "2nde", className: "1G3")?.grade == "1re")
        // MonLycée children are created with no class label (grade "" or
        // "?"); the Pronote roster then gives "2NDE2" / "6EME2".
        #expect(GradeInference.refreshedGrade(current: "?", className: "2NDE2")?.grade == "2nde")
        #expect(GradeInference.refreshedGrade(current: "", className: "6EME2")?.grade == "6e")
    }

    @Test("A class picked by hand maps to its level, only 6e → Tle")
    func manualChoice() {
        #expect(GradeInference.manualChoice("2nde")?.level == .lycee)
        #expect(GradeInference.manualChoice("Tle")?.level == .lycee)
        #expect(GradeInference.manualChoice("6e")?.level == .college)
        #expect(GradeInference.manualChoice("6e")?.grade == "6e")
        #expect(GradeInference.manualChoice("CM2") == nil)
        #expect(GradeInference.manualChoice("") == nil)
    }
}
