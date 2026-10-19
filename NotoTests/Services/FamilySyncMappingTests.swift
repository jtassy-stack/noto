import Testing
import Foundation
import SwiftData
@testable import Noto

/// Family sync (phase 9.3): local models ↔ records, without CloudKit.
@Suite("FamilySync mapping")
@MainActor
struct FamilySyncMappingTests {
    private let date = QuizClock.date(day: 0, hour: 17)

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: NotoSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeChild(in context: ModelContext) -> Child {
        let child = Child(firstName: "Léa", level: .elementaire, grade: "4e", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "FamilySyncMappingTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private var attempt: SyncedAttempt {
        SyncedAttempt(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, date: date, correctCount: 4,
                      totalCount: 5, durationSec: 80, minutesEarned: 10, bonusApplied: false, bonusMinutes: 0,
                      denialReason: nil, itemSubjects: ["SVT", "", "Histoire", "SVT", "SVT"],
                      itemXP: [10, 0, 10, 10, 15])
    }

    private var notion: SyncedNotion {
        SyncedNotion(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                     notionKey: "4e|svt|la digestion", leitnerBox: 3, nextReview: date, streakCorrect: 2,
                     lastReviewedAt: date, masteredAt: nil)
    }

    // MARK: Fingerprint and outbox

    @Test func fingerprintFollowsContentOnly() {
        let a = attempt.record
        var reordered = FamilySyncRecord(kind: a.kind, name: a.name, decodedFields: [:])
        for key in a.fields.keys.sorted().reversed() { reordered.fields[key] = a.fields[key] }
        #expect(reordered.fingerprint == a.fingerprint)

        var changed = a
        changed.fields["correct"] = .int(5)
        #expect(changed.fingerprint != a.fingerprint)
        #expect(notion.record.fingerprint != a.fingerprint)
    }

    @Test func outboxSendsOnlyWhatChanged() {
        let records = [attempt.record, notion.record]
        #expect(FamilySyncOutbox.pending(records, sent: [:]).count == 2)

        let sent = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.fingerprint) })
        #expect(FamilySyncOutbox.pending(records, sent: sent).isEmpty)

        let moved = SyncedNotion(id: notion.id, notionKey: notion.notionKey, leitnerBox: 4,
                                 nextReview: notion.nextReview, streakCorrect: 3,
                                 lastReviewedAt: notion.lastReviewedAt, masteredAt: date)
        #expect(FamilySyncOutbox.pending([attempt.record, moved.record], sent: sent).map(\.name)
                == [moved.record.name])
    }

    @Test func childRecordsComeFromTheLocalModels() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        let local = QuizAttempt(child: child, date: date, itemIDs: [UUID()], questionKeys: ["secret-hash"],
                                answers: [1], correctCount: 1, totalCount: 1, durationSec: 30, minutesEarned: 0,
                                bonusApplied: false, itemSubjects: ["SVT"], itemXP: [10])
        context.insert(local)
        context.insert(NotionMastery(child: child, notionKey: "4e|svt|la digestion", now: date,
                                     calendar: QuizClock.calendar))
        context.insert(StreakJoker(child: child, day: CalendarDay(key: "2026-10-17")!, createdAt: date))
        try context.save()

        var ledger = RewardLedger(day: "2026-10-18")
        ledger.creditedToday = 20
        let records = FamilySyncOutbox.childRecords(for: child, ledger: ledger)
        #expect(Set(records.map(\.kind)) == [.attempt, .notion, .joker, .dayMinutes])
        #expect(records.contains { $0.name == SyncedAttempt.recordName(local.id) })
        // Question keys never leave the child's device.
        #expect(!records.contains { $0.fingerprint.contains("secret-hash") })
    }

    // MARK: Ingest

    @Test func ingestWritesUnderTheParentsChildAndIsIdempotent() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        let joker = SyncedJoker(id: UUID(), dayKey: "2026-10-17", createdAt: date)
        let minutes = SyncedDayMinutes(day: "2026-10-18", credited: 15, pending: 5, reserve: 0)
        let records = [attempt.record, notion.record, joker.record, minutes.record,
                       SyncedRules(config: .default, cultureQuizEnabled: true, familyChallengeEnabled: true).record]

        let first = FamilySyncIngest.apply(records, to: child, context: context)
        try context.save()
        #expect(first == FamilySyncIngest.Result(attempts: 1, notions: 1, jokers: 1, minutes: minutes))
        #expect(child.quizAttempts.count == 1)
        #expect(child.quizAttempts.first?.id == attempt.id)
        #expect(child.quizAttempts.first?.itemSubjects == attempt.itemSubjects)
        #expect(child.quizAttempts.first?.questionKeys.isEmpty == true)
        #expect(child.streakJokers.first?.id == joker.id)

        FamilySyncIngest.apply(records, to: child, context: context)
        try context.save()
        #expect(child.quizAttempts.count == 1)
        #expect(child.streakJokers.count == 1)
        #expect(child.notionMasteries.count == 1)
    }

    @Test func ingestUpdatesAKnownNotion() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        FamilySyncIngest.apply([notion.record], to: child, context: context)
        let later = SyncedNotion(id: notion.id, notionKey: notion.notionKey, leitnerBox: 5, nextReview: date,
                                 streakCorrect: 4, lastReviewedAt: date, masteredAt: date)
        FamilySyncIngest.apply([later.record], to: child, context: context)
        try context.save()
        #expect(child.notionMasteries.count == 1)
        #expect(child.notionMasteries.first?.leitnerBox == 5)
        #expect(child.notionMasteries.first?.masteredAt == date)
    }

    @Test func ingestSkipsUnreadableRecords() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        let broken = FamilySyncRecord(kind: .attempt, name: "attempt-pas-un-uuid", fields: attempt.record.fields)
        let result = FamilySyncIngest.apply([broken], to: child, context: context)
        #expect(result.isEmpty)
        #expect(child.quizAttempts.isEmpty)
    }

    // MARK: Rules and state

    @Test func rulesReplaceTheChildDevicesSettings() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = RewardConfig(tiers: [5, 5, 5], passThreshold: 0.6, dailyCap: 25).sanitized()
        let rules = SyncedRules(config: config, cultureQuizEnabled: true, familyChallengeEnabled: true)

        #expect(FamilySyncRulesApplier.apply(rules.record, defaults: defaults))
        #expect(SyncedRules.current(defaults: defaults) == rules)
        #expect(!FamilySyncRulesApplier.apply(attempt.record, defaults: defaults))
    }

    @Test func stateStoreKeepsEachZoneApart() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FamilySyncStateStore(defaults: defaults)
        let zone = FamilySyncLink.makeZoneName()
        let other = FamilySyncLink.makeZoneName()

        store.markSent([attempt.record], zoneName: zone)
        store.setChangeToken(Data([1, 2, 3]), zoneName: zone)
        let minutes = SyncedDayMinutes(day: "2026-10-18", credited: 15, pending: 5, reserve: 2)
        store.setReceivedMinutes(minutes, zoneName: zone)

        #expect(store.sent(zoneName: zone) == [attempt.record.name: attempt.record.fingerprint])
        #expect(store.changeToken(zoneName: zone) == Data([1, 2, 3]))
        #expect(store.receivedMinutes(zoneName: zone) == minutes)
        #expect(store.sent(zoneName: other).isEmpty)

        store.clear(zoneName: zone)
        #expect(store.sent(zoneName: zone).isEmpty)
        #expect(store.changeToken(zoneName: zone) == nil)
        #expect(store.receivedMinutes(zoneName: zone) == nil)
    }
}
