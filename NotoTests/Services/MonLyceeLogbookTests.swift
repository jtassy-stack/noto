import Testing
import Foundation
@testable import Noto

/// The MonLycée logbook (homework, grades, class) feeds a MonLycée child
/// whenever no Pronote session lists it, as in the TestFlight builds.
@Suite("MonLycée logbook")
struct MonLyceeLogbookTests {

    private let logbook: [String: Any] = [
        "structures": [[
            "individuals": [
                ["id": "parent-1", "firstName": "Julien", "lastName": "PARENT"],
                [
                    "id": "child-g", "firstName": "Gaston", "lastName": "TEST",
                    "work": ["notebook": [[
                        "subject": "MATHEMATIQUES",
                        "workToDo": [
                            ["description": "<p>Exercice 3 &amp; 4 p.12</p>", "dateForThe": "2026-10-27"],
                            ["description": "Réviser l&#039;interro", "dateForThe": ""],
                        ],
                    ]]],
                    "notation": ["grades": [
                        ["subject": "ANGLAIS", "grade": "14,5", "scale": "20", "date": "2026-10-20"],
                        ["subject": "SVT", "grade": "Abs", "scale": "20", "date": "2026-10-21"],
                        ["subject": "PHYSIQUE", "grade": "8", "scale": "10", "date": "2026-10-22T08:00:00"],
                    ]],
                ],
                ["id": "child-j", "firstName": "Joseph", "lastName": "TEST", "work": [:]],
            ],
        ]],
    ]

    @Test("a child is found by id first, then by first name")
    func findsIndividual() {
        #expect(MonLyceeSyncService.individual(in: logbook, entChildId: "child-g", firstName: "X")?["firstName"] as? String == "Gaston")
        #expect(MonLyceeSyncService.individual(in: logbook, entChildId: "unknown", firstName: "Joseph")?["id"] as? String == "child-j")
        #expect(MonLyceeSyncService.individual(in: logbook, entChildId: nil, firstName: "Nobody") == nil)
        #expect(MonLyceeSyncService.individual(in: [:], entChildId: "child-g", firstName: "Gaston") == nil)
    }

    @Test("homework: HTML stripped, due date parsed, missing date kept as nil")
    func homework() throws {
        let gaston = try #require(MonLyceeSyncService.individual(in: logbook, entChildId: "child-g", firstName: "Gaston"))
        let items = MonLyceeSyncService.homeworkItems(in: gaston)
        #expect(items.count == 2)
        #expect(items[0].subject == "MATHEMATIQUES")
        #expect(items[0].description == "Exercice 3 & 4 p.12")
        #expect(items[0].dueDate != nil)
        #expect(items[1].description == "Réviser l'interro")
        #expect(items[1].dueDate == nil)
    }

    @Test("grades: decimal comma, scale, unreadable values dropped")
    func grades() throws {
        let gaston = try #require(MonLyceeSyncService.individual(in: logbook, entChildId: "child-g", firstName: "Gaston"))
        let items = MonLyceeSyncService.gradeItems(in: gaston)
        #expect(items.count == 2)
        #expect(items[0] == .init(subject: "ANGLAIS", value: 14.5, outOf: 20, date: MonLyceeSyncService.parseDay("2026-10-20")))
        #expect(items[1].outOf == 10)
        #expect(items[1].date != nil)
    }

    @Test("store round-trips through the protected file and clears")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noto-logbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MonLyceeLogbookStore.load(in: dir) == nil)
        try MonLyceeLogbookStore.save(logbook, in: dir)
        let loaded = try #require(MonLyceeLogbookStore.load(in: dir))
        #expect(MonLyceeSyncService.individual(in: loaded, entChildId: "child-j", firstName: "") != nil)
        #expect(MonLyceeLogbookStore.fileURL(in: dir).deletingLastPathComponent() == MonLyceeNewsStore.fileURL(in: dir).deletingLastPathComponent())
        MonLyceeLogbookStore.clear(in: dir)
        #expect(MonLyceeLogbookStore.load(in: dir) == nil)
    }

    @Test("cookies copied for loginENT: Pronote host, ENT and CAS only")
    func cookieDomains() {
        let host = "0000000a.index-education.net"
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: host, pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: ".index-education.net", pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: "auth.monlycee.net", pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: ".monlycee.net", pronoteHost: nil))
        #expect(!PawnoteBridge.shouldTransfer(cookieDomain: ".google.com", pronoteHost: host))
        #expect(!PawnoteBridge.shouldTransfer(cookieDomain: "", pronoteHost: host))
    }
}
