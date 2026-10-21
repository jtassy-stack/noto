import Testing
import Foundation
@testable import Noto

/// Subject order in Parcours / Réviser / the parent's week: in 1re and Tle
/// the child's own spécialités come first. Bundled curriculum, no network.
@Suite("SubjectProgress order")
struct SubjectPathOrderTests {
    private func subjects(_ level: String, _ specialties: [String]) -> [String] {
        SubjectProgress.path(level: level, specialties: specialties, masteries: [],
                             curriculum: CurriculumSnapshot.bundled).map(\.subject)
    }

    @Test func ownSpecialtiesComeFirstInCurriculumOrder() {
        let tle = subjects("Tle", ["SES", "Mathématiques"])
        #expect(Array(tle.prefix(2)) == ["Mathématiques", "SES"])
        #expect(tle.contains("Philosophie"))
        // Spécialités the child does not take stay out.
        #expect(!tle.contains("SVT") && !tle.contains("NSI"))
    }

    @Test func aSubjectInBothTracksIsListedOnceFirst() {
        // 1re lists « Mathématiques » in the tronc commun and as a spécialité.
        let first = subjects("1re", ["Mathématiques", "SVT"])
        #expect(Array(first.prefix(2)) == ["Mathématiques", "SVT"])
        #expect(first.filter { $0 == "Mathématiques" }.count == 1)
    }

    @Test func unknownSpecialtiesKeepTheCurriculumOrder() {
        #expect(subjects("Tle", []).first == "Philosophie")
        #expect(subjects("4e", ["SES"]) == subjects("4e", []))
    }
}
