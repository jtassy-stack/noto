import Testing
import Foundation
@testable import Noto

/// Pure parts of the unlock path: schedule maths, child wording, foreground
/// maintenance decisions.
@MainActor
@Suite("Reward unlock logic")
struct RewardUnlockLogicTests {
    let calendar = RewardClock.calendar
    let morning = RewardClock.date(hour: 10)

    // MARK: RewardSchedule

    @Test("interval starts now (to the second) and ends at 23:59")
    func intervalNow() {
        let start = RewardSchedule.intervalStart(now: RewardClock.date(hour: 17, minute: 42, second: 9),
                                                 calendar: calendar)
        #expect(start == DateComponents(hour: 17, minute: 42, second: 9))
        #expect(RewardSchedule.intervalEnd == DateComponents(hour: 23, minute: 59))
    }

    @Test("after 23:44 the start is clamped so the interval keeps 15 minutes")
    func intervalClamp() {
        #expect(RewardSchedule.intervalStart(now: RewardClock.date(hour: 23, minute: 44), calendar: calendar)
                == DateComponents(hour: 23, minute: 44, second: 0))
        #expect(RewardSchedule.intervalStart(now: RewardClock.date(hour: 23, minute: 50, second: 30),
                                             calendar: calendar)
                == DateComponents(hour: 23, minute: 44, second: 0))
    }

    @Test("threshold components split hours and minutes")
    func threshold() {
        #expect(RewardSchedule.threshold(minutes: 20) == DateComponents(hour: 0, minute: 20))
        #expect(RewardSchedule.threshold(minutes: 75) == DateComponents(hour: 1, minute: 15))
    }

    // MARK: RewardStatus

    private func status(_ ledger: RewardLedger, configured: Bool = true, inClass: Bool = false) -> RewardStatus {
        RewardStatus.make(ledger: ledger, configured: configured, inClass: inClass, now: morning, calendar: calendar)
    }

    private func unlocked(_ minutes: Int) -> RewardLedger {
        var l = RewardLedger(now: morning, calendar: calendar)
        l.credit(minutes, now: morning, calendar: calendar)
        let plan = l.planUnlock(name: "noto.reward.a", now: morning, calendar: calendar, registeredActivityCount: 1)!
        l.commit(plan, now: morning, calendar: calendar)
        return l
    }

    @Test("no Screen Time setup → neutral wording whatever the ledger")
    func notConfigured() {
        #expect(status(unlocked(10), configured: false) == .neutral)
        #expect(status(RewardLedger(now: morning, calendar: calendar)) == .neutral)
    }

    @Test("running reward → unlocked; in class → after class")
    func unlockedAndClass() {
        #expect(status(unlocked(10)) == .unlocked(minutes: 10))
        #expect(status(unlocked(10), inClass: true) == .afterClass)
        var reserve = RewardLedger(now: morning, calendar: calendar)
        reserve.credit(5, now: morning, calendar: calendar)
        reserve.moveToReserve(now: morning, calendar: calendar)
        #expect(status(reserve) == .afterClass)
    }

    @Test("pending outside class → waiting for the budget; yesterday's ledger → neutral")
    func pending() {
        var l = RewardLedger(now: morning, calendar: calendar)
        l.credit(5, now: morning, calendar: calendar)
        #expect(status(l) == .waitingForBudget(minutes: 5))
        let tomorrow = RewardClock.date(day: 1, hour: 9)
        #expect(RewardStatus.make(ledger: unlocked(10), configured: true, inClass: false,
                                  now: tomorrow, calendar: calendar) == .neutral)
    }

    @Test("child wording, tutoiement")
    func wording() {
        #expect(ChildHomeView.rewardStatusText(.neutral) == nil)
        #expect(ChildHomeView.rewardStatusText(.unlocked(minutes: 12))?.title == "Tes 12 min sont débloquées")
        #expect(ChildHomeView.rewardStatusText(.afterClass)?.title == "Tes minutes t'attendent après les cours")
        #expect(ChildHomeView.rewardStatusText(.waitingForBudget(minutes: 5))?.title == "Tes 5 min t'attendent")
    }

    // MARK: RewardMaintenance

    @Test("noto.reward.daily only without the app-limit activity, counting the budget")
    func dailyReset() {
        let appLimit = RewardConstants.appLimitActivityName
        let daily = RewardConstants.dailyActivityName
        #expect(RewardMaintenance.dailyResetAction(registered: []) == .register)
        #expect(RewardMaintenance.dailyResetAction(registered: [daily]) == .none)
        #expect(RewardMaintenance.dailyResetAction(registered: [appLimit]) == .none)
        #expect(RewardMaintenance.dailyResetAction(registered: [appLimit, daily]) == .stop)
        let full = Set((0..<20).map { "noto.classlock.\($0)" })
        #expect(RewardMaintenance.dailyResetAction(registered: full) == .none)
    }

    @Test("defensive re-lock only for a reward that vanished unrecorded, budget spent, none running")
    func relock() {
        let none = RewardLedger(now: morning, calendar: calendar)
        func relock(_ l: RewardLedger, dropped: Int = 1, engaged: Bool = false, monitoring: Bool = true,
                    spent: Bool = true) -> Bool {
            RewardMaintenance.shouldRelock(ledger: l, droppedMissing: dropped, shieldEngaged: engaged,
                                           appLimitMonitoring: monitoring, budgetSpentToday: spent)
        }
        #expect(relock(none))
        // Normal consumption (extension re-shielded) or the parent raising the
        // budget (shield lifted by the app-limit re-registration): no re-lock.
        #expect(!relock(none, dropped: 0))
        #expect(!relock(unlocked(10)))                       // another reward still runs
        #expect(!relock(none, engaged: true))                // already locked
        #expect(!relock(none, monitoring: false))            // parent turned the limit off
        #expect(!relock(none, spent: false))                 // budget not spent today
    }

    @Test("pending minutes without an app-limit budget → neutral, no false promise")
    func pendingWithoutBudget() {
        var l = RewardLedger(now: morning, calendar: calendar)
        l.credit(5, now: morning, calendar: calendar)
        #expect(RewardStatus.make(ledger: l, configured: true, inClass: false, appLimitMonitoring: false,
                                  now: morning, calendar: calendar) == .neutral)
    }

    @Test("budget spent: an app-limit event today, after the last (re)registration")
    func budgetSpent() {
        let event = RewardClock.date(hour: 16)
        #expect(RewardBudget.isSpent(eventDates: [event], registeredAt: nil, now: RewardClock.date(hour: 17),
                                     calendar: calendar))
        #expect(RewardBudget.isSpent(eventDates: [event], registeredAt: RewardClock.date(hour: 9),
                                     now: RewardClock.date(hour: 17), calendar: calendar))
        // The parent raised the budget at 16:30: no longer spent.
        #expect(!RewardBudget.isSpent(eventDates: [event], registeredAt: RewardClock.date(hour: 16, minute: 30),
                                      now: RewardClock.date(hour: 17), calendar: calendar))
        // Yesterday's event does not count.
        #expect(!RewardBudget.isSpent(eventDates: [event], registeredAt: nil, now: RewardClock.date(day: 1, hour: 10),
                                      calendar: calendar))
    }
}
