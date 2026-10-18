import Foundation

/// Family sync (phase 9): what crosses from the child's device to the parent's
/// and back, as plain records. Pure: no CloudKit here, the CKRecord adapter
/// is `FamilySyncRecord+CloudKit.swift`. Every record has a single writer
/// (the child for attempts, notions, jokers and day minutes, the parent for
/// the rules), so the engine never merges: last write wins.
///
/// Privacy: only results. Never credentials, messages, grades, timetable,
/// cahier de textes, photos, question texts or question keys (the anti-replay
/// hashes stay on the child's device, where the anti-cheat runs). See
/// `/mnt/project-files/sync-famille/CADRAGE.md`.
struct FamilySyncRecord: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        /// Child → parent.
        case attempt = "QuizAttempt"
        case notion = "NotionMastery"
        case joker = "StreakJoker"
        case dayMinutes = "DayMinutes"
        /// Parent → child.
        case rules = "RewardRules"
    }

    enum Value: Sendable, Equatable {
        case int(Int)
        case double(Double)
        case string(String)
        case date(Date)
        case ints([Int])
        case strings([String])
    }

    /// Bumped when a field changes meaning. A decoder reads any version and
    /// ignores the fields it does not know; a record missing a required field
    /// is dropped.
    static let schemaVersion = 1
    static let versionField = "v"

    let kind: Kind
    /// Unique within the child's zone, ASCII: « attempt-<uuid> »,
    /// « joker-2026-10-18 », « rules »…
    let name: String
    var fields: [String: Value]

    init(kind: Kind, name: String, fields: [String: Value]) {
        self.kind = kind
        self.name = name
        var all = fields
        all[Self.versionField] = .int(Self.schemaVersion)
        self.fields = all
    }

    /// As read back from storage: the fields as they are, version included.
    init(kind: Kind, name: String, decodedFields: [String: Value]) {
        self.kind = kind
        self.name = name
        self.fields = decodedFields
    }

    func int(_ key: String) -> Int? {
        if case .int(let v) = fields[key] { return v }
        return nil
    }

    func double(_ key: String) -> Double? {
        switch fields[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    func string(_ key: String) -> String? {
        if case .string(let v) = fields[key] { return v }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let v) = fields[key] { return v }
        return nil
    }

    func bool(_ key: String) -> Bool? { int(key).map { $0 != 0 } }

    func ints(_ key: String) -> [Int]? {
        if case .ints(let v) = fields[key] { return v }
        return nil
    }

    func strings(_ key: String) -> [String]? {
        if case .strings(let v) = fields[key] { return v }
        return nil
    }
}

// MARK: - Payloads

/// One quiz played, as the parent sees it. No item ids, answers or question
/// keys.
struct SyncedAttempt: Sendable, Equatable {
    let id: UUID
    let date: Date
    let correctCount: Int
    let totalCount: Int
    let durationSec: Int
    let minutesEarned: Int
    let bonusApplied: Bool
    let bonusMinutes: Int
    /// `RewardDenial` raw value.
    let denialReason: String?
    let itemSubjects: [String]
    let itemXP: [Int]

    var record: FamilySyncRecord {
        var fields: [String: FamilySyncRecord.Value] = [
            "date": .date(date),
            "correct": .int(correctCount),
            "total": .int(totalCount),
            "duration": .int(durationSec),
            "minutes": .int(minutesEarned),
            "bonusApplied": .int(bonusApplied ? 1 : 0),
            "bonusMinutes": .int(bonusMinutes),
            "subjects": .strings(itemSubjects),
            "xp": .ints(itemXP),
        ]
        if let denialReason { fields["denial"] = .string(denialReason) }
        return FamilySyncRecord(kind: .attempt, name: Self.recordName(id), fields: fields)
    }

    static func recordName(_ id: UUID) -> String { "attempt-\(id.uuidString)" }

    init(id: UUID, date: Date, correctCount: Int, totalCount: Int, durationSec: Int, minutesEarned: Int,
         bonusApplied: Bool, bonusMinutes: Int, denialReason: String?, itemSubjects: [String], itemXP: [Int]) {
        self.id = id
        self.date = date
        self.correctCount = correctCount
        self.totalCount = totalCount
        self.durationSec = durationSec
        self.minutesEarned = minutesEarned
        self.bonusApplied = bonusApplied
        self.bonusMinutes = bonusMinutes
        self.denialReason = denialReason
        self.itemSubjects = itemSubjects
        self.itemXP = itemXP
    }

    init?(record: FamilySyncRecord) {
        guard record.kind == .attempt,
              let id = UUID(uuidString: String(record.name.dropFirst("attempt-".count))),
              record.name == Self.recordName(id),
              let date = record.date("date"),
              let correct = record.int("correct"),
              let total = record.int("total"),
              let minutes = record.int("minutes") else { return nil }
        self.init(id: id, date: date, correctCount: correct, totalCount: total,
                  durationSec: record.int("duration") ?? 0, minutesEarned: minutes,
                  bonusApplied: record.bool("bonusApplied") ?? false,
                  bonusMinutes: record.int("bonusMinutes") ?? 0,
                  denialReason: record.string("denial"),
                  itemSubjects: record.strings("subjects") ?? [],
                  itemXP: record.ints("xp") ?? [])
    }
}

/// Leitner state of one notion. Named by the child's `NotionMastery.id`
/// (stable per notion); the key travels as a field.
struct SyncedNotion: Sendable, Equatable {
    let id: UUID
    let notionKey: String
    let leitnerBox: Int
    let nextReview: Date
    let streakCorrect: Int
    let lastReviewedAt: Date?
    let masteredAt: Date?

    var record: FamilySyncRecord {
        var fields: [String: FamilySyncRecord.Value] = [
            "key": .string(notionKey),
            "box": .int(leitnerBox),
            "next": .date(nextReview),
            "streak": .int(streakCorrect),
        ]
        if let lastReviewedAt { fields["last"] = .date(lastReviewedAt) }
        if let masteredAt { fields["mastered"] = .date(masteredAt) }
        return FamilySyncRecord(kind: .notion, name: Self.recordName(id), fields: fields)
    }

    static func recordName(_ id: UUID) -> String { "notion-\(id.uuidString)" }

    init(id: UUID, notionKey: String, leitnerBox: Int, nextReview: Date, streakCorrect: Int,
         lastReviewedAt: Date?, masteredAt: Date?) {
        self.id = id
        self.notionKey = notionKey
        self.leitnerBox = leitnerBox
        self.nextReview = nextReview
        self.streakCorrect = streakCorrect
        self.lastReviewedAt = lastReviewedAt
        self.masteredAt = masteredAt
    }

    init?(record: FamilySyncRecord) {
        guard record.kind == .notion,
              let id = UUID(uuidString: String(record.name.dropFirst("notion-".count))),
              record.name == Self.recordName(id),
              let key = record.string("key"), !key.isEmpty,
              let box = record.int("box"),
              let next = record.date("next") else { return nil }
        self.init(id: id, notionKey: key, leitnerBox: min(max(box, 1), 5), nextReview: next,
                  streakCorrect: record.int("streak") ?? 0, lastReviewedAt: record.date("last"),
                  masteredAt: record.date("mastered"))
    }
}

/// A série joker: the covered day only (`CalendarDay.key`).
struct SyncedJoker: Sendable, Equatable {
    let dayKey: String
    let createdAt: Date

    var record: FamilySyncRecord {
        FamilySyncRecord(kind: .joker, name: Self.recordName(dayKey), fields: ["created": .date(createdAt)])
    }

    static func recordName(_ dayKey: String) -> String { "joker-\(dayKey)" }

    init(dayKey: String, createdAt: Date) {
        self.dayKey = dayKey
        self.createdAt = createdAt
    }

    init?(record: FamilySyncRecord) {
        let dayKey = String(record.name.dropFirst("joker-".count))
        guard record.kind == .joker, record.name == Self.recordName(dayKey), CalendarDay(key: dayKey) != nil,
              let created = record.date("created") else { return nil }
        self.init(dayKey: dayKey, createdAt: created)
    }
}

/// The day's reward counters (`RewardLedger`), for « Bonus du jour ». Totals
/// only: no activity names, no log.
struct SyncedDayMinutes: Sendable, Equatable {
    /// `RewardLedger.day`, « yyyy-MM-dd ».
    let day: String
    let credited: Int
    let pending: Int
    let reserve: Int

    var record: FamilySyncRecord {
        FamilySyncRecord(kind: .dayMinutes, name: Self.recordName(day), fields: [
            "credited": .int(credited),
            "pending": .int(pending),
            "reserve": .int(reserve),
        ])
    }

    static func recordName(_ day: String) -> String { "day-\(day)" }

    init(day: String, credited: Int, pending: Int, reserve: Int) {
        self.day = day
        self.credited = credited
        self.pending = pending
        self.reserve = reserve
    }

    init(ledger: RewardLedger) {
        self.init(day: ledger.day, credited: ledger.creditedToday, pending: ledger.pending, reserve: ledger.reserve)
    }

    init?(record: FamilySyncRecord) {
        let day = String(record.name.dropFirst("day-".count))
        guard record.kind == .dayMinutes, record.name == Self.recordName(day), CalendarDay(key: day) != nil,
              let credited = record.int("credited") else { return nil }
        self.init(day: day, credited: credited, pending: record.int("pending") ?? 0,
                  reserve: record.int("reserve") ?? 0)
    }
}

/// The parent's rules for one child: the barème (`RewardConfig`) and the
/// two toggles of « Révisions & récompenses ». One record per zone.
struct SyncedRules: Sendable, Equatable {
    let config: RewardConfig
    let cultureQuizEnabled: Bool
    let familyChallengeEnabled: Bool

    static let recordName = "rules"

    var record: FamilySyncRecord {
        FamilySyncRecord(kind: .rules, name: Self.recordName, fields: [
            "tiers": .ints(config.tiers),
            "threshold": .double(config.passThreshold),
            "cap": .int(config.dailyCap),
            "eveBonus": .int(config.examEveBonus),
            "eveBonusOn": .int(config.examEveBonusEnabled ? 1 : 0),
            "minDuration": .int(config.minDurationSec),
            "replay": .string(config.replayWindow.rawValue),
            "minQuestions": .int(config.minQuestionCount),
            "culture": .int(cultureQuizEnabled ? 1 : 0),
            "challenge": .int(familyChallengeEnabled ? 1 : 0),
        ])
    }

    init(config: RewardConfig, cultureQuizEnabled: Bool, familyChallengeEnabled: Bool) {
        self.config = config
        self.cultureQuizEnabled = cultureQuizEnabled
        self.familyChallengeEnabled = familyChallengeEnabled
    }

    /// A missing field keeps the default, like `RewardConfig`'s decoder; the
    /// result is sanitized, so a bad record can never make every quiz
    /// unwinnable.
    init?(record: FamilySyncRecord) {
        guard record.kind == .rules, record.name == Self.recordName else { return nil }
        let d = RewardConfig.default
        let config = RewardConfig(
            tiers: record.ints("tiers") ?? d.tiers,
            passThreshold: record.double("threshold") ?? d.passThreshold,
            dailyCap: record.int("cap") ?? d.dailyCap,
            examEveBonus: record.int("eveBonus") ?? d.examEveBonus,
            examEveBonusEnabled: record.bool("eveBonusOn") ?? d.examEveBonusEnabled,
            minDurationSec: record.int("minDuration") ?? d.minDurationSec,
            replayWindow: record.string("replay").flatMap(ReplayWindow.init(rawValue:)) ?? d.replayWindow,
            minQuestionCount: record.int("minQuestions") ?? d.minQuestionCount)
        self.init(config: config.sanitized(), cultureQuizEnabled: record.bool("culture") ?? false,
                  familyChallengeEnabled: record.bool("challenge") ?? false)
    }
}
