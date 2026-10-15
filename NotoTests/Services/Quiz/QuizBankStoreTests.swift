import Testing
import Foundation
import SwiftData
@testable import Noto

/// Mutable clock for throttle tests.
final class QuizTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// `QuizBankStore`: mapping into `QuizItem`, idempotent upsert, pagination,
/// per-grade high-water mark, 12 h throttle, offline-first failures. Every
/// request goes to `QuizStubProtocol`; SwiftData is an in-memory
/// `NotoSchemaV1` container; `UserDefaults` is an isolated suite.
extension QuizBankSuites {
@MainActor
@Suite("QuizBankStore")
struct QuizBankStoreTests {
    let context: ModelContext
    let defaults: UserDefaults
    let clock = QuizTestClock(QuizClock.now)

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let suite = "QuizBankStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> QuizBankStore {
        let clock = self.clock
        return QuizBankStore(modelContext: context, client: stubbedQuizClient(), defaults: defaults,
                             now: { clock.now })
    }

    private func items() throws -> [QuizItem] {
        try context.fetch(FetchDescriptor<QuizItem>(sortBy: [SortDescriptor(\.question)]))
    }

    // MARK: Mapping

    @Test("maps every contract field onto QuizItem (source .celyn, grade → level)")
    func mapping() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }

        let outcome = try await makeStore().sync(level: "6ème")
        #expect(outcome == .synced(upserted: 2, dropped: 0))

        let all = try items()
        #expect(all.count == 2)
        let item = try #require(all.first { $0.id == QuizBankFixtures.id1 })
        let question = "Quel héros de l'Odyssée est le roi d'Ithaque ?"
        let choices = ["Ulysse", "Achille", "Hector", "Énée"]
        #expect(item.questionKey == QuizKey.make(question: question, choices: choices))
        #expect(item.question == question)
        #expect(item.choices == choices)
        #expect(item.answerIndex == 0)
        #expect(item.explanation == "Ulysse est le roi d'Ithaque dans l'Odyssée d'Homère.")
        #expect(item.kind == "programme")
        #expect(item.domain == "scolaire")
        #expect(item.difficulty == 1)
        #expect(item.tone == "histoire")
        #expect(item.horizon == nil)
        #expect(item.validUntil == nil)
        #expect(item.promotedFrom == nil)
        #expect(item.oeuvreId == QuizBankFixtures.oeuvre)
        #expect(item.oeuvreTitle == "L'Odyssée")
        #expect(item.imageUrl == nil)
        #expect(item.format == .mcq)
        #expect(item.level == "6e")
        #expect(item.subject == "Français")
        #expect(item.theme == "Récits de création ; création poétique")
        #expect(item.notion == "Ulysse")
        #expect(item.source == .celyn)
        #expect(item.sourceRef == "celyn/bank/6e")
        #expect(item.fetchedAt == QuizClock.now)

        // Canonical grade on the wire, never the raw child label.
        #expect(QuizStubProtocol.requests.first?.queryMap["grade"] == "6e")
    }

    @Test("reviewed = reviewConfidence ≥ 0.9 and a review method")
    func reviewedFlag() {
        func dto(_ method: String?, _ confidence: Double) -> BankQuizDto {
            BankQuizDto(id: UUID(), questionKey: "k", grade: "6e", subject: "S", theme: "T", notion: nil,
                        kind: "programme", domain: "scolaire", difficulty: 1, tone: "histoire",
                        question: "Q ?", choices: ["a", "b", "c", "d"], answerIndex: 0, explanation: nil,
                        oeuvreId: nil, oeuvreTitle: nil, imageUrl: nil, reviewMethod: method,
                        reviewConfidence: confidence, updatedAt: "2026-10-15T10:00:00.000Z")
        }
        #expect(QuizBankMapper.isReviewed(dto("jev", 0.95)))
        #expect(QuizBankMapper.isReviewed(dto("deterministic", 0.9)))
        #expect(!QuizBankMapper.isReviewed(dto("llm", 0.89)))
        #expect(!QuizBankMapper.isReviewed(dto(nil, 1.0)))
    }

    @Test("reviewed flag persisted per item")
    func reviewedPersisted() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        try await makeStore().sync(level: "6e")
        let byID = Dictionary(uniqueKeysWithValues: try items().map { ($0.id, $0) })
        #expect(byID[QuizBankFixtures.id1]?.reviewed == true)   // jev 0.95
        #expect(byID[QuizBankFixtures.id2]?.reviewed == false)  // llm 0.7
    }

    @Test("structurally invalid items are dropped, the rest of the page is kept")
    func dropsInvalid() async throws {
        let bad = [
            QuizBankFixtures.item(id: UUID(), choices: ["a", "b", "c"]),
            QuizBankFixtures.item(id: UUID(), choices: ["Ulysse", " Ulysse ", "Hector", "Énée"]),
            QuizBankFixtures.item(id: UUID(), answerIndex: 4),
            QuizBankFixtures.item(id: UUID(), difficulty: 5),
            QuizBankFixtures.item(id: UUID(), grade: "5e"),
        ]
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: bad + [QuizBankFixtures.item()])) }
        defer { QuizStubProtocol.reset() }
        let outcome = try await makeStore().sync(level: "6e")
        #expect(outcome == .synced(upserted: 1, dropped: 5))
        #expect(try items().map(\.id) == [QuizBankFixtures.id1])
    }

    @Test("choices are distinct as celyn checks them (trimmed, exact): maths and units are kept")
    func distinctChoicesLikeServer() async throws {
        let ok = [
            QuizBankFixtures.item(id: QuizBankFixtures.id1, question: "Opposé de 3 ?", choices: ["-3", "3", "1/3", "0"]),
            QuizBankFixtures.item(id: QuizBankFixtures.id2, question: "Unité d'aire ?", choices: ["m²", "m³", "m", "Le Nil"]),
        ]
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: ok)) }
        defer { QuizStubProtocol.reset() }
        #expect(try await makeStore().sync(level: "6e") == .synced(upserted: 2, dropped: 0))
    }

    @Test("an updated row that fails a check deletes the stale local copy")
    func droppedUpdateDeletesStaleCopy() async throws {
        let store = makeStore()
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()])) }
        defer { QuizStubProtocol.reset() }
        #expect(try await store.sync(level: "6e") == .synced(upserted: 1, dropped: 0))

        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [QuizBankFixtures.item(answerIndex: 7,
                                                                      updatedAt: "2026-10-16T10:00:00.000Z")]))
        }
        #expect(try await store.sync(level: "6e", force: true) == .synced(upserted: 0, dropped: 1, removed: 1))
        #expect(try items().isEmpty)
        #expect(store.highWaterMark(grade: "6e") == "2026-10-16T10:00:00.000Z")
    }

    // MARK: Upsert

    @Test("upsert is idempotent and updates in place by id")
    func idempotentUpsert() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")
        try await store.sync(level: "6e", force: true)
        #expect(try items().count == 2)

        // celyn edits item 1 (new explanation, now reviewed).
        let edited = QuizBankFixtures.item(reviewMethod: "llm", reviewConfidence: 0.99,
                                           updatedAt: "2026-10-16T08:00:00.000Z")
            .replacingOccurrences(of: "Ulysse est le roi d'Ithaque dans l'Odyssée d'Homère.",
                                  with: "Ulysse règne sur Ithaque.")
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [edited])) }
        clock.now = QuizClock.now.addingTimeInterval(60)
        try await store.sync(level: "6e", force: true)

        let all = try items()
        #expect(all.count == 2)
        let item = try #require(all.first { $0.id == QuizBankFixtures.id1 })
        #expect(item.explanation == "Ulysse règne sur Ithaque.")
        #expect(item.fetchedAt == QuizClock.now.addingTimeInterval(60))
    }

    // MARK: Pagination + high-water mark

    @Test("loops on nextUpdatedSince and stores the high-water mark per grade")
    func pagination() async throws {
        QuizStubProtocol.install { request in
            switch request.queryMap["updatedSince"] {
            case nil:
                return .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()],
                                                   next: "2026-10-15T10:00:00.000Z"))
            case "2026-10-15T10:00:00.000Z":
                return .json(QuizBankFixtures.page(items: [
                    QuizBankFixtures.item(id: QuizBankFixtures.id2, question: "Qui a écrit l'Odyssée ?",
                                          choices: ["Homère", "Virgile", "Ovide", "Sophocle"],
                                          updatedAt: "2026-10-15T12:00:00.000Z"),
                ]))
            default:
                return .json("unexpected", status: 500)
            }
        }
        defer { QuizStubProtocol.reset() }

        let store = makeStore()
        let outcome = try await store.sync(level: "6e")
        #expect(outcome == .synced(upserted: 2, dropped: 0))
        #expect(QuizStubProtocol.requests.count == 2)
        #expect(QuizStubProtocol.requests.allSatisfy { $0.queryMap["limit"] == "200" })
        // Last page has a null cursor: the mark is its last item's updatedAt.
        #expect(store.highWaterMark(grade: "6e") == "2026-10-15T12:00:00.000Z")
        #expect(store.highWaterMark(grade: "5e") == nil)
        #expect(store.lastSync(grade: "6e") == QuizClock.now)

        // Next sync resumes from the mark.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        try await store.sync(level: "6e", force: true)
        #expect(QuizStubProtocol.requests.last?.queryMap["updatedSince"] == "2026-10-15T12:00:00.000Z")
        #expect(store.highWaterMark(grade: "6e") == "2026-10-15T12:00:00.000Z")
    }

    @Test("a server repeating the same cursor does not loop")
    func repeatedCursorStops() async throws {
        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()], next: "2026-10-15T10:00:00.000Z"))
        }
        defer { QuizStubProtocol.reset() }
        try await makeStore().sync(level: "6e")
        // Page 1 (no cursor) moves to …10:00; page 2 returns the same cursor → stop.
        #expect(QuizStubProtocol.requests.count == 2)
    }

    @Test("a short page with a cursor is not the last one: the loop continues")
    func shortNonFinalPageContinues() async throws {
        QuizStubProtocol.install { request in
            switch request.queryMap["updatedSince"] {
            case nil:
                // 1 item < limit 200, yet more rows follow.
                return .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()],
                                                   next: "2026-10-15T10:00:00.000Z"))
            case "2026-10-15T10:00:00.000Z":
                // No item at all, still non-final.
                return .json(QuizBankFixtures.page(items: [], next: "2026-10-15T11:00:00.000Z"))
            case "2026-10-15T11:00:00.000Z":
                return .json(QuizBankFixtures.page(items: [
                    QuizBankFixtures.item(id: QuizBankFixtures.id2, question: "Qui a écrit l'Odyssée ?",
                                          choices: ["Homère", "Virgile", "Ovide", "Sophocle"],
                                          updatedAt: "2026-10-15T12:00:00.000Z"),
                ]))
            default:
                return .json("unexpected", status: 500)
            }
        }
        defer { QuizStubProtocol.reset() }

        let store = makeStore()
        #expect(try await store.sync(level: "6e") == .synced(upserted: 2, dropped: 0))
        #expect(QuizStubProtocol.requests.count == 3)
        #expect(try items().count == 2)
        #expect(store.highWaterMark(grade: "6e") == "2026-10-15T12:00:00.000Z")
    }

    // MARK: Removals

    @Test("removed ids delete local items in the same save; attempts are kept")
    func removedDeletes() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")
        #expect(try items().count == 2)

        // An attempt that played item 1: history is values, not a relationship.
        let attempt = QuizAttempt(date: QuizClock.now, itemIDs: [QuizBankFixtures.id1],
                                  questionKeys: ["k1"], answers: [0], correctCount: 1, totalCount: 1,
                                  durationSec: 30, minutesEarned: 1, bonusApplied: false)
        context.insert(attempt)
        try context.save()

        // Incremental page: item 2 edited, item 1 reported past the threshold.
        let edited = QuizBankFixtures.item(id: QuizBankFixtures.id2, question: "Qui a écrit l'Odyssée ?",
                                           choices: ["Homère", "Virgile", "Ovide", "Sophocle"],
                                           updatedAt: "2026-10-16T08:00:00.000Z")
            .replacingOccurrences(of: "Ulysse est le roi d'Ithaque dans l'Odyssée d'Homère.",
                                  with: "Homère, poète grec.")
        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [edited],
                                        removed: [QuizBankFixtures.removedEntry(id: QuizBankFixtures.id1)]))
        }
        let outcome = try await store.sync(level: "6e", force: true)
        #expect(outcome == .synced(upserted: 1, dropped: 0, removed: 1))
        #expect(QuizStubProtocol.requests.last?.queryMap["updatedSince"] == "2026-10-15T12:00:00.000Z")

        // Persisted (read through a fresh context, not the store's pending state).
        let fresh = ModelContext(context.container)
        let remaining = try fresh.fetch(FetchDescriptor<QuizItem>())
        #expect(remaining.map(\.id) == [QuizBankFixtures.id2])
        #expect(remaining.first?.explanation == "Homère, poète grec.")
        let attempts = try fresh.fetch(FetchDescriptor<QuizAttempt>())
        #expect(attempts.map(\.itemIDs) == [[QuizBankFixtures.id1]])
    }

    @Test("unknown removed ids are ignored")
    func unknownRemovedIgnored() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")

        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [], removed: [QuizBankFixtures.removedEntry(id: UUID())]))
        }
        #expect(try await store.sync(level: "6e", force: true) == .synced(upserted: 0, dropped: 0, removed: 0))
        #expect(try items().count == 2)
    }

    @Test("a removed-only page advances the high-water mark")
    func removedOnlyPageAdvancesMark() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")
        #expect(store.highWaterMark(grade: "6e") == "2026-10-15T12:00:00.000Z")

        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [], removed: [
                QuizBankFixtures.removedEntry(id: QuizBankFixtures.id2, updatedAt: "2026-10-16T09:00:00.000Z"),
            ]))
        }
        #expect(try await store.sync(level: "6e", force: true) == .synced(upserted: 0, dropped: 0, removed: 1))
        #expect(store.highWaterMark(grade: "6e") == "2026-10-16T09:00:00.000Z")
        #expect(try items().map(\.id) == [QuizBankFixtures.id1])
    }

    @Test("last-page mark is the max over items and removals")
    func markIsMaxOfItemsAndRemovals() async throws {
        // Prime the mark with a full sync (no `removed` there, per contract).
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")

        // Incremental: removal later than the item.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(
            items: [QuizBankFixtures.item(updatedAt: "2026-10-16T08:00:00.000Z")],
            removed: [QuizBankFixtures.removedEntry(id: UUID(), updatedAt: "2026-10-16T09:00:00.000Z")]
        )) }
        try await store.sync(level: "6e", force: true)
        #expect(store.highWaterMark(grade: "6e") == "2026-10-16T09:00:00.000Z")

        // Item later than the removal.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(
            items: [QuizBankFixtures.item(updatedAt: "2026-10-16T11:00:00.000Z")],
            removed: [QuizBankFixtures.removedEntry(id: UUID(), updatedAt: "2026-10-16T10:00:00.000Z")]
        )) }
        try await store.sync(level: "6e", force: true)
        #expect(store.highWaterMark(grade: "6e") == "2026-10-16T11:00:00.000Z")
    }

    @Test("timestamp comparison: dates, not strings; never backwards")
    func laterTimestamp() {
        #expect(QuizBankMapper.later(nil, "2026-10-15T10:00:00.000Z") == "2026-10-15T10:00:00.000Z")
        #expect(QuizBankMapper.later("2026-10-15T10:00:00.000Z", nil) == "2026-10-15T10:00:00.000Z")
        #expect(QuizBankMapper.later("2026-10-15T10:00:00.500Z", "2026-10-15T10:00:00Z") == "2026-10-15T10:00:00.500Z")
        #expect(QuizBankMapper.later("2026-10-15T10:00:00.000Z", "2026-10-15T12:00:00.000+01:00")
                == "2026-10-15T12:00:00.000+01:00")
    }

    // MARK: Throttle

    @Test("at most one sync per grade per 12 h unless forced")
    func throttle() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()

        #expect(try await store.sync(level: "6e") == .synced(upserted: 2, dropped: 0))
        clock.now = QuizClock.now.addingTimeInterval(11 * 3600)
        #expect(try await store.sync(level: "6e") == .throttled)
        #expect(QuizStubProtocol.requests.count == 1)

        // Another grade has its own window.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(grade: "2nde", items: [])) }
        #expect(try await store.sync(level: "Seconde") == .synced(upserted: 0, dropped: 0))

        // Forced bypasses the window.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        #expect(try await store.sync(level: "6e", force: true) == .synced(upserted: 0, dropped: 0))

        // Window measured from the last success (the forced one, at +11 h).
        clock.now = QuizClock.now.addingTimeInterval(22 * 3600)
        #expect(try await store.sync(level: "6e") == .throttled)
        clock.now = QuizClock.now.addingTimeInterval(23 * 3600 + 1)
        #expect(try await store.sync(level: "6e") == .synced(upserted: 0, dropped: 0))
    }

    @Test("primary and unknown levels never hit the server")
    func unsupportedLevel() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        #expect(try await store.sync(level: "CM2") == .unsupportedLevel("CM2"))
        #expect(try await store.sync(level: "?") == .unsupportedLevel("?"))
        #expect(QuizStubProtocol.requests.isEmpty)
    }

    // MARK: Offline-first

    @Test("network failure keeps local items, the mark and the throttle untouched")
    func failureKeepsLocalData() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        try await store.sync(level: "6e")
        let mark = store.highWaterMark(grade: "6e")
        let stamped = store.lastSync(grade: "6e")

        QuizStubProtocol.install { _ in .offline() }
        clock.now = QuizClock.now.addingTimeInterval(13 * 3600)
        let error = await quizError { try await store.sync(level: "6e") }
        guard case .transport = error else {
            Issue.record("expected .transport, got \(String(describing: error))")
            return
        }
        #expect(try items().count == 2)
        #expect(store.highWaterMark(grade: "6e") == mark)
        #expect(store.lastSync(grade: "6e") == stamped)

        // Not throttled: the failed attempt did not stamp a success.
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        #expect(try await store.sync(level: "6e") == .synced(upserted: 0, dropped: 0))
    }

    @Test("failure on page 2 keeps page 1 and its mark; next sync resumes there")
    func partialFailureResumes() async throws {
        QuizStubProtocol.install { request in
            request.queryMap["updatedSince"] == nil
                ? .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()], next: "2026-10-15T10:00:00.000Z"))
                : .json(#"{"error":"boom"}"#, status: 500)
        }
        defer { QuizStubProtocol.reset() }
        let store = makeStore()
        let error = await quizError { try await store.sync(level: "6e") }
        guard case .httpError(500, _) = error else {
            Issue.record("expected .httpError(500), got \(String(describing: error))")
            return
        }
        #expect(try items().map(\.id) == [QuizBankFixtures.id1])
        #expect(store.highWaterMark(grade: "6e") == "2026-10-15T10:00:00.000Z")
        #expect(store.lastSync(grade: "6e") == nil)

        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        try await store.sync(level: "6e")
        #expect(QuizStubProtocol.requests.last?.queryMap["updatedSince"] == "2026-10-15T10:00:00.000Z")
    }
}
}
