import Testing
import Foundation
@testable import Noto

/// Discover: a level badge next to « Pour <enfant> » must always be the
/// child's own level (retour TestFlight build 14 : « Pas très cohérent entre
/// enfant et classe identifié » — « Français · CE2 » affiché « Pour Gaston »,
/// lycéen). Tag shapes mirror what culture-api actually returns (mixed case:
/// `CE2-francais`, `terminale-philosophie`). Pure logic, no network.
@Suite("RecoGradeMatcher")
struct RecoGradeMatcherTests {

    /// Every level a child can have, with the tag culture-api uses for it and
    /// the badge label expected.
    static let levels: [(grade: String, tag: String, label: String)] = [
        ("6e", "6eme-histoire", "Histoire · 6e"),
        ("5e", "5eme-histoire", "Histoire · 5e"),
        ("4e", "4eme-francais", "Francais · 4e"),
        ("3e", "3eme-histoire", "Histoire · 3e"),
        ("2nde", "2nde-histoire", "Histoire · 2nde"),
        ("1re", "1ere-arts", "Arts · 1re"),
        ("Tle", "terminale-philosophie", "Philosophie · Tle"),
        // Primaire stays in Discover (not in the revisions scope).
        ("CP", "CP-francais", "Francais · CP"),
        ("CE1", "CE1-francais", "Francais · CE1"),
        ("CE2", "CE2-francais", "Francais · CE2"),
        ("CM1", "CM1-histoire", "Histoire · CM1"),
        ("CM2", "CM2-histoire", "Histoire · CM2"),
    ]

    /// A multi-level result as returned for grade=terminale, with the
    /// out-of-level `CE2-francais` tag first.
    static let allLevelTags = ["CE2-francais"] + levels.map(\.tag) + ["GS-sciences"]

    // MARK: - Regression (the TestFlight screenshot)

    @Test("Tle child: CE2 tag first, badge is the terminale tag")
    func terminaleChildNeverGetsCE2() {
        let tags = ["CE2-francais", "terminale-philosophie", "4eme-histoire"]
        #expect(RecoGradeMatcher.badgeTags(tags, linkedLevel: "Tle") == ["terminale-philosophie"])
        #expect(RecoGradeMatcher.isForChildLevel(tags: tags, childGrade: "Tle"))
    }

    @Test("Result tagged only for other levels: no badge, not for the child")
    func outOfLevelResult() {
        let tags = ["CE2-francais", "terminale-arts"]
        for grade in ["6e", "5e", "4e", "3e", "2nde", "1re"] {
            #expect(RecoGradeMatcher.badgeTags(tags, linkedLevel: grade).isEmpty, "\(grade)")
            #expect(!RecoGradeMatcher.isForChildLevel(tags: tags, childGrade: grade), "\(grade)")
        }
    }

    // MARK: - Every level

    @Test("Each level picks its own tag out of a multi-level result",
          arguments: RecoGradeMatcherTests.levels.map(\.grade))
    func eachLevelMatchesItsTag(grade: String) throws {
        let expected = try #require(Self.levels.first { $0.grade == grade })
        let badge = RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: grade)
        #expect(badge == [expected.tag])
        #expect(RecoGradeMatcher.formatTag(expected.tag) == expected.label)
        #expect(RecoGradeMatcher.isForChildLevel(tags: Self.allLevelTags, childGrade: grade))
    }

    @Test("A level never matches another level's tag",
          arguments: RecoGradeMatcherTests.levels.map(\.grade))
    func noCrossLevelMatch(grade: String) {
        let others = Self.levels.filter { $0.grade != grade }.map(\.tag)
        #expect(RecoGradeMatcher.matchingTags(others, childGrade: grade).isEmpty)
        #expect(!RecoGradeMatcher.isForChildLevel(tags: others, childGrade: grade))
    }

    @Test("Revision levels 6e → Tle are all covered")
    func revisionScopeCovered() {
        for grade in CurriculumService.revisionLevels {
            #expect(!RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: grade).isEmpty, "\(grade)")
        }
    }

    @Test("Raw class labels resolve to the right tag")
    func rawLabels() {
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "Terminale") == ["terminale-philosophie"])
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "1G3") == ["1ere-arts"])
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "3ème") == ["3eme-histoire"])
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "Seconde") == ["2nde-histoire"])
    }

    @Test("Several tags of the child's level: first one, original order kept")
    func firstMatchingTag() {
        let tags = ["CE2-francais", "1ere-francais", "1ere-histoire"]
        #expect(RecoGradeMatcher.matchingTags(tags, childGrade: "1re") == ["1ere-francais", "1ere-histoire"])
        #expect(RecoGradeMatcher.badgeTags(tags, linkedLevel: "1re") == ["1ere-francais"])
    }

    // MARK: - Unknown / not judgeable

    @Test("No linked level or unknown grade: no badge, never a fallback tag")
    func unknownGrade() {
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: nil).isEmpty)
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "").isEmpty)
        #expect(RecoGradeMatcher.badgeTags(Self.allLevelTags, linkedLevel: "   ").isEmpty)
        #expect(RecoGradeMatcher.gradeCode(for: "") == nil)
        #expect(RecoGradeMatcher.gradeCode(for: nil) == nil)
        // Cannot judge → the (grade-filtered) result stays attributed.
        #expect(RecoGradeMatcher.isForChildLevel(tags: ["CE2-francais"], childGrade: ""))
    }

    @Test("Untagged results (events) stay attributed, without badge")
    func untagged() {
        #expect(RecoGradeMatcher.isForChildLevel(tags: [], childGrade: "Tle"))
        #expect(RecoGradeMatcher.badgeTags([], linkedLevel: "Tle").isEmpty)
        // Malformed tags carry no level.
        #expect(RecoGradeMatcher.isForChildLevel(tags: ["philosophie", "-x", "tle-"], childGrade: "Tle"))
    }

    @Test("Prefix is not a match: '1ere' child vs 'terminale' / '1erebis'")
    func exactLevelToken() {
        #expect(RecoGradeMatcher.matchingTags(["1erebis-francais"], childGrade: "1re").isEmpty)
        #expect(RecoGradeMatcher.matchingTags(["6eme-arts"], childGrade: "6e") == ["6eme-arts"])
        #expect(RecoGradeMatcher.matchingTags(["16eme-arts"], childGrade: "6e").isEmpty)
    }

    // MARK: - Formatting

    @Test("formatTag labels")
    func formatting() {
        #expect(RecoGradeMatcher.formatTag("terminale-histoire") == "Histoire · Tle")
        #expect(RecoGradeMatcher.formatTag("1ere-francais") == "Francais · 1re")
        #expect(RecoGradeMatcher.formatTag("2nde-svt") == "Svt · 2nde")
        #expect(RecoGradeMatcher.formatTag("GS-sciences") == "Sciences · GS")
        #expect(RecoGradeMatcher.formatTag("philosophie") == "philosophie")
    }

    @Test("Static apiGrade matches the instance method")
    func staticApiGrade() {
        let service = CurriculumService()
        for grade in CurriculumService.revisionLevels + ["CE2", "Terminale", "3ème", ""] {
            #expect(CurriculumService.apiGrade(for: grade) == service.apiGrade(for: grade))
        }
    }
}
