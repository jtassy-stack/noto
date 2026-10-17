import Testing
import Foundation
@testable import Noto

/// Pure logic of the culture G quiz: audience filter, child-safe text,
/// out-of-date questions, draw, copy. No network.
@MainActor
@Suite("Culture G quiz — filter and draw")
struct CultureQuizFilterTests {

    private let calendar = QuizClock.calendar

    private func quiz(_ n: Int, domain: String = "livres", difficulty: Int = 1, kind: String = "catalogue",
                      question: String? = nil, tone: String? = "histoire", validUntil: String? = nil,
                      explanation: String? = nil) -> CultureLotQuizDto {
        CultureLotQuizDto(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!,
                          domain: domain, difficulty: difficulty, kind: kind,
                          question: question ?? "Question \(n) ?", choices: ["A", "B", "C", "D"],
                          answerIndex: 1, explanation: explanation, tone: tone, validUntil: validUntil)
    }

    private func entry(_ quiz: CultureLotQuizDto, app: String = "keskonfe",
                       lotDate: String = "2026-10-15") -> CultureQuizEntry {
        CultureQuizEntry(quiz: quiz, app: app, lotDate: lotDate)
    }

    // MARK: Audience

    @Test("the parent gets every domain, tone and difficulty")
    func parentGetsEverything() {
        for q in [quiz(1, domain: "politique"), quiz(2, tone: "actu"), quiz(3, difficulty: 3),
                  quiz(4, question: "Quel tueur en série inspire ce film ?")] {
            #expect(CultureQuizFilter.isAppropriate(q, for: .parent))
        }
    }

    @Test("child: culture, sport and sciences domains only", arguments: [
        ("films", true), ("jeux", true), ("sport", true), ("sciences_tech", true), ("environnement", true),
        ("culture", true), ("politique", false), ("international", false), ("societe", false),
        ("economie", false), ("sante", false), ("inconnu", false),
    ])
    func childDomains(domain: String, allowed: Bool) {
        #expect(CultureQuizFilter.isAppropriate(quiz(1, domain: domain), for: .child(level: "5e")) == allowed)
    }

    @Test("child: no news question (tone or kind actu), evergreen and fun ones kept")
    func childEvergreenOnly() {
        let child = CultureQuizAudience.child(level: "4e")
        #expect(!CultureQuizFilter.isAppropriate(quiz(1, tone: "actu"), for: child))
        #expect(!CultureQuizFilter.isAppropriate(quiz(2, kind: "actu", tone: nil), for: child))
        #expect(CultureQuizFilter.isAppropriate(quiz(3, tone: "fun"), for: child))
        #expect(CultureQuizFilter.isAppropriate(quiz(4, tone: nil), for: child))
    }

    @Test("child: difficulty 3 only in lycée; unknown level counts as collège")
    func childDifficulty() {
        let hard = quiz(1, difficulty: 3)
        #expect(!CultureQuizFilter.isAppropriate(hard, for: .child(level: "3e")))
        #expect(!CultureQuizFilter.isAppropriate(hard, for: .child(level: nil)))
        #expect(CultureQuizFilter.isAppropriate(hard, for: .child(level: "2nde")))
        #expect(CultureQuizFilter.isAppropriate(hard, for: .child(level: "Tle")))
        #expect(CultureQuizFilter.isAppropriate(quiz(2, difficulty: 2), for: .child(level: "6e")))
    }

    @Test("child: a sensitive word anywhere (question, explanation, choices) drops the question")
    func childSensitiveText() {
        let child = CultureQuizAudience.child(level: "5e")
        #expect(!CultureQuizFilter.isAppropriate(quiz(1, question: "Quel tueur en série inspire ce film ?"), for: child))
        #expect(!CultureQuizFilter.isAppropriate(quiz(2, explanation: "Un film sur la drogue."), for: child))
        let choices = CultureLotQuizDto(id: UUID(), domain: "films", question: "Quel genre ?",
                                        choices: ["Comédie", "Drame", "Horreur", "Western"], answerIndex: 2)
        #expect(!CultureQuizFilter.isAppropriate(choices, for: child))
    }

    @Test("child-safe text: whole words, case and accents folded", arguments: [
        ("Qui a écrit « Le Petit Prince » ?", true),
        ("Dans quel comté anglais, l'Essex, se passe la série ?", true),
        ("Un roman ÉROTIQUE du XVIIIe siècle", false),
        ("L'assassinat de César", false),
        ("Quel film d'épouvante…", false),
        ("Le sexe des anges", false),
        ("Une scène de Suicide Squad", false),
    ])
    func childSafeText(text: String, safe: Bool) {
        #expect(ChildSafeText.isSafe(text) == safe)
    }

    // MARK: Out of date

    @Test("past validUntil is out of date; validUntil today still plays")
    func validUntil() {
        #expect(!CultureQuizFilter.isPlayable(entry(quiz(1, validUntil: "2026-10-16")), today: "2026-10-17", calendar: calendar))
        #expect(CultureQuizFilter.isPlayable(entry(quiz(2, validUntil: "2026-10-17")), today: "2026-10-17", calendar: calendar))
    }

    @Test("actu without validUntil plays 3 days after its lot; evergreen never expires")
    func actuDefault() {
        let actu = entry(quiz(1, tone: "actu"), lotDate: "2026-10-14")
        #expect(CultureQuizFilter.isPlayable(actu, today: "2026-10-17", calendar: calendar))
        #expect(!CultureQuizFilter.isPlayable(actu, today: "2026-10-18", calendar: calendar))
        #expect(CultureQuizFilter.isPlayable(entry(quiz(2), lotDate: "2025-11-01"), today: "2026-10-17", calendar: calendar))
    }

    @Test("malformed questions never play")
    func malformed() {
        let dup = CultureLotQuizDto(id: UUID(), domain: "films", question: "Q ?",
                                    choices: ["a", "A", "b", "c"], answerIndex: 0)
        let outOfRange = CultureLotQuizDto(id: UUID(), domain: "films", question: "Q ?",
                                           choices: ["a", "b", "c", "d"], answerIndex: 4)
        #expect(!CultureQuizFilter.isWellFormed(dup))
        #expect(!CultureQuizFilter.isWellFormed(outOfRange))
    }

    // MARK: Draw

    @Test("draw: at most 10, unseen first, then seen ones refill")
    func drawUnseenFirst() {
        let pool = (1...12).map { entry(quiz($0)) }
        let seen = Set((1...8).map { pool[$0 - 1].id })
        var rng = SplitMix64(seed: 42)
        let drawn = CultureQuizDraw.draw(from: pool, audience: .parent, seen: seen, today: "2026-10-17",
                                         calendar: calendar, using: &rng)
        #expect(drawn.count == 10)
        #expect(Set(drawn.prefix(4).map(\.id)) == Set(pool[8...].map(\.id)))
        #expect(Set(drawn.map(\.id)).count == 10)
    }

    @Test("draw: interleaves apps and never repeats a question text")
    func drawInterleavesAndDedups() {
        let pool = (1...5).map { entry(quiz($0), app: "keskonfe") }
            + (6...10).map { entry(quiz($0, domain: "sport"), app: "leclub") }
            + [entry(quiz(11, question: "question 1 ?"), app: "sirius")]
        var rng = SplitMix64(seed: 7)
        let drawn = CultureQuizDraw.draw(from: pool, audience: .parent, seen: [], today: "2026-10-17",
                                         calendar: calendar, count: 4, using: &rng)
        #expect(drawn.count == 4)
        #expect(drawn.filter { $0.domain == "sport" }.count == 2)
        let all = CultureQuizDraw.draw(from: pool, audience: .parent, seen: [], today: "2026-10-17",
                                       calendar: calendar, count: 50, using: &rng)
        #expect(all.count == 10)
    }

    @Test("draw: the child pool is filtered, the parent one is not")
    func drawAudience() {
        let pool = [entry(quiz(1, domain: "politique"), app: "sirius"), entry(quiz(2, tone: "actu")),
                    entry(quiz(3, domain: "films"))]
        var rng = SplitMix64(seed: 1)
        let child = CultureQuizDraw.draw(from: pool, audience: .child(level: "6e"), seen: [], today: "2026-10-15",
                                         calendar: calendar, using: &rng)
        let parent = CultureQuizDraw.draw(from: pool, audience: .parent, seen: [], today: "2026-10-15",
                                          calendar: calendar, using: &rng)
        #expect(child.map(\.id) == [pool[2].id])
        #expect(parent.count == 3)
    }

    // MARK: Seen

    @Test("seen ids are kept per audience")
    func seenStore() throws {
        let suite = "CultureQuizSeen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CultureQuizSeenStore(defaults: defaults)
        let id = UUID()
        store.markSeen([id, id], for: .parent)
        #expect(store.seen(for: .parent) == [id])
        #expect(store.seen(for: .child(level: "5e")).isEmpty)
    }

    // MARK: Copy

    @Test("copy: vouvoiement for the parent, tutoiement for the child")
    func copy() {
        let parent = CultureQuizCopy(audience: .parent)
        let child = CultureQuizCopy(audience: .child(level: "5e"))
        #expect(parent.resultMessage(score: 7, total: 10).hasPrefix("Vous avez 7 bonnes réponses sur 10."))
        #expect(child.resultMessage(score: 1, total: 10).hasPrefix("Tu as 1 bonne réponse sur 10."))
        #expect(parent.accessibilityValue(.wrong) == "Votre réponse, incorrecte")
        #expect(child.accessibilityValue(.wrong) == "Ta réponse, incorrecte")
        let q = quiz(1)
        #expect(parent.feedbackTitle(quiz: q, answered: 1) == "Bonne réponse !")
        #expect(child.feedbackTitle(quiz: q, answered: 0) == "Pas tout à fait : la bonne réponse était « B ».")
        #expect(CultureQuizCopy.score(questions: [q, quiz(2)], answers: [1, 0]) == 1)
    }
}

/// `CultureQuizPoolStore.refresh`: GET-only culture bank sync, then the lots
/// of the three Koi apps when the bank is unavailable (today first then the
/// backfill, 404 marked), offline stops the round. Through
/// `QuizStubProtocol`; nested in `QuizBankSuites` (static stub).
extension QuizBankSuites {
@MainActor
@Suite("Culture G quiz — local pool")
struct CultureQuizPoolStoreTests {

    private let calendar = QuizClock.calendar
    /// 2023-11-14 22:13 UTC = 2023-11-14 23:13 Paris.
    private let now = QuizClock.now

    private func withStore(_ body: @MainActor (CultureQuizPoolStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CultureQuizPoolStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(CultureQuizPoolStore(directory: directory))
    }

    /// One quiz per lot, id derived from the app and date so merges are distinct.
    /// Nonisolated: called from the stub handler, a `@Sendable` nonisolated closure.
    nonisolated private static func lot(for request: URLRequest) -> QuizStubProtocol.Stub {
        if request.url?.path == bankPath { return .json(#"{"error":"Not found"}"#, status: 404) }
        let query = request.queryMap
        let app = query["app"] ?? "?"
        let date = query["date"] ?? "2023-11-14"
        let n = Int(UInt(bitPattern: (app + date).hashValue) % 1_000_000_000)
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!
        return .json(CultureLotFixtures.lotJSON(date: date, quizzes: [CultureLotFixtures.quizJSON(id: id)]))
    }

    @Test("cultureLot(app:date:) sends only app and date")
    func request() async throws {
        QuizStubProtocol.install { Self.lot(for: $0) }
        defer { QuizStubProtocol.reset() }
        _ = try await stubbedQuizClient().cultureLot(app: "sirius", date: "2023-11-10")
        let request = try #require(QuizStubProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/quiz/v2/lot")
        #expect(request.queryMap == ["app": "sirius", "date": "2023-11-10"])
    }

    @Test("no bank (404): today's 3 lots first, then 14 past days per app; second refresh is free")
    func backfill() async throws {
        QuizStubProtocol.install { Self.lot(for: $0) }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            let pool = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            #expect(QuizStubProtocol.requests.first?.url?.path == Self.bankPath)
            let requests = Array(QuizStubProtocol.requests.dropFirst())
            #expect(requests.count == 3 + 3 * CultureQuizPoolStore.backfillDays)
            #expect(requests.prefix(3).map { $0.queryMap } == QuizAPIClient.cultureLotApps.map { ["app": $0] })
            #expect(requests.dropFirst(3).allSatisfy { $0.queryMap["date"] != nil })
            #expect(requests.allSatisfy { $0.httpMethod == "GET" })
            #expect(Set(pool.map(\.app)) == Set(QuizAPIClient.cultureLotApps))
            #expect(pool.count == requests.count)

            QuizStubProtocol.install { Self.lot(for: $0) }
            let again = await store.refresh(client: stubbedQuizClient(), now: now.addingTimeInterval(60),
                                            calendar: calendar)
            #expect(QuizStubProtocol.requests.isEmpty)
            #expect(again.count == pool.count)
        }
    }

    @Test("404 days are not asked again; offline stops the round and is retried later")
    func missingAndOffline() async throws {
        QuizStubProtocol.install { _ in .json(#"{"error":"no lot for this date"}"#, status: 404) }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            _ = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            QuizStubProtocol.install { _ in .offline() }
            _ = await store.refresh(client: stubbedQuizClient(), now: now.addingTimeInterval(60), calendar: calendar)
            #expect(QuizStubProtocol.requests.isEmpty)
        }

        QuizStubProtocol.install { _ in .offline() }
        try await withStore { store in
            let pool = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            #expect(pool.isEmpty)
            #expect(QuizStubProtocol.requests.count == 1)
            QuizStubProtocol.install { Self.lot(for: $0) }
            let retried = await store.refresh(client: stubbedQuizClient(), now: now.addingTimeInterval(60),
                                              calendar: calendar)
            #expect(!retried.isEmpty)
        }
    }

    // MARK: Culture bank

    nonisolated static let bankPath = "/api/quiz/v2/bank/culture"

    nonisolated private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!
    }

    /// One `CultureBankQuizDto` as JSON, every contract key present.
    nonisolated private static func bankItem(_ n: Int, apps: [String] = ["sirius"], kind: String = "catalogue",
                                             generatedOn: String = "2023-11-10",
                                             validUntil: String? = nil) -> String {
        let appsJSON = apps.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id": "\(id(n).uuidString.lowercased())", "questionKey": "k\(n)", "source": "catalogue",
         "apps": [\(appsJSON)], "domain": "livres", "kind": "\(kind)", "tone": "histoire", "horizon": null,
         "difficulty": 2, "question": "Question \(n) ?", "choices": ["A", "B", "C", "D"], "answerIndex": 1,
         "explanation": null, "oeuvreId": null, "oeuvreTitle": null, "imageUrl": null,
         "generatedOn": "\(generatedOn)", "validUntil": \(validUntil.map { "\"\($0)\"" } ?? "null"),
         "reviewMethod": "jev", "reviewConfidence": 0.95, "updatedAt": "2023-11-14T10:00:00.000Z"}
        """
    }

    nonisolated private static func bankPage(_ items: [String], removed: [Int] = [], cursor: String?,
                                             hasMore: Bool) -> QuizStubProtocol.Stub {
        let removedJSON = removed.map {
            #"{"id": "\#(id($0).uuidString.lowercased())", "questionKey": "k\#($0)", "updatedAt": "2023-11-14T11:00:00.000Z"}"#
        }
        return .json("""
        {"app": "noto", "count": \(items.count), "items": [\(items.joined(separator: ","))],
         "removed": [\(removedJSON.joined(separator: ","))],
         "cursor": \(cursor.map { "\"\($0)\"" } ?? "null"), "hasMore": \(hasMore)}
        """)
    }

    @Test("cultureBank sends only app=noto, limit and the cursor")
    func bankRequest() async throws {
        QuizStubProtocol.install { _ in Self.bankPage([], cursor: nil, hasMore: false) }
        defer { QuizStubProtocol.reset() }
        let client = stubbedQuizClient()
        _ = try await client.cultureBank()
        _ = try await client.cultureBank(limit: 9_999, cursor: "c1")
        let requests = QuizStubProtocol.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == Self.bankPath })
        #expect(requests.map(\.queryMap) == [["app": "noto", "limit": "500"],
                                             ["app": "noto", "limit": "500", "cursor": "c1"]])
    }

    @Test("bank decoding drops an unreadable item, never the page")
    func bankLossy() throws {
        let json = """
        {"app": "noto", "count": 2, "items": [\(Self.bankItem(1)), {"id": "nope"}], "removed": [],
         "cursor": null, "hasMore": false}
        """
        let page = try JSONDecoder().decode(CultureBankResponse.self, from: Data(json.utf8))
        #expect(page.items.map(\.quiz.id) == [Self.id(1)])
        #expect(page.items.first?.apps == ["sirius"])
        #expect(page.items.first?.generatedOn == "2023-11-10")
    }

    @Test("full bank sync: pages until hasMore is false, replaces the pool, skips the lots")
    func bankFullSync() async throws {
        QuizStubProtocol.install { request in
            guard request.url?.path == Self.bankPath else { return Self.lot(for: request) }
            switch request.queryMap["cursor"] {
            case nil: return Self.bankPage([Self.bankItem(1), Self.bankItem(2, apps: [])], cursor: "p1", hasMore: true)
            case "p1": return Self.bankPage([Self.bankItem(3, apps: ["keskonfe", "sirius"])], cursor: "p2", hasMore: false)
            default: return .json("{}", status: 500)
            }
        }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            var seeded = CultureQuizPoolStore.Snapshot()
            seeded.entries = [CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA),
                                               app: "keskonfe", lotDate: "2023-11-13")]
            store.save(seeded)

            let pool = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            #expect(QuizStubProtocol.requests.allSatisfy { $0.url?.path == Self.bankPath })
            #expect(QuizStubProtocol.requests.count == 2)
            #expect(pool.map(\.id) == [Self.id(1), Self.id(2), Self.id(3)])
            #expect(pool.map(\.app) == ["sirius", CultureQuizPoolStore.bankApp, "keskonfe"])
            #expect(pool.allSatisfy { $0.fromBank == true && $0.lotDate == "2023-11-10" })
            #expect(store.load().bankCursor == "p2")

            QuizStubProtocol.install { _ in .offline() }
            _ = await store.refresh(client: stubbedQuizClient(), now: now.addingTimeInterval(600), calendar: calendar)
            #expect(QuizStubProtocol.requests.isEmpty)
        }
    }

    @Test("an interrupted full sync still replaces the pool when it resumes")
    func bankResumedFullSync() async throws {
        QuizStubProtocol.install { request in
            request.queryMap["cursor"] == nil
                ? Self.bankPage([Self.bankItem(1)], cursor: "p1", hasMore: true)
                : .offline()
        }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            var seeded = CultureQuizPoolStore.Snapshot()
            seeded.entries = [CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA),
                                               app: "keskonfe", lotDate: "2023-11-13")]
            store.save(seeded)
            _ = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            #expect(store.load().bankCursor == "p1")
            #expect(store.load().bankFullSyncSeen == [Self.id(1)])

            QuizStubProtocol.install { _ in Self.bankPage([Self.bankItem(2)], cursor: "p2", hasMore: false) }
            let pool = await store.refresh(client: stubbedQuizClient(), now: now.addingTimeInterval(60),
                                           calendar: calendar)
            #expect(QuizStubProtocol.requests.map { $0.queryMap["cursor"] } == ["p1"])
            #expect(pool.map(\.id) == [Self.id(1), Self.id(2)])
            #expect(store.load().bankFullSyncSeen == nil)
        }
    }

    @Test("incremental bank sync: sends the saved cursor, merges and applies tombstones")
    func bankIncremental() async throws {
        QuizStubProtocol.install { _ in
            Self.bankPage([Self.bankItem(1), Self.bankItem(2)], cursor: "p1", hasMore: false)
        }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            _ = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            QuizStubProtocol.install { _ in Self.bankPage([Self.bankItem(3)], removed: [1], cursor: "p2", hasMore: false) }
            let pool = await store.refresh(client: stubbedQuizClient(),
                                           now: now.addingTimeInterval(CultureQuizPoolStore.bankRefreshInterval),
                                           calendar: calendar)
            #expect(QuizStubProtocol.requests.map { $0.queryMap["cursor"] } == ["p1"])
            #expect(pool.map(\.id) == [Self.id(2), Self.id(3)])
            #expect(store.load().bankCursor == "p2")
        }
    }

    @Test("a refused cursor (400) restarts a full sync")
    func bankStaleCursor() async throws {
        QuizStubProtocol.install { request in
            request.queryMap["cursor"] == nil
                ? Self.bankPage([Self.bankItem(4)], cursor: "fresh", hasMore: false)
                : .json(#"{"error":"invalid cursor"}"#, status: 400)
        }
        defer { QuizStubProtocol.reset() }
        try await withStore { store in
            var seeded = CultureQuizPoolStore.Snapshot()
            seeded.bankCursor = "stale"
            store.save(seeded)
            let pool = await store.refresh(client: stubbedQuizClient(), now: now, calendar: calendar)
            #expect(QuizStubProtocol.requests.map { $0.queryMap["cursor"] } == ["stale", nil])
            #expect(pool.map(\.id) == [Self.id(4)])
            #expect(store.load().bankCursor == "fresh")
        }
    }

    @Test("bank questions skip the retention cutoff; their actus still expire")
    func bankRetention() {
        let today = CalendarDay(key: "2026-10-17")!
        var snapshot = CultureQuizPoolStore.Snapshot()
        snapshot.entries = [
            CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA), app: "koi",
                             lotDate: "2020-01-01", fromBank: true),
            CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idB, validUntil: "2026-10-12"),
                             app: "sirius", lotDate: "2026-10-10", fromBank: true),
        ]
        CultureQuizPoolStore.prune(&snapshot, today: today, calendar: calendar)
        #expect(snapshot.entries.map(\.id) == [CultureLotFixtures.idA])
    }

    @Test("a pool saved before the bank still loads")
    func legacySnapshot() throws {
        let json = #"{"entries": [], "fetchedDays": ["keskonfe|2023-11-13"], "todayFetchedAt": {}}"#
        let snapshot = try JSONDecoder().decode(CultureQuizPoolStore.Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.fetchedDays == ["keskonfe|2023-11-13"])
        #expect(snapshot.bankCursor == nil && snapshot.bankSyncedAt == nil)
    }

    @Test("prune drops out-of-date questions and the ones past retention")
    func prune() {
        let today = CalendarDay(key: "2026-10-17")!
        var snapshot = CultureQuizPoolStore.Snapshot()
        snapshot.entries = [
            CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA), app: "keskonfe", lotDate: "2026-10-10"),
            CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idB, validUntil: "2026-10-12"),
                             app: "sirius", lotDate: "2026-10-10"),
            CultureQuizEntry(quiz: CultureLotFixtures.quiz(CultureLotFixtures.idC), app: "leclub", lotDate: "2025-01-01"),
        ]
        snapshot.fetchedDays = ["keskonfe|2026-10-16", "keskonfe|2026-09-01"]
        CultureQuizPoolStore.prune(&snapshot, today: today, calendar: calendar)
        #expect(snapshot.entries.map(\.id) == [CultureLotFixtures.idA])
        #expect(snapshot.fetchedDays == ["keskonfe|2026-10-16"])
    }
}
}
