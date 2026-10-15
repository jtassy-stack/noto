import Testing
import Foundation
@testable import Noto

/// `RewardLedger` (pure mutations) and `RewardLedgerStore` (versioned
/// envelope on a private suite).
@Suite("RewardLedger")
struct RewardLedgerTests {
    let calendar = RewardClock.calendar
    let morning = RewardClock.date(hour: 10)

    private func ledger(at date: Date? = nil) -> RewardLedger {
        RewardLedger(now: date ?? morning, calendar: calendar)
    }

    /// Credits `minutes`, plans and commits one activity at `date`.
    @discardableResult
    private func unlock(_ ledger: inout RewardLedger, minutes: Int, at date: Date,
                        name: String = RewardConstants.activityName(), registered: Int = 2) -> RewardUnlockPlan? {
        ledger.credit(minutes, now: date, calendar: calendar)
        guard let plan = ledger.planUnlock(name: name, now: date, calendar: calendar,
                                           registeredActivityCount: registered) else { return nil }
        ledger.commit(plan, now: date, calendar: calendar)
        return plan
    }

    // MARK: Credit, reserve

    @Test("credit adds to pending and to today's total; zero or negative is ignored")
    func credit() {
        var l = ledger()
        l.credit(10, now: morning, calendar: calendar)
        l.credit(0, now: morning, calendar: calendar)
        l.credit(-5, now: morning, calendar: calendar)
        #expect(l.pending == 10)
        #expect(l.creditedToday == 10)
        #expect(l.balance == 10)
        #expect(l.day == "2026-10-14")
    }

    @Test("reserve: pending moves in during class and back out after")
    func reserve() {
        var l = ledger()
        l.credit(10, now: morning, calendar: calendar)
        #expect(l.moveToReserve(now: morning, calendar: calendar) == 10)
        #expect(l.pending == 0)
        #expect(l.reserve == 10)
        #expect(l.balance == 10)
        // Nothing to unlock while in reserve.
        #expect(l.planUnlock(name: "noto.reward.x", now: morning, calendar: calendar,
                             registeredActivityCount: 1) == nil)
        #expect(l.releaseReserve(now: morning, calendar: calendar) == 10)
        #expect(l.reserve == 0)
        #expect(l.pending == 10)
    }

    // MARK: Unlock, consume

    @Test("unlock registers the pending minutes and empties pending")
    func unlockOne() throws {
        var l = ledger()
        let plan = try #require(unlock(&l, minutes: 10, at: morning, name: "noto.reward.a"))
        #expect(plan.stop.isEmpty)
        #expect(plan.activity == RewardActivity(name: "noto.reward.a", thresholdMinutes: 10,
                                                creditedMinutes: 10, startedAt: morning))
        #expect(l.pending == 0)
        #expect(l.activities.map(\.name) == ["noto.reward.a"])
        #expect(l.unlockedMinutes == 10)
        #expect(l.balance == 10)
    }

    @Test("a second credit while one runs gets a cumulative threshold")
    func cumulative() throws {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        let plan = try #require(unlock(&l, minutes: 5, at: morning.addingTimeInterval(600), name: "noto.reward.b"))
        #expect(plan.activity.thresholdMinutes == 15)
        #expect(plan.activity.creditedMinutes == 5)
        #expect(l.unlockedMinutes == 15)
    }

    @Test("threshold: re-lock only once the last running reward is used up")
    func thresholdRelocksOnLast() {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        unlock(&l, minutes: 5, at: morning.addingTimeInterval(600), name: "noto.reward.b")
        let later = morning.addingTimeInterval(1200)
        #expect(l.thresholdReached(name: "noto.reward.a", now: later, calendar: calendar) == false)
        #expect(l.thresholdReached(name: "noto.reward.b", now: later, calendar: calendar) == true)
        #expect(l.activities.isEmpty)
        #expect(l.log.map(\.outcome) == [.thresholdReached, .thresholdReached])
        #expect(l.balance == 0)
    }

    @Test("unknown threshold name re-locks only when nothing is known to run")
    func unknownThreshold() {
        var empty = ledger()
        #expect(empty.thresholdReached(name: "noto.reward.lost", now: morning, calendar: calendar) == true)

        var running = ledger()
        unlock(&running, minutes: 10, at: morning, name: "noto.reward.a")
        #expect(running.thresholdReached(name: "noto.reward.lost", now: morning, calendar: calendar) == false)
        #expect(running.activities.count == 1)
    }

    @Test("interval end expires the activity; an unknown (merged) name changes nothing")
    func expire() {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        let night = RewardClock.date(hour: 23, minute: 59)
        #expect(l.expire(name: "noto.reward.merged", now: night, calendar: calendar) == false)
        #expect(l.activities.count == 1)
        #expect(l.expire(name: "noto.reward.a", now: night, calendar: calendar) == true)
        #expect(l.log.last?.outcome == .expired)
    }

    // MARK: Limits

    @Test("a 4th reward merges the oldest: at most 3 run at once")
    func capMerge() throws {
        var l = ledger()
        for (index, name) in ["a", "b", "c"].enumerated() {
            unlock(&l, minutes: 5, at: morning.addingTimeInterval(Double(index) * 60), name: "noto.reward.\(name)")
        }
        #expect(l.activities.count == 3)
        #expect(l.unlockedMinutes == 15)

        let plan = try #require(unlock(&l, minutes: 5, at: morning.addingTimeInterval(300), name: "noto.reward.d"))
        #expect(plan.stop == ["noto.reward.a"])
        #expect(plan.activity.thresholdMinutes == 20)
        #expect(l.activities.map(\.name) == ["noto.reward.b", "noto.reward.c", "noto.reward.d"])
        #expect(l.log.last == RewardLogEntry(name: "noto.reward.a", minutes: 5,
                                             date: morning.addingTimeInterval(300), outcome: .merged))
    }

    @Test("near the 20-schedule limit more of the oldest are merged; none left → no plan")
    func appleLimit() {
        var l = ledger()
        unlock(&l, minutes: 5, at: morning, name: "noto.reward.a")
        unlock(&l, minutes: 5, at: morning.addingTimeInterval(60), name: "noto.reward.b")
        l.credit(5, now: morning, calendar: calendar)

        // 20 registered: one must go to get below 20 before registering.
        let plan = l.planUnlock(name: "noto.reward.c", now: morning, calendar: calendar, registeredActivityCount: 20)
        #expect(plan?.stop == ["noto.reward.a"])
        #expect(plan?.activity.thresholdMinutes == 15)

        // 21 registered (stale outside rewards): both merged.
        let both = l.planUnlock(name: "noto.reward.c", now: morning, calendar: calendar, registeredActivityCount: 21)
        #expect(both?.stop == ["noto.reward.a", "noto.reward.b"])

        // Full with no reward to merge: nothing can be registered.
        var fresh = ledger()
        fresh.credit(5, now: morning, calendar: calendar)
        #expect(fresh.planUnlock(name: "noto.reward.x", now: morning, calendar: calendar,
                                 registeredActivityCount: 20) == nil)
        #expect(fresh.planUnlock(name: "noto.reward.x", now: morning, calendar: calendar,
                                 registeredActivityCount: 19) != nil)
    }

    @Test("rollback after a failed startMonitoring gives the minutes back")
    func rollback() throws {
        var l = ledger()
        l.credit(10, now: morning, calendar: calendar)
        let plan = try #require(l.planUnlock(name: "noto.reward.a", now: morning, calendar: calendar,
                                             registeredActivityCount: 1))
        l.commit(plan, now: morning, calendar: calendar)
        l.rollback(plan)
        #expect(l.activities.isEmpty)
        #expect(l.pending == 10)

        // With a merge: the stopped activity's minutes come back as well.
        var m = ledger()
        unlock(&m, minutes: 5, at: morning, name: "noto.reward.a")
        m.credit(5, now: morning, calendar: calendar)
        let merging = try #require(m.planUnlock(name: "noto.reward.b", now: morning, calendar: calendar,
                                                registeredActivityCount: 1, maxSimultaneous: 1))
        #expect(merging.stop == ["noto.reward.a"])
        m.commit(merging, now: morning, calendar: calendar)
        m.rollback(merging)
        #expect(m.activities.isEmpty)
        #expect(m.pending == 10)
    }

    @Test("dropMissing removes activities the center no longer lists, after a grace period")
    func dropMissing() {
        var l = ledger()
        unlock(&l, minutes: 5, at: morning, name: "noto.reward.a")
        #expect(l.dropMissing(registered: [], now: morning.addingTimeInterval(30), calendar: calendar) == 0)
        #expect(l.dropMissing(registered: ["noto.reward.a"], now: morning.addingTimeInterval(600),
                              calendar: calendar) == 0)
        #expect(l.dropMissing(registered: [], now: morning.addingTimeInterval(600), calendar: calendar) == 1)
        #expect(l.log.last?.outcome == .missing)
    }

    // MARK: Day

    @Test("midnight reset: credits cleared, yesterday's names handed back once")
    func midnight() {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        l.credit(5, now: morning, calendar: calendar)
        _ = l.moveToReserve(now: morning, calendar: calendar)

        // Same day (daily activity registered mid-day): nothing happens.
        let sameDay = l.midnightReset(now: RewardClock.date(hour: 15), calendar: calendar)
        #expect(sameDay.rolledOver == false)
        #expect(sameDay.namesToStop.isEmpty)
        #expect(l.reserve == 5)

        let midnight = RewardClock.date(day: 1, hour: 0, minute: 0, second: 5)
        let reset = l.midnightReset(now: midnight, calendar: calendar)
        #expect(reset.rolledOver)
        #expect(reset.namesToStop == ["noto.reward.a"])
        #expect(l.day == "2026-10-15")
        #expect(l.balance == 0)
        #expect(l.creditedToday == 0)
        #expect(l.activities.isEmpty)
        #expect(l.namesToStop.isEmpty)
        #expect(l.log.last?.outcome == .dayReset)

        #expect(l.midnightReset(now: midnight, calendar: calendar).namesToStop.isEmpty)
    }

    @Test("any mutation on a new day starts from zero (missed midnight callback)")
    func lazyRollOver() {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        l.credit(5, now: morning, calendar: calendar)
        let tomorrow = RewardClock.date(day: 1, hour: 9)
        l.credit(5, now: tomorrow, calendar: calendar)
        #expect(l.pending == 5)
        #expect(l.creditedToday == 5)
        #expect(l.activities.isEmpty)
        #expect(l.namesToStop == ["noto.reward.a"])
        // A plan for a stale ledger day is refused.
        var stale = ledger()
        stale.credit(5, now: morning, calendar: calendar)
        #expect(stale.planUnlock(name: "noto.reward.x", now: tomorrow, calendar: calendar,
                                 registeredActivityCount: 1) == nil)
    }

    // MARK: Store

    @Test("store: absent key → fresh ledger for today")
    func storeAbsent() {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        #expect(RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar) == ledger())
        #expect(RewardLedgerStore.load(defaults: nil, now: morning, calendar: calendar) == ledger())
    }

    @Test("store: round-trip inside a versioned envelope")
    func storeRoundTrip() throws {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        l.credit(5, now: morning, calendar: calendar)
        RewardLedgerStore.save(l, defaults: defaults)
        #expect(RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar) == l)

        let data = try #require(defaults.data(forKey: RewardLedgerStore.key))
        let envelope = try JSONDecoder().decode(RewardLedgerStore.Envelope.self, from: data)
        #expect(envelope.version == RewardLedgerStore.Envelope.currentVersion)
    }

    @Test("store: another version or corrupt data → safe defaults, data left in place")
    func storeVersionMismatch() throws {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        var l = ledger()
        l.credit(10, now: morning, calendar: calendar)
        let future = RewardLedgerStore.Envelope(version: RewardLedgerStore.Envelope.currentVersion + 1, ledger: l)
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: RewardLedgerStore.key)
        #expect(RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar) == ledger())
        #expect(defaults.data(forKey: RewardLedgerStore.key) == futureData)

        defaults.set(Data("not json".utf8), forKey: RewardLedgerStore.key)
        #expect(RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar) == ledger())
    }

    @Test("store: update loads, mutates and saves")
    func storeUpdate() {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        let released = RewardLedgerStore.update(defaults: defaults, now: morning, calendar: calendar) { l -> Int in
            l.credit(7, now: morning, calendar: calendar)
            l.moveToReserve(now: morning, calendar: calendar)
            return l.releaseReserve(now: morning, calendar: calendar)
        }
        #expect(released == 7)
        #expect(RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar).pending == 7)
    }

    // MARK: Stacking on what is left

    @Test("a credit stacked on a running reward counts only its remaining minutes")
    func stackOnRemaining() throws {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        l.recordUsed(name: "noto.reward.a", minutes: 9, now: morning, calendar: calendar)
        #expect(l.unlockedMinutes == 1)
        let plan = try #require(unlock(&l, minutes: 5, at: morning.addingTimeInterval(600), name: "noto.reward.b"))
        #expect(plan.activity.thresholdMinutes == 6)
        #expect(l.unlockedMinutes == 6)
    }

    @Test("recorded usage is monotone, clamped, and ignores unknown names")
    func recordUsed() {
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        l.recordUsed(name: "noto.reward.a", minutes: 6, now: morning, calendar: calendar)
        l.recordUsed(name: "noto.reward.a", minutes: 3, now: morning, calendar: calendar)
        #expect(l.activities.first?.usedMinutes == 6)
        l.recordUsed(name: "noto.reward.a", minutes: 40, now: morning, calendar: calendar)
        #expect(l.activities.first?.usedMinutes == 10)
        let before = l
        l.recordUsed(name: "noto.reward.lost", minutes: 3, now: morning, calendar: calendar)
        #expect(l == before)
    }

    @Test("usage milestones: parsed back, at most 20, below the threshold")
    func milestones() {
        #expect(RewardConstants.usedMinutes(fromEventName: RewardConstants.usageEventName(minutes: 7)) == 7)
        #expect(RewardConstants.usedMinutes(fromEventName: RewardConstants.thresholdEventName) == nil)
        #expect(RewardConstants.usageMilestones(thresholdMinutes: 5) == [1, 2, 3, 4])
        #expect(RewardConstants.usageMilestones(thresholdMinutes: 1).isEmpty)
        let big = RewardConstants.usageMilestones(thresholdMinutes: 60)
        #expect(big.count <= RewardConstants.maxUsageMilestones)
        #expect(big.allSatisfy { $0 < 60 })
    }

    // MARK: Lenient decoding

    @Test("store: a ledger written without newer fields or with an unknown outcome still loads")
    func lenientDecode() throws {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        let json = """
        {"version":1,"ledger":{"day":"2026-10-14","pending":4,
          "activities":[{"name":"noto.reward.a","thresholdMinutes":10,"creditedMinutes":10,"startedAt":0}],
          "log":[{"name":"noto.reward.z","minutes":3,"date":0,"outcome":"somethingNew"},
                 {"name":"noto.reward.y","minutes":2,"date":0,"outcome":"expired"}]}}
        """
        defaults.set(Data(json.utf8), forKey: RewardLedgerStore.key)
        let l = RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar)
        #expect(l.pending == 4)
        #expect(l.activities.map(\.name) == ["noto.reward.a"])
        #expect(l.activities.first?.usedMinutes == 0)
        #expect(l.log.map(\.name) == ["noto.reward.y"])
    }

    @Test("store: another version keeps its reward names to stop")
    func salvageNames() throws {
        let defaults = RewardClock.privateDefaults("RewardLedgerTests")
        var l = ledger()
        unlock(&l, minutes: 10, at: morning, name: "noto.reward.a")
        let future = RewardLedgerStore.Envelope(version: RewardLedgerStore.Envelope.currentVersion + 1, ledger: l)
        defaults.set(try JSONEncoder().encode(future), forKey: RewardLedgerStore.key)
        let loaded = RewardLedgerStore.load(defaults: defaults, now: morning, calendar: calendar)
        #expect(loaded.activities.isEmpty)
        #expect(loaded.pending == 0)
        #expect(loaded.namesToStop == ["noto.reward.a"])
    }
}
