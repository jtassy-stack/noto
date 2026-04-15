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

    // MARK: - Known substring gotchas (pinning current behavior)

    /// `inferLevel` does a naive `.contains("3e")`. A className like
    /// "subtle" contains "tle" as a substring, so it matches the lycée
    /// branch. Pinning current behavior so we notice when anyone
    /// tightens this to word boundaries.
    @Test("'subtle' trips the naive tle substring → lycee (pin)")
    func subtleGotcha() {
        #expect(GradeInference.level(from: "subtle") == .lycee)
    }

    /// Numbers like "16e" contain "6e" — naive substring match classifies
    /// this as college. Pinning current behavior; see backlog P4 for the
    /// word-boundary fix.
    @Test("'16e' trips the 6e substring → college (pin)")
    func sixteenthGotcha() {
        #expect(GradeInference.level(from: "16e") == .college)
    }
}
