import Testing
import Foundation
@testable import Noto

/// The MonLycée news payload is parsed into announcements and kept in a
/// protected file, never in UserDefaults.
@Suite("MonLycée news")
struct MonLyceeNewsTests {

    @Test("news entries parse, untitled ones are dropped")
    func parses() {
        let items = MonLyceeSyncService.newsItems(from: [
            ["title": " Réunion parents ", "author": "Direction", "date": "2026-10-20T08:30:00.000Z", "link": "https://ent/x"],
            ["title": "Sans date", "author": "CPE", "date": "", "link": ""],
            ["title": "", "author": "vide"],
            ["title": "Date simple", "date": "2026-10-21T07:00:00Z"],
        ])
        #expect(items.count == 3)
        #expect(items[0].title == "Réunion parents")
        #expect(items[0].author == "Direction")
        #expect(items[0].link == "https://ent/x")
        #expect(items[0].date != nil)
        #expect(items[1].date == nil)
        #expect(items[1].link == nil)
        #expect(items[2].date != nil)
    }

    @Test("store round-trips through the protected file and clears")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noto-news-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MonLyceeNewsStore.load(in: dir).isEmpty)
        try MonLyceeNewsStore.save([["title": "A", "author": "B"]], in: dir)
        let loaded = MonLyceeNewsStore.load(in: dir)
        #expect(loaded.count == 1)
        #expect(loaded.first?["title"] as? String == "A")
        #expect(MonLyceeNewsStore.fileURL(in: dir).lastPathComponent == MonLyceeNewsStore.fileName)

        MonLyceeNewsStore.clear(in: dir)
        #expect(MonLyceeNewsStore.load(in: dir).isEmpty)
    }

    @Test("legacy UserDefaults keys are purged")
    func purgesLegacy() {
        let suite = "MonLyceeNewsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in MonLyceeNewsStore.legacyDefaultsKeys { defaults.set("x", forKey: key) }
        MonLyceeNewsStore.purgeLegacyDefaults(defaults)
        for key in MonLyceeNewsStore.legacyDefaultsKeys { #expect(defaults.string(forKey: key) == nil) }
    }
}
