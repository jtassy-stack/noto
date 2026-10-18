import CloudKit
import Testing
import Foundation
@testable import Noto

/// Family sync (phase 9.1): the records that cross between the child's and
/// the parent's devices, and their CKRecord form.
@Suite("FamilySyncRecord")
struct FamilySyncRecordTests {
    private let zone = CKRecordZone.ID(zoneName: "enfant-test", ownerName: CKCurrentUserDefaultName)
    private let date = QuizClock.date(day: 0, hour: 17)

    // Stored, not computed: one id per test, so two reads compare equal.
    private let attempt =
        SyncedAttempt(id: UUID(), date: QuizClock.date(day: 0, hour: 17), correctCount: 4, totalCount: 5,
                      durationSec: 92, minutesEarned: 15, bonusApplied: true, bonusMinutes: 5, denialReason: nil,
                      itemSubjects: ["Histoire", "", "SVT", "SVT", "Histoire"], itemXP: [10, 0, 10, 15, 10])

    private let notion =
        SyncedNotion(id: UUID(), notionKey: "4e|histoire|la revolution francaise", leitnerBox: 4,
                     nextReview: QuizClock.date(day: 0, hour: 17), streakCorrect: 3,
                     lastReviewedAt: QuizClock.date(day: 0, hour: 17), masteredAt: nil)

    private var rules: SyncedRules {
        SyncedRules(config: RewardConfig(tiers: [10, 10, 5], passThreshold: 0.6, dailyCap: 30, examEveBonus: 0,
                                         examEveBonusEnabled: false, minDurationSec: 45, replayWindow: .sameDay,
                                         minQuestionCount: 4),
                    cultureQuizEnabled: true, familyChallengeEnabled: false)
    }

    // MARK: Plain records

    @Test func payloadsRoundTrip() {
        let a = attempt
        #expect(SyncedAttempt(record: a.record) == a)
        let n = notion
        #expect(SyncedNotion(record: n.record) == n)
        let j = SyncedJoker(id: UUID(), dayKey: "2026-10-17", createdAt: date)
        #expect(SyncedJoker(record: j.record) == j)
        let d = SyncedDayMinutes(day: "2026-10-18", credited: 20, pending: 5, reserve: 10)
        #expect(SyncedDayMinutes(record: d.record) == d)
        #expect(SyncedRules(record: rules.record) == rules)
    }

    @Test func attemptCarriesNoQuestionData() {
        let fields = Set(attempt.record.fields.keys)
        #expect(fields == ["v", "date", "correct", "total", "duration", "minutes", "bonusApplied", "bonusMinutes",
                           "subjects", "xp"])
        #expect(attempt.record.name.hasPrefix("attempt-"))
        #expect(attempt.record.int(FamilySyncRecord.versionField) == FamilySyncRecord.schemaVersion)
    }

    @Test func dayMinutesKeepsTotalsOnly() {
        var ledger = RewardLedger(day: "2026-10-18")
        ledger.creditedToday = 25
        ledger.pending = 5
        ledger.reserve = 10
        ledger.namesToStop = ["noto.reward.1"]
        let synced = SyncedDayMinutes(ledger: ledger)
        #expect(synced == SyncedDayMinutes(day: "2026-10-18", credited: 25, pending: 5, reserve: 10))
        #expect(Set(synced.record.fields.keys) == ["v", "day", "credited", "pending", "reserve"])
    }

    @Test func recordNamesCarryNoDateOrNotion() {
        let names = [attempt.record.name, notion.record.name,
                     SyncedJoker(id: UUID(), dayKey: "2026-10-17", createdAt: date).record.name,
                     SyncedDayMinutes(day: "2026-10-18", credited: 0, pending: 0, reserve: 0).record.name,
                     SyncedRules.recordName]
        for name in names {
            #expect(!name.contains("2026-10-1"))
            #expect(!name.contains("histoire"))
        }
    }

    @Test func badRecordsAreDropped() {
        // Wrong kind, broken name, missing required field.
        #expect(SyncedAttempt(record: notion.record) == nil)
        #expect(SyncedAttempt(record: FamilySyncRecord(kind: .attempt, name: "attempt-pas-un-uuid",
                                                       fields: attempt.record.fields)) == nil)
        var missing = attempt.record
        missing.fields["total"] = nil
        #expect(SyncedAttempt(record: missing) == nil)
        #expect(SyncedJoker(record: FamilySyncRecord(kind: .joker, name: SyncedJoker.recordName(UUID()),
                                                     fields: ["day": .string("hier"), "created": .date(date)])) == nil)
    }

    @Test func newerFieldsAreIgnoredAndRulesSanitized() {
        var record = attempt.record
        record.fields["futureField"] = .string("x")
        record.fields[FamilySyncRecord.versionField] = .int(FamilySyncRecord.schemaVersion + 1)
        #expect(SyncedAttempt(record: record) == attempt)

        let hostile = FamilySyncRecord(kind: .rules, name: SyncedRules.recordName, fields: [
            "tiers": .ints([90, 0, 10]), "threshold": .int(2), "cap": .int(-5),
        ])
        let decoded = SyncedRules(record: hostile)
        #expect(decoded?.config == RewardConfig(tiers: [90, 0, 10], passThreshold: 2, dailyCap: -5).sanitized())
        #expect(decoded?.config.passThreshold ?? 2 <= 1)
        #expect(decoded?.config.dailyCap ?? -1 >= 0)
        #expect(decoded?.cultureQuizEnabled == false)
    }

    // MARK: CKRecord

    @Test func ckRecordIsEncryptedAndRoundTrips() {
        let a = attempt
        let ck = a.record.ckRecord(in: zone)
        #expect(ck.recordType == "QuizAttempt")
        #expect(ck.recordID.recordName == a.record.name)
        #expect(ck.recordID.zoneID == zone)
        #expect(ck.encryptedValues.allKeys().contains("date"))
        #expect(FamilySyncRecord(ckRecord: ck).flatMap(SyncedAttempt.init(record:)) == a)

        let r = rules
        #expect(FamilySyncRecord(ckRecord: r.record.ckRecord(in: zone)).flatMap(SyncedRules.init(record:)) == r)
        let n = notion
        #expect(FamilySyncRecord(ckRecord: n.record.ckRecord(in: zone)).flatMap(SyncedNotion.init(record:)) == n)
    }

    @Test func applyClearsDroppedFields() {
        var withDenial = attempt.record
        withDenial.fields["denial"] = .string("tooFast")
        let ck = withDenial.ckRecord(in: zone)
        attempt.record.apply(to: ck)
        #expect(!ck.encryptedValues.allKeys().contains("denial"))
    }

    @Test func unknownRecordTypeIsIgnored() {
        let ck = CKRecord(recordType: "Futur", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        #expect(FamilySyncRecord(ckRecord: ck) == nil)
    }
}
