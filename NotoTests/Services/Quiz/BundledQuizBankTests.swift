import Testing
import Foundation
import SwiftData
@testable import Noto

/// Offline fallback (plan §3.2 « banque embarquée »): the bundled snapshots in
/// `Noto/Resources/questions/` decode with the celyn DTO, are structurally
/// valid and programme-consistent, and seed the store once without touching
/// the sync state. `Bundle.main` is the test host (`Noto.app`). Nested in
/// `QuizBankSuites` because the upsert test drives `QuizStubProtocol`.
extension QuizBankSuites {
@MainActor
@Suite("Bundled quiz bank (offline fallback)")
struct BundledQuizBankTests {
    nonisolated static let bundledGrades = ["6e", "2nde"]

    let context: ModelContext
    let defaults: UserDefaults
    let clock = QuizTestClock(QuizClock.now)

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        let suite = "BundledQuizBankTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> QuizBankStore {
        let clock = self.clock
        return QuizBankStore(modelContext: context, client: stubbedQuizClient(), defaults: defaults,
                             now: { clock.now })
    }

    private func items(level: String) throws -> [QuizItem] {
        try context.fetch(FetchDescriptor<QuizItem>()).filter { $0.level == level }
    }

    private func bundled(_ grade: String) throws -> BundledQuizBank.File {
        try #require(try BundledQuizBank.load(grade: grade))
    }

    // MARK: Files

    @Test("ships in the bundle and decodes with the celyn DTO", arguments: bundledGrades)
    func decodes(grade: String) throws {
        #expect(BundledQuizBank.url(grade: grade) != nil)
        let file = try bundled(grade)
        #expect(file.grade == grade)
        #expect(!file.version.isEmpty)
        #expect(!file.items.isEmpty)
    }

    @Test("every item is valid: 4 distinct choices, answerIndex in range, grade, reviewed",
          arguments: bundledGrades)
    func itemsAreValid(grade: String) throws {
        let file = try bundled(grade)
        for dto in file.items {
            #expect(QuizBankMapper.problem(in: dto, expectedGrade: grade) == nil, "\(dto.id)")
            let trimmed = dto.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            #expect(dto.choices.count == 4 && Set(trimmed).count == 4, "\(dto.id)")
            #expect((0..<dto.choices.count).contains(dto.answerIndex), "\(dto.id)")
            #expect(dto.grade == grade, "\(dto.id)")
            #expect(QuizBankMapper.isReviewed(dto), "\(dto.id)")
            #expect(!dto.subject.isEmpty && !dto.theme.isEmpty, "\(dto.id)")
        }
        #expect(Set(file.items.map(\.id)).count == file.items.count)
        #expect(Set(file.items.map(\.questionKey)).count == file.items.count)
    }

    @Test("every item's subject + theme exists in curriculum.json for its level",
          arguments: bundledGrades)
    func matchesCurriculum(grade: String) throws {
        let program = try #require(CurriculumService.bundledPrograms.first { $0.level == grade })
        let pairs = Set(program.subjects.flatMap { subject in
            subject.themes.map { "\(subject.name)\u{1F}\($0.theme)" }
        })
        for dto in try bundled(grade).items {
            #expect(pairs.contains("\(dto.subject)\u{1F}\(dto.theme)"),
                    "\(dto.id): \(dto.subject) / \(dto.theme) not in curriculum \(grade)")
        }
    }

    @Test("ids do not collide across bundled levels")
    func idsDistinctAcrossLevels() throws {
        let all = try Self.bundledGrades.flatMap { try bundled($0).items.map(\.id) }
        #expect(Set(all).count == all.count)
    }

    // MARK: Seeding

    @Test("seeds N reviewed .celyn items once (idempotent), from a stored grade label")
    func seedsOnce() throws {
        let expected = try bundled("6e").items.count
        let store = makeStore()

        #expect(try store.seedBundledIfNeeded(level: "6ème") == expected)
        let seeded = try items(level: "6e")
        #expect(seeded.count == expected)
        #expect(seeded.allSatisfy { $0.source == .celyn && $0.reviewed && $0.format == .mcq })
        #expect(seeded.allSatisfy { $0.sourceRef == BundledQuizBank.sourceRef(grade: "6e") })
        let ids = Set(try bundled("6e").items.map(\.id))
        #expect(Set(seeded.map(\.id)) == ids)

        #expect(try store.seedBundledIfNeeded(level: "6e") == 0)
        #expect(try items(level: "6e").count == expected)
        #expect(QuizSession.availableItems(level: "6e", in: context, now: QuizClock.now).count == expected)
    }

    @Test("seeding leaves the high-water mark and lastSync untouched")
    func seedKeepsSyncState() throws {
        let store = makeStore()
        try store.seedBundledIfNeeded(level: "2nde")
        #expect(store.highWaterMark(grade: "2nde") == nil)
        #expect(store.lastSync(grade: "2nde") == nil)
        #expect(defaults.string(forKey: QuizBankStore.updatedSinceKey(grade: "2nde")) == nil)
        #expect(defaults.object(forKey: QuizBankStore.lastSyncKey(grade: "2nde")) == nil)
    }

    @Test("no seeding when the level already has a celyn item")
    func noSeedOverCelyn() throws {
        let dto = try JSONDecoder().decode(BankQuizDto.self, from: Data(QuizBankFixtures.item().utf8))
        context.insert(QuizBankMapper.makeItem(from: dto, fetchedAt: QuizClock.now))
        try context.save()

        #expect(try makeStore().seedBundledIfNeeded(level: "6e") == 0)
        #expect(try items(level: "6e").count == 1)
    }

    @Test("other levels are unaffected: only the asked level is seeded")
    func seedsOnlyAskedLevel() throws {
        try makeStore().seedBundledIfNeeded(level: "6e")
        #expect(try items(level: "2nde").isEmpty)
    }

    @Test("no file, or a level outside 6e → Tle: nothing seeded", arguments: ["4e", "Tle", "CM2", "inconnu"])
    func nothingToSeed(level: String) throws {
        #expect(try makeStore().seedBundledIfNeeded(level: level) == 0)
        #expect(try context.fetch(FetchDescriptor<QuizItem>()).isEmpty)
    }

    @Test("QuizSession seeds the bundled bank when the level is empty")
    func sessionSeedsWhenEmpty() throws {
        let child = Child(firstName: "Léa", level: .college, grade: "6ème", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        let session = QuizSession(child: child, modelContext: context, config: .default,
                                  calendar: QuizClock.calendar, seed: 42, now: { QuizClock.now })
        #expect(session.phase == .inProgress)
        #expect(session.questions.count == QuizSession.questionCount)
        #expect(try items(level: "6e").count == (try bundled("6e").items.count))
    }

    // MARK: Later network sync

    /// The bundled file re-wrapped as a final celyn page: same ids and
    /// questionKeys, the first item's explanation edited, the last item left
    /// out (excluded server-side since the snapshot).
    private func serverPage(grade: String) throws -> (json: String, editedID: UUID, droppedID: UUID, served: Int) {
        let url = try #require(BundledQuizBank.url(grade: grade))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(root["items"] as? [[String: Any]])
        let dropped = rows.removeLast()
        rows[0]["explanation"] = "Explication mise à jour par celyn."
        rows[0]["updatedAt"] = "2026-10-20T08:00:00.000Z"
        let page: [String: Any] = [
            "app": "noto", "grade": grade, "count": rows.count, "items": rows,
            "removed": [], "nextUpdatedSince": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: page)
        let editedRaw = try #require(rows[0]["id"] as? String)
        let editedID = try #require(UUID(uuidString: editedRaw))
        let droppedRaw = try #require(dropped["id"] as? String)
        let droppedID = try #require(UUID(uuidString: droppedRaw))
        return (String(decoding: data, as: UTF8.self), editedID, droppedID, rows.count)
    }

    @Test("a later full sync of the same ids upserts in place, never duplicates")
    func laterSyncUpserts() async throws {
        let store = makeStore()
        let seededCount = try store.seedBundledIfNeeded(level: "6e")
        let page = try serverPage(grade: "6e")
        let json = page.json
        QuizStubProtocol.install { _ in .json(json) }
        defer { QuizStubProtocol.reset() }

        let outcome = try await store.sync(level: "6e")

        // Full sync (no mark after seeding): no updatedSince on the request.
        let request = try #require(QuizStubProtocol.requests.first)
        #expect(request.queryMap["updatedSince"] == nil)
        #expect(outcome == .synced(upserted: page.served, dropped: 0, removed: 1))

        let all = try items(level: "6e")
        #expect(all.count == seededCount - 1)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.questionKey)).count == all.count)
        #expect(all.allSatisfy { $0.sourceRef == QuizBankMapper.sourceRef(grade: "6e") })
        let edited = try #require(all.first { $0.id == page.editedID })
        #expect(edited.explanation == "Explication mise à jour par celyn.")
        // Not served by the full feed → pruned (excluded since the snapshot).
        #expect(!all.contains { $0.id == page.droppedID })
        // The sync, not the seed, set the mark.
        #expect(store.highWaterMark(grade: "6e") == "2026-10-20T08:00:00.000Z")
        // Server rows now exist: no re-seed.
        #expect(try store.seedBundledIfNeeded(level: "6e") == 0)
    }

    @Test("an incremental sync never prunes seeded rows it did not mention")
    func incrementalSyncKeepsSeeded() async throws {
        let store = makeStore()
        let seededCount = try store.seedBundledIfNeeded(level: "6e")
        defaults.set("2026-10-15T00:00:00.000Z", forKey: QuizBankStore.updatedSinceKey(grade: "6e"))
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        defer { QuizStubProtocol.reset() }

        _ = try await store.sync(level: "6e")
        #expect(try items(level: "6e").count == seededCount)
    }

    /// The bundled 6e rows as raw JSON objects, wrapped in a celyn page.
    private func bundledRows(_ grade: String) throws -> [[String: Any]] {
        let url = try #require(BundledQuizBank.url(grade: grade))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["items"] as? [[String: Any]])
    }

    private func pageJSON(grade: String, rows: [[String: Any]], next: String?) throws -> String {
        let page: [String: Any] = [
            "app": "noto", "grade": grade, "count": rows.count, "items": rows,
            "removed": [], "nextUpdatedSince": next.map { $0 as Any } ?? NSNull(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
    }

    @Test("a full sync interrupted on page 2 still prunes unserved seeded rows once resumed")
    func interruptedFullSyncPrunesOnResume() async throws {
        let store = makeStore()
        let seededCount = try store.seedBundledIfNeeded(level: "6e")
        var rows = try bundledRows("6e")
        let dropped = rows.removeLast()
        let droppedRaw = try #require(dropped["id"] as? String)
        let droppedID = try #require(UUID(uuidString: droppedRaw))
        let half = rows.count / 2
        let cursor = "2026-10-15T10:00:00.000Z"
        let page1 = try pageJSON(grade: "6e", rows: Array(rows[..<half]), next: cursor)
        let page2 = try pageJSON(grade: "6e", rows: Array(rows[half...]), next: nil)

        // Run 1: page 1 saved (the mark moves), page 2 fails.
        QuizStubProtocol.install { request in
            request.queryMap["updatedSince"] == nil ? .json(page1) : .json(#"{"error":"boom"}"#, status: 500)
        }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { try await store.sync(level: "6e") }
        guard case .httpError(500, _) = error else {
            Issue.record("expected .httpError(500), got \(String(describing: error))")
            return
        }
        #expect(store.highWaterMark(grade: "6e") == cursor)
        #expect(defaults.bool(forKey: QuizBankStore.fullSyncPendingKey(grade: "6e")))
        #expect(try items(level: "6e").count == seededCount)

        // Run 2 resumes from the mark (incremental request) and drains the feed.
        QuizStubProtocol.install { _ in .json(page2) }
        _ = try await store.sync(level: "6e")
        #expect(QuizStubProtocol.requests.last?.queryMap["updatedSince"] == cursor)

        let all = try items(level: "6e")
        #expect(all.count == seededCount - 1)
        #expect(!all.contains { $0.id == droppedID })
        #expect(all.allSatisfy { $0.sourceRef == QuizBankMapper.sourceRef(grade: "6e") })
        #expect(!defaults.bool(forKey: QuizBankStore.fullSyncPendingKey(grade: "6e")))
    }

    @Test("a level emptied by celyn removals is not re-seeded from the snapshot")
    func noReseedAfterServerRemovals() async throws {
        let store = makeStore()
        try store.seedBundledIfNeeded(level: "6e")
        let page = try serverPage(grade: "6e")
        let json = page.json
        QuizStubProtocol.install { _ in .json(json) }
        defer { QuizStubProtocol.reset() }
        try await store.sync(level: "6e")

        // celyn later removes every item of the level (incremental feed).
        for item in try items(level: "6e") { context.delete(item) }
        try context.save()
        #expect(try items(level: "6e").isEmpty)
        #expect(store.highWaterMark(grade: "6e") != nil)

        #expect(try store.seedBundledIfNeeded(level: "6e") == 0)
        #expect(try QuizBankStore.seedBundledIfNeeded(level: "6e", in: context, defaults: defaults) == 0)
        #expect(try items(level: "6e").isEmpty)
    }
}
}
