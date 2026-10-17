import Testing
import Foundation
@testable import Noto

/// Decoding of `PawnoteBridge.fetchLessonContents` output (3.8). Fixture
/// shaped like the bridge's JSON, made-up data. The JS function itself is
/// checked by hand, read-only, on one real account (raw shape unverified).
@Suite("Pronote lesson contents decoding")
struct PronoteLessonContentDecodeTests {
    @Test("full fixture decodes, entries and key names")
    func fullFixture() throws {
        let data = try FixtureLoader.data("pronote-lesson-contents.json")
        let payload = try JSONDecoder().decode(PronoteLessonContentsPayload.self, from: data)
        let entries = try #require(payload.entries)
        #expect(entries.count == 2)
        #expect(entries[0].subject == "HISTOIRE-GEOGRAPHIE")
        #expect(entries[0].startDate == "2023-11-06T08:00:00.000Z")
        let item = try #require(entries[0].contents?.first)
        #expect(item.id == "C-1")
        #expect(item.title == "Chapitre 2 : la Révolution française")
        #expect(item.themes == ["La Révolution française"])
        #expect(item.categoryLabel == "Cours")
        #expect(entries[1].endDate == nil)
        #expect(entries[1].contents?.first?.categoryLabel == nil)
        #expect(payload.rawEntryKeys?.contains("listeContenus") == true)
    }

    @Test("missing fields decode without throwing")
    func minimalFixture() throws {
        let json = #"{"entries":[{},{"subject":null,"contents":[{}]},{"id":"X","contents":null}]}"#
        let payload = try JSONDecoder().decode(PronoteLessonContentsPayload.self, from: Data(json.utf8))
        let entries = try #require(payload.entries)
        #expect(entries.count == 3)
        #expect(entries[0] == PronoteLessonContentEntry(id: nil, subject: nil, startDate: nil, endDate: nil,
                                                        contents: nil))
        #expect(entries[1].contents?.first?.title == nil)
        #expect(entries[1].contents?.first?.themes == nil)
        #expect(payload.rawKeys == nil)

        let empty = try JSONDecoder().decode(PronoteLessonContentsPayload.self, from: Data("{}".utf8))
        #expect(empty.entries == nil)
    }
}
