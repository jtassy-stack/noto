import Foundation
import SwiftData

/// Family sync (phase 9.3): between the local models and the synced
/// records, without CloudKit. The child's device turns its quizzes, notions,
/// jokers and day minutes into records (`FamilySyncOutbox`); the parent's
/// device writes the received ones into the same models under its own
/// `Child` (`FamilySyncIngest`), so the parent screens fill as they are; the
/// child's device applies the parent's rules (`FamilySyncRulesApplier`).

// MARK: - Local → record

extension SyncedAttempt {
    init(attempt: QuizAttempt) {
        self.init(id: attempt.id, date: attempt.date, correctCount: attempt.correctCount,
                  totalCount: attempt.totalCount, durationSec: attempt.durationSec,
                  minutesEarned: attempt.minutesEarned, bonusApplied: attempt.bonusApplied,
                  bonusMinutes: attempt.bonusMinutes, denialReason: attempt.denialReason,
                  itemSubjects: attempt.itemSubjects, itemXP: attempt.itemXP)
    }
}

extension SyncedNotion {
    init(mastery: NotionMastery) {
        self.init(id: mastery.id, notionKey: mastery.notionKey, leitnerBox: mastery.leitnerBox,
                  nextReview: mastery.nextReview, streakCorrect: mastery.streakCorrect,
                  lastReviewedAt: mastery.lastReviewedAt, masteredAt: mastery.masteredAt)
    }
}

extension SyncedJoker {
    init(joker: StreakJoker) {
        self.init(id: joker.id, dayKey: joker.dayKey, createdAt: joker.createdAt)
    }
}

extension SyncedRules {
    /// This device's rules, as the parent set them in Réglages › Révisions.
    static func current(defaults: UserDefaults? = RewardConfigStore.appGroupDefaults) -> SyncedRules {
        SyncedRules(config: RewardConfigStore.load(defaults: defaults),
                    cultureQuizEnabled: CultureQuestionSettings.isEnabled(defaults: defaults),
                    familyChallengeEnabled: FamilyChallengeSettings.isEnabled(defaults: defaults))
    }
}

extension FamilySyncRecord {
    /// Stable text of the record's content: the outbox sends a record again
    /// only when it changed since the last successful send.
    var fingerprint: String {
        let parts = fields.keys.sorted().map { key -> String in
            let value: String
            switch fields[key]! {
            case .int(let v): value = "i\(v)"
            case .double(let v): value = "d\(v.bitPattern)"
            case .string(let v): value = "s\(v)"
            case .date(let v): value = "t\(v.timeIntervalSinceReferenceDate.bitPattern)"
            case .ints(let v): value = "I" + v.map(String.init).joined(separator: ",")
            case .strings(let v): value = "S" + v.map { "\($0.count):\($0)" }.joined()
            }
            return "\(key)=\(value)"
        }
        return kind.rawValue + "|" + name + "|" + parts.joined(separator: ";")
    }
}

// MARK: - Outbox

enum FamilySyncOutbox {
    /// Everything the child's device shares, from its own models.
    static func childRecords(for child: Child, ledger: RewardLedger) -> [FamilySyncRecord] {
        child.quizAttempts.map { SyncedAttempt(attempt: $0).record }
            + child.notionMasteries.map { SyncedNotion(mastery: $0).record }
            + child.streakJokers.map { SyncedJoker(joker: $0).record }
            + [SyncedDayMinutes(ledger: ledger).record]
    }

    /// The records whose content differs from what was last sent.
    static func pending(_ records: [FamilySyncRecord], sent: [String: String]) -> [FamilySyncRecord] {
        records.filter { sent[$0.name] != $0.fingerprint }
    }
}

// MARK: - Ingest (parent side)

@MainActor
enum FamilySyncIngest {
    struct Result: Equatable {
        var attempts = 0
        var notions = 0
        var jokers = 0
        var minutes: SyncedDayMinutes?

        var isEmpty: Bool { attempts == 0 && notions == 0 && jokers == 0 && minutes == nil }
    }

    /// Writes the child's records under the parent's `Child`, matched by id:
    /// a quiz or joker already there is left as it is, a notion is updated.
    /// Rules records (the parent's own) and anything unreadable are skipped.
    @discardableResult
    static func apply(_ records: [FamilySyncRecord], to child: Child, context: ModelContext) -> Result {
        var result = Result()
        var attemptIDs = Set(child.quizAttempts.map(\.id))
        var jokerIDs = Set(child.streakJokers.map(\.id))
        var notions = Dictionary(child.notionMasteries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for record in records {
            switch record.kind {
            case .attempt:
                guard let synced = SyncedAttempt(record: record), !attemptIDs.contains(synced.id) else { continue }
                // No item ids, answers or question keys: they stay on the
                // child's device. `itemSubjects` and `itemXP` keep their order.
                let attempt = QuizAttempt(
                    id: synced.id, child: child, date: synced.date, itemIDs: [], questionKeys: [], answers: [],
                    correctCount: synced.correctCount, totalCount: synced.totalCount,
                    durationSec: synced.durationSec, minutesEarned: synced.minutesEarned,
                    bonusApplied: synced.bonusApplied, bonusMinutes: synced.bonusMinutes,
                    denialReason: synced.denialReason, itemSubjects: synced.itemSubjects, itemXP: synced.itemXP)
                context.insert(attempt)
                attemptIDs.insert(synced.id)
                result.attempts += 1
            case .notion:
                guard let synced = SyncedNotion(record: record) else { continue }
                let mastery: NotionMastery
                if let existing = notions[synced.id] {
                    mastery = existing
                } else {
                    mastery = NotionMastery(child: child, notionKey: synced.notionKey, now: synced.nextReview,
                                            calendar: .current)
                    mastery.id = synced.id
                    context.insert(mastery)
                    notions[synced.id] = mastery
                }
                mastery.notionKey = synced.notionKey
                mastery.leitnerBox = synced.leitnerBox
                mastery.nextReview = synced.nextReview
                mastery.streakCorrect = synced.streakCorrect
                mastery.lastReviewedAt = synced.lastReviewedAt
                mastery.masteredAt = synced.masteredAt
                result.notions += 1
            case .joker:
                guard let synced = SyncedJoker(record: record), !jokerIDs.contains(synced.id),
                      let day = CalendarDay(key: synced.dayKey) else { continue }
                let joker = StreakJoker(child: child, day: day, createdAt: synced.createdAt)
                joker.id = synced.id
                context.insert(joker)
                jokerIDs.insert(synced.id)
                result.jokers += 1
            case .dayMinutes:
                if let synced = SyncedDayMinutes(record: record) { result.minutes = synced }
            case .rules:
                continue
            }
        }
        return result
    }
}

// MARK: - Rules (child side)

enum FamilySyncRulesApplier {
    /// The parent's rules replace this device's. Returns false when the
    /// record is not a rules record.
    @discardableResult
    static func apply(_ record: FamilySyncRecord,
                      defaults: UserDefaults? = RewardConfigStore.appGroupDefaults) -> Bool {
        guard let rules = SyncedRules(record: record) else { return false }
        RewardConfigStore.save(rules.config, defaults: defaults)
        CultureQuestionSettings.setEnabled(rules.cultureQuizEnabled, defaults: defaults)
        FamilyChallengeSettings.setEnabled(rules.familyChallengeEnabled, defaults: defaults)
        return true
    }
}

// MARK: - Local sync state

/// What each device remembers between syncs, per zone: the CloudKit change
/// token and the fingerprints of the records sent. Parent side, the child's
/// latest day minutes. In UserDefaults: none of it is a credential, and zone
/// names are opaque.
struct FamilySyncStateStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ kind: String, _ zoneName: String) -> String { "familySync.\(kind).\(zoneName)" }

    func sent(zoneName: String) -> [String: String] {
        defaults.dictionary(forKey: key("sent", zoneName)) as? [String: String] ?? [:]
    }

    func markSent(_ records: [FamilySyncRecord], zoneName: String) {
        var sent = sent(zoneName: zoneName)
        for record in records { sent[record.name] = record.fingerprint }
        defaults.set(sent, forKey: key("sent", zoneName))
    }

    func changeToken(zoneName: String) -> Data? {
        defaults.data(forKey: key("token", zoneName))
    }

    func setChangeToken(_ data: Data?, zoneName: String) {
        defaults.set(data, forKey: key("token", zoneName))
    }

    func receivedMinutes(zoneName: String) -> SyncedDayMinutes? {
        guard let values = defaults.dictionary(forKey: key("minutes", zoneName)),
              let day = values["day"] as? String,
              let credited = values["credited"] as? Int else { return nil }
        return SyncedDayMinutes(day: day, credited: credited, pending: values["pending"] as? Int ?? 0,
                                reserve: values["reserve"] as? Int ?? 0)
    }

    func setReceivedMinutes(_ minutes: SyncedDayMinutes, zoneName: String) {
        defaults.set(["day": minutes.day, "credited": minutes.credited, "pending": minutes.pending,
                      "reserve": minutes.reserve], forKey: key("minutes", zoneName))
    }

    /// Unlinked: forget everything about the zone.
    func clear(zoneName: String) {
        for kind in ["sent", "token", "minutes"] { defaults.removeObject(forKey: key(kind, zoneName)) }
    }
}
