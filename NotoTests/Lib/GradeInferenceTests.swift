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
}
