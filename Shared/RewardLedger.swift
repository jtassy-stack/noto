import Foundation

/// One registered `noto.reward.<uuid>` activity.
struct RewardActivity: Codable, Equatable, Sendable {
    let name: String
    /// Threshold registered with `DeviceActivityCenter`, CUMULATIVE: this
    /// activity's own credit plus the largest REMAINING balance
    /// (`thresholdMinutes - usedMinutes`) of the activities still running
    /// when it started. Reward activities all watch the same selection, so
    /// they count the same usage in parallel, not one after the other: a
    /// 5 min activity started while a 10 min one runs would fire after 5 min
    /// and re-lock too early. Stacking on what is left (not on the original
    /// threshold) avoids granting the minutes already used twice; the
    /// remaining child-favourable overestimate is below one usage milestone
    /// step (`RewardConstants.usageMilestones`) per stacked credit.
    let thresholdMinutes: Int
    /// Minutes this credit added (log and UI).
    let creditedMinutes: Int
    let startedAt: Date
    /// Usage seen so far by this activity, from its milestone events
    /// (`noto.reward.used.<n>`, recorded by the extension). Monotone.
    var usedMinutes: Int = 0

    /// Minutes this activity still lets the child use (upper bound).
    var remainingMinutes: Int { max(0, thresholdMinutes - usedMinutes) }
}

/// What happened to a reward activity, newest last (audit + manual tests).
struct RewardLogEntry: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// The extension saw the threshold: the minutes are used up.
        case thresholdReached
        /// Stopped to respect the 3-activity / 20-schedule limits; its minutes
        /// are carried by the newer activity (cumulative threshold).
        case merged
        /// Interval ended (23:59) before the threshold.
        case expired
        /// Still registered at midnight: stopped, credits reset.
        case dayReset
        /// No longer registered with `DeviceActivityCenter` (foreground check).
        case missing
    }

    let name: String
    let minutes: Int
    let date: Date
    let outcome: Outcome
}

/// Result of `RewardLedger.planUnlock`: the activity to register and the
/// older ones to stop (merged into it) so the limits hold.
struct RewardUnlockPlan: Equatable, Sendable {
    let activity: RewardActivity
    let stop: [String]
}

/// The child's reward minutes on this device, day-keyed (plan §3.4).
///
/// Lifecycle of a credit:
/// `credit` → `pending` → (during a class block) `moveToReserve` → after class
/// `releaseReserve` → `pending` → `planUnlock` + `commit` → an entry in
/// `activities` → `thresholdReached` / `expire` / merge → `log`.
///
/// Pure value type: every mutation takes `now` and a `Calendar`, and first
/// rolls over to that day (`rollOver`), so a missed midnight callback never
/// carries yesterday's minutes. Persisted by `RewardLedgerStore` in the app
/// group, compiled into the app and the extension (no app-only types).
struct RewardLedger: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` of the day the counters belong to.
    var day: String
    /// Minutes credited today (all states).
    var creditedToday: Int = 0
    /// Credited outside class, not yet unlocked (no Screen Time setup, or the
    /// daily budget is not spent yet so there is nothing to lift).
    var pending: Int = 0
    /// Credited during a class block: never consumed before the block ends.
    var reserve: Int = 0
    /// Registered reward activities, oldest first.
    var activities: [RewardActivity] = []
    /// Names left over from a previous day, to `stopMonitoring` at the next
    /// midnight callback or foreground (the extension cannot list them).
    var namesToStop: [String] = []
    var log: [RewardLogEntry] = []

    static let logRetentionDays = 7
    static let maxLogEntries = 100

    init(day: String) {
        self.day = day
    }

    init(now: Date, calendar: Calendar) {
        self.init(day: Self.dayKey(for: now, calendar: calendar))
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Read

    /// Upper bound of the minutes still unlocked right now (the largest
    /// remaining balance: the activities count the same usage in parallel).
    var unlockedMinutes: Int { activities.map(\.remainingMinutes).max() ?? 0 }

    /// Minutes still owed to the child today, whatever their state.
    var balance: Int { pending + reserve + unlockedMinutes }

    var activityNames: [String] { activities.map(\.name) }

    // MARK: - Day

    /// New day: yesterday's activities go to `namesToStop` and every counter
    /// resets (credits do not carry over, like the daily cap). Returns true
    /// when it reset.
    @discardableResult
    mutating func rollOver(now: Date, calendar: Calendar) -> Bool {
        let today = Self.dayKey(for: now, calendar: calendar)
        guard today != day else { return false }
        for activity in activities {
            appendLog(name: activity.name, minutes: activity.thresholdMinutes, date: now, outcome: .dayReset)
        }
        namesToStop = Self.unique(namesToStop + activities.map(\.name))
        activities = []
        creditedToday = 0
        pending = 0
        reserve = 0
        day = today
        trimLog(now: now)
        return true
    }

    /// Midnight callback: roll over (only if the day changed: the daily
    /// activities also start when registered mid-day) and hand back the
    /// names to stop, cleared from the ledger.
    mutating func midnightReset(now: Date, calendar: Calendar) -> (rolledOver: Bool, namesToStop: [String]) {
        let rolled = rollOver(now: now, calendar: calendar)
        let names = namesToStop
        namesToStop = []
        return (rolled, names)
    }

    // MARK: - Credit, reserve

    mutating func credit(_ minutes: Int, now: Date, calendar: Calendar) {
        rollOver(now: now, calendar: calendar)
        guard minutes > 0 else { return }
        pending += minutes
        creditedToday += minutes
    }

    /// During a class block: pending minutes wait in the reserve. Returns the
    /// minutes moved.
    @discardableResult
    mutating func moveToReserve(now: Date, calendar: Calendar) -> Int {
        rollOver(now: now, calendar: calendar)
        let moved = pending
        reserve += moved
        pending = 0
        return moved
    }

    /// After class: the reserve becomes unlockable again. Returns the minutes
    /// released.
    @discardableResult
    mutating func releaseReserve(now: Date, calendar: Calendar) -> Int {
        rollOver(now: now, calendar: calendar)
        let released = reserve
        pending += released
        reserve = 0
        return released
    }

    // MARK: - Unlock

    /// The activity to register for the pending minutes, nil when nothing is
    /// pending or no schedule slot can be freed. Does not mutate: `commit`
    /// once `startMonitoring` succeeded.
    ///
    /// - At most `maxSimultaneous` reward activities: the oldest are merged
    ///   (stopped; the cumulative threshold already carries their minutes).
    /// - `registeredActivityCount` is `DeviceActivityCenter().activities.count`;
    ///   it must stay below `appleLimit` before registering, else more of the
    ///   oldest are merged.
    func planUnlock(
        name: String,
        now: Date,
        calendar: Calendar,
        registeredActivityCount: Int,
        maxSimultaneous: Int = RewardConstants.maxSimultaneousRewardActivities,
        appleLimit: Int = RewardConstants.appleActivityLimit
    ) -> RewardUnlockPlan? {
        guard Self.dayKey(for: now, calendar: calendar) == day, pending > 0 else { return nil }
        var running = activities.sorted { $0.startedAt < $1.startedAt }
        // Stack on what is left, not on the original thresholds: usage the
        // running activities already counted is not granted a second time.
        let threshold = pending + (running.map(\.remainingMinutes).max() ?? 0)
        var stop: [String] = []

        while running.count + 1 > max(1, maxSimultaneous), !running.isEmpty {
            stop.append(running.removeFirst().name)
        }
        while registeredActivityCount - stop.count >= appleLimit, !running.isEmpty {
            stop.append(running.removeFirst().name)
        }
        guard registeredActivityCount - stop.count < appleLimit else { return nil }

        return RewardUnlockPlan(
            activity: RewardActivity(name: name, thresholdMinutes: threshold,
                                     creditedMinutes: pending, startedAt: now),
            stop: stop
        )
    }

    /// `plan` is registered: record it, drop the merged activities, empty
    /// `pending`.
    mutating func commit(_ plan: RewardUnlockPlan, now: Date, calendar: Calendar) {
        rollOver(now: now, calendar: calendar)
        let stopped = Set(plan.stop)
        for activity in activities where stopped.contains(activity.name) {
            appendLog(name: activity.name, minutes: activity.thresholdMinutes, date: now, outcome: .merged)
        }
        activities.removeAll { stopped.contains($0.name) }
        activities.append(plan.activity)
        pending = max(0, pending - plan.activity.creditedMinutes)
    }

    /// `startMonitoring` failed after `commit`: forget the new activity and
    /// give its minutes back to `pending`. Merged activities were already
    /// stopped, so what they carried comes back too (the part of the
    /// cumulative threshold no remaining activity covers).
    mutating func rollback(_ plan: RewardUnlockPlan) {
        activities.removeAll { $0.name == plan.activity.name }
        let restored = plan.stop.isEmpty
            ? plan.activity.creditedMinutes
            : max(plan.activity.creditedMinutes, plan.activity.thresholdMinutes - unlockedMinutes)
        pending += restored
    }

    // MARK: - Extension callbacks

    /// Threshold reached on a reward activity: it is used up. Returns whether
    /// the shield must be re-applied: only when no other reward activity is
    /// still running (an older one firing first must not re-lock a newer
    /// credit). An unknown name (ledger lost) re-locks when nothing is known
    /// to run, the conservative choice.
    mutating func thresholdReached(name: String, now: Date, calendar: Calendar) -> Bool {
        rollOver(now: now, calendar: calendar)
        if let index = activities.firstIndex(where: { $0.name == name }) {
            let activity = activities.remove(at: index)
            appendLog(name: name, minutes: activity.thresholdMinutes, date: now, outcome: .thresholdReached)
        }
        return activities.isEmpty
    }

    /// A usage milestone of a reward activity fired: `minutes` of its
    /// threshold are used. Monotone (a replayed or reordered callback never
    /// lowers it), clamped to the threshold; an unknown name changes nothing.
    mutating func recordUsed(name: String, minutes: Int, now: Date, calendar: Calendar) {
        rollOver(now: now, calendar: calendar)
        guard let index = activities.firstIndex(where: { $0.name == name }) else { return }
        let activity = activities[index]
        activities[index].usedMinutes = min(activity.thresholdMinutes, max(activity.usedMinutes, minutes))
    }

    /// Interval of a reward activity ended (23:59) without its threshold.
    /// Same re-lock rule; an unknown name (already merged or consumed, since
    /// `stopMonitoring` may also end the interval) changes nothing.
    mutating func expire(name: String, now: Date, calendar: Calendar) -> Bool {
        rollOver(now: now, calendar: calendar)
        guard let index = activities.firstIndex(where: { $0.name == name }) else { return false }
        let activity = activities.remove(at: index)
        appendLog(name: name, minutes: activity.thresholdMinutes, date: now, outcome: .expired)
        return activities.isEmpty
    }

    /// Foreground check: activities `DeviceActivityCenter` no longer lists
    /// (and older than `grace`, to tolerate a just-registered one) are gone.
    /// Returns how many were dropped.
    @discardableResult
    mutating func dropMissing(registered: Set<String>, now: Date, calendar: Calendar,
                              grace: TimeInterval = 60) -> Int {
        rollOver(now: now, calendar: calendar)
        let missing = activities.filter { !registered.contains($0.name) && now.timeIntervalSince($0.startedAt) > grace }
        for activity in missing {
            appendLog(name: activity.name, minutes: activity.thresholdMinutes, date: now, outcome: .missing)
        }
        let names = Set(missing.map(\.name))
        activities.removeAll { names.contains($0.name) }
        return missing.count
    }

    // MARK: - Helpers

    private mutating func appendLog(name: String, minutes: Int, date: Date, outcome: RewardLogEntry.Outcome) {
        log.append(RewardLogEntry(name: name, minutes: minutes, date: date, outcome: outcome))
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
    }

    private mutating func trimLog(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.logRetentionDays) * 86_400)
        log.removeAll { $0.date < cutoff }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

// MARK: - Lenient decoding

/// Decodes `T`, or nil instead of failing the whole array (an outcome or
/// field a newer build wrote).
private struct LenientDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Synthesized `Decodable` ignores property defaults: a field added later
/// would fail to decode every ledger stored before it and reset it. Every
/// field but the identity ones decodes with its default when absent.
extension RewardActivity {
    enum CodingKeys: String, CodingKey {
        case name, thresholdMinutes, creditedMinutes, startedAt, usedMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        thresholdMinutes = try c.decode(Int.self, forKey: .thresholdMinutes)
        creditedMinutes = try c.decodeIfPresent(Int.self, forKey: .creditedMinutes) ?? thresholdMinutes
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        usedMinutes = try c.decodeIfPresent(Int.self, forKey: .usedMinutes) ?? 0
    }
}

extension RewardLedger {
    enum CodingKeys: String, CodingKey {
        case day, creditedToday, pending, reserve, activities, namesToStop, log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(day: try c.decode(String.self, forKey: .day))
        creditedToday = try c.decodeIfPresent(Int.self, forKey: .creditedToday) ?? 0
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        reserve = try c.decodeIfPresent(Int.self, forKey: .reserve) ?? 0
        activities = (try c.decodeIfPresent([LenientDecodable<RewardActivity>].self, forKey: .activities))?
            .compactMap(\.value) ?? []
        namesToStop = try c.decodeIfPresent([String].self, forKey: .namesToStop) ?? []
        // Unknown outcomes (newer build) are dropped, not fatal.
        log = (try c.decodeIfPresent([LenientDecodable<RewardLogEntry>].self, forKey: .log))?
            .compactMap(\.value) ?? []
    }
}

/// `RewardLedger` in the app group (`group.fr.noto.app.shared`), JSON inside a
/// versioned envelope like `ScreenTimeEventStore` / `RewardConfigStore`.
///
/// Absent key, unreadable JSON or another version: a fresh ledger for today
/// (logged; a read never overwrites, the next save does), which still lists
/// every reward activity name it can salvage in `namesToStop`, so they are
/// stopped instead of orphaned. A lost ledger is otherwise safe: an unknown
/// reward activity re-locks when it reaches its threshold, and the app's
/// foreground stops reward activities the ledger does not know.
///
/// The app and the extension read-modify-write it from two processes, with
/// no cross-process lock: writers keep load → save windows short and save
/// only what they changed (`RewardEngine.unlockPending`).
enum RewardLedgerStore {
    static let key = "noto_reward_ledger"

    struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let ledger: RewardLedger
    }

    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: ScreenTimeEventStore.appGroupID) }

    static func load(defaults: UserDefaults? = appGroupDefaults, now: Date = .now,
                     calendar: Calendar = .current) -> RewardLedger {
        let fresh = RewardLedger(now: now, calendar: calendar)
        guard let defaults else {
            NSLog("[noto][error] RewardLedgerStore: app group defaults unavailable")
            return fresh
        }
        guard let data = defaults.data(forKey: key) else { return fresh }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Envelope.currentVersion else {
                NSLog("[noto][error] RewardLedgerStore: stored version %d != %d — fresh ledger",
                      envelope.version, Envelope.currentVersion)
                return salvaged(fresh, from: data)
            }
            return envelope.ledger
        } catch {
            NSLog("[noto][error] RewardLedgerStore: decode failed — %@", error.localizedDescription)
            return salvaged(fresh, from: data)
        }
    }

    /// The reward activity names an unreadable or other-version ledger still
    /// carries, queued in `namesToStop` of the fresh one.
    private static func salvaged(_ fresh: RewardLedger, from data: Data) -> RewardLedger {
        struct NamedActivity: Decodable { let name: String }
        struct Names: Decodable {
            let activities: [LenientDecodable<NamedActivity>]?
            let namesToStop: [String]?
        }
        struct NamesEnvelope: Decodable { let ledger: Names }
        guard let names = try? JSONDecoder().decode(NamesEnvelope.self, from: data).ledger else { return fresh }
        let all = (names.activities ?? []).compactMap { $0.value?.name } + (names.namesToStop ?? [])
        var ledger = fresh
        var seen = Set<String>()
        ledger.namesToStop = all.filter { RewardConstants.isRewardActivity($0) && seen.insert($0).inserted }
        return ledger
    }

    static func save(_ ledger: RewardLedger, defaults: UserDefaults? = appGroupDefaults) {
        guard let defaults else { return }
        do {
            let envelope = Envelope(version: Envelope.currentVersion, ledger: ledger)
            defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        } catch {
            NSLog("[noto][error] RewardLedgerStore: encode failed — %@", error.localizedDescription)
        }
    }

    /// Load, mutate, save.
    @discardableResult
    static func update<T>(defaults: UserDefaults? = appGroupDefaults, now: Date = .now,
                          calendar: Calendar = .current, _ body: (inout RewardLedger) -> T) -> T {
        var ledger = load(defaults: defaults, now: now, calendar: calendar)
        let result = body(&ledger)
        save(ledger, defaults: defaults)
        return result
    }
}
