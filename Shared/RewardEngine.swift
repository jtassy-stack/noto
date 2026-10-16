import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// The app-limit shield on the DEFAULT `ManagedSettingsStore()`, the only
/// store reward code ever touches. The class lock store
/// (`ManagedSettingsStore(named: ClassLockConstants.storeName)`) is never
/// read or written here (CLAUDE.md « crédit ≠ verrou cours »).
enum RewardShield {
    /// The daily budget was spent: the extension's app-limit branch shielded
    /// the watched selection.
    static func isEngaged(_ store: ManagedSettingsStore) -> Bool {
        store.shield.applications != nil || store.shield.applicationCategories != nil
    }

    static func lift(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    /// Exactly what the extension's app-limit branch applies when the budget
    /// is spent, so re-locking after a reward restores the same state.
    static func apply(_ selection: FamilyActivitySelection, to store: ManagedSettingsStore) {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens, except: Set())
    }

    static func hasTokens(_ selection: FamilyActivitySelection) -> Bool {
        !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty
    }
}

/// Whether the daily budget is spent right now, so a re-lock after a reward
/// restores a real state: the app-limit activity is registered and its
/// threshold (« Temps d'écran total » event) fired today, after its last
/// (re)registration — raising the budget or toggling the limit re-registers
/// it and lifts the shield, so the budget is no longer spent.
enum RewardBudget {
    static let appLimitRegisteredAtKey = "noto_screentime_applimit_registered_at"

    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: ScreenTimeEventStore.appGroupID) }

    /// `ScreenTimeMonitorService.startMonitoring` succeeded.
    static func markAppLimitRegistered(at date: Date = .now, defaults: UserDefaults? = appGroupDefaults) {
        defaults?.set(date, forKey: appLimitRegisteredAtKey)
    }

    /// Pure: an app-limit event today, after `registeredAt` (any today when
    /// unknown, e.g. registered by an older build).
    static func isSpent(eventDates: [Date], registeredAt: Date?, now: Date, calendar: Calendar) -> Bool {
        eventDates.contains { date in
            calendar.isDate(date, inSameDayAs: now) && (registeredAt.map { date >= $0 } ?? true)
        }
    }

    static func isSpentToday(now: Date = .now, calendar: Calendar = .current,
                             defaults: UserDefaults? = appGroupDefaults) -> Bool {
        let dates = ScreenTimeEventStore.load()
            .filter { $0.activityName == RewardConstants.appLimitActivityName }
            .map(\.date)
        return isSpent(eventDates: dates, registeredAt: defaults?.object(forKey: appLimitRegisteredAtKey) as? Date,
                       now: now, calendar: calendar)
    }

    /// Also requires the app-limit activity to be registered right now.
    static func isSpentNow(now: Date = .now, calendar: Calendar = .current,
                           center: DeviceActivityCenter = DeviceActivityCenter()) -> Bool {
        center.activities.contains(DeviceActivityName(RewardConstants.appLimitActivityName))
            && isSpentToday(now: now, calendar: calendar)
    }
}

/// Pure schedule maths of a reward activity.
enum RewardSchedule {
    static let endHour = 23
    static let endMinute = 59

    /// Start of the `now → 23:59` interval. `DeviceActivitySchedule` needs
    /// 15 minutes: after 23:44 the start is clamped to 23:44 (usage between
    /// 23:44 and the credit then counts, a minute-scale loss on the last
    /// credit of the day).
    static func intervalStart(now: Date, calendar: Calendar) -> DateComponents {
        let c = calendar.dateComponents([.hour, .minute, .second], from: now)
        let nowMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let latestStart = endHour * 60 + endMinute - RewardConstants.minimumIntervalMinutes
        if nowMinutes > latestStart {
            return DateComponents(hour: latestStart / 60, minute: latestStart % 60, second: 0)
        }
        return DateComponents(hour: c.hour, minute: c.minute, second: c.second)
    }

    static var intervalEnd: DateComponents { DateComponents(hour: endHour, minute: endMinute) }

    static func threshold(minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }
}

/// Outcome of `RewardEngine.unlockPending`, logged by both callers.
enum RewardUnlockOutcome: Equatable, Sendable {
    /// Screen Time not authorized on this device (app side only): the
    /// minutes stay in the ledger, nothing is registered.
    case notAuthorized
    case nothingPending
    /// Inside a class block: the minutes went to the reserve.
    case reserved(minutes: Int)
    /// No watched apps: nothing to unlock, minutes stay pending.
    case noSelection
    /// Budget not spent (no shield to lift): minutes stay pending, and are
    /// unlocked when the app-limit threshold fires or on a later foreground.
    case budgetNotSpent
    /// No schedule slot could be freed (20-schedule limit).
    case noRoom
    /// iOS < 17.4: DeviceActivityEvent cannot ignore usage from before the
    /// unlock (`includesPastActivity`), so earlier use in the interval could
    /// re-lock the apps at once. Minutes stay pending, nothing is unlocked.
    case unsupportedOS
    case failed(String)
    case unlocked(RewardActivity, merged: [String])
}

/// Registers reward activities. Shared by `RewardUnlockService` (app) and
/// the extension (reserve released after class, minutes earned before the
/// budget ran out), so both follow one implementation.
enum RewardEngine {
    /// Turns the ledger's pending minutes into a `noto.reward.<uuid>` activity
    /// on the watched selection and lifts the default store shield.
    ///
    /// Order: gate → selection → something to lift → plan (3-activity cap,
    /// `activities.count < 20` check) → commit the ledger → stop the merged
    /// activities → `startMonitoring` → lift.
    /// - The ledger is committed before stopping, so an `intervalDidEnd`
    ///   triggered by the stop finds an unknown name and re-locks nothing.
    /// - Merged activities are stopped before registering, so the count the
    ///   plan checked (< 20) is the count `startMonitoring` sees.
    /// - The shield is lifted last, only once something watches the usage.
    /// - On failure the ledger is rolled back; if nothing watches any more
    ///   while the shield is down and the budget is still spent, the
    ///   selection is re-shielded.
    /// - The ledger is saved only after each change (never in a blanket
    ///   `defer`), so a write the extension made in between (a usage
    ///   milestone, a threshold) is not overwritten by a stale copy.
    static func unlockPending(
        now: Date = .now,
        calendar: Calendar = .current,
        blocks: [ClassBlock],
        selection: FamilyActivitySelection,
        defaults: UserDefaults? = RewardLedgerStore.appGroupDefaults,
        center: DeviceActivityCenter = DeviceActivityCenter(),
        store: ManagedSettingsStore = ManagedSettingsStore()
    ) -> RewardUnlockOutcome {
        guard #available(iOS 17.4, *) else { return .unsupportedOS }
        var ledger = RewardLedgerStore.load(defaults: defaults, now: now, calendar: calendar)
        if ledger.rollOver(now: now, calendar: calendar) {
            RewardLedgerStore.save(ledger, defaults: defaults)
        }
        guard ledger.pending > 0 else { return .nothingPending }

        guard RewardGate.canConsume(now: now, blocks: blocks, calendar: calendar) else {
            let moved = ledger.moveToReserve(now: now, calendar: calendar)
            RewardLedgerStore.save(ledger, defaults: defaults)
            NSLog("[noto][reward] in class: %d min to reserve", moved)
            return .reserved(minutes: moved)
        }

        guard RewardShield.hasTokens(selection) else { return .noSelection }
        // Something to unlock: the budget shield is up, or a running reward
        // already lifted it (the new credit extends that reward).
        guard RewardShield.isEngaged(store) || !ledger.activities.isEmpty else { return .budgetNotSpent }

        let registered = center.activities.count
        let name = RewardConstants.activityName()
        // Re-read right before planning: the stacked threshold uses the
        // freshest usage milestones the extension recorded.
        ledger = RewardLedgerStore.load(defaults: defaults, now: now, calendar: calendar)
        ledger.rollOver(now: now, calendar: calendar)
        guard ledger.pending > 0 else { return .nothingPending }
        guard let plan = ledger.planUnlock(name: name, now: now, calendar: calendar,
                                           registeredActivityCount: registered) else {
            NSLog("[noto][reward] no schedule slot (%d registered)", registered)
            return .noRoom
        }

        ledger.commit(plan, now: now, calendar: calendar)
        RewardLedgerStore.save(ledger, defaults: defaults)
        stop(plan.stop, center: center)

        let schedule = DeviceActivitySchedule(
            intervalStart: RewardSchedule.intervalStart(now: now, calendar: calendar),
            intervalEnd: RewardSchedule.intervalEnd,
            repeats: false
        )
        do {
            try center.startMonitoring(
                DeviceActivityName(plan.activity.name),
                during: schedule,
                events: makeEvents(selection: selection, minutes: plan.activity.thresholdMinutes)
            )
        } catch {
            // Rolled back on a fresh copy: keeps what the extension wrote since.
            let nothingRuns = RewardLedgerStore.update(defaults: defaults, now: now, calendar: calendar) { l -> Bool in
                l.rollback(plan)
                return l.activities.isEmpty
            }
            if nothingRuns, !RewardShield.isEngaged(store),
               RewardBudget.isSpentNow(now: now, calendar: calendar, center: center) {
                RewardShield.apply(selection, to: store)
            }
            NSLog("[noto][reward] startMonitoring failed: %@", error.localizedDescription)
            return .failed(error.localizedDescription)
        }

        RewardShield.lift(store)
        NSLog("[noto][reward] unlocked %@ threshold %d min (credit %d, merged %d)",
              plan.activity.name, plan.activity.thresholdMinutes, plan.activity.creditedMinutes, plan.stop.count)
        return .unlocked(plan.activity, merged: plan.stop)
    }

    /// Stops reward activities by name, never with an empty list (which
    /// would stop every activity, app limit and class lock included).
    static func stop(_ names: [String], center: DeviceActivityCenter = DeviceActivityCenter()) {
        let rewardNames = names.filter(RewardConstants.isRewardActivity)
        guard !rewardNames.isEmpty else { return }
        center.stopMonitoring(rewardNames.map { DeviceActivityName($0) })
    }

    /// The threshold event, plus the usage milestones the extension records
    /// so a later credit stacks on what is left (`RewardLedger.planUnlock`).
    private static func makeEvents(selection: FamilyActivitySelection,
                                   minutes: Int) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var events = [DeviceActivityEvent.Name(RewardConstants.thresholdEventName): makeEvent(selection: selection,
                                                                                               minutes: minutes)]
        for milestone in RewardConstants.usageMilestones(thresholdMinutes: minutes) {
            events[DeviceActivityEvent.Name(RewardConstants.usageEventName(minutes: milestone))] =
                makeEvent(selection: selection, minutes: milestone)
        }
        return events
    }

    private static func makeEvent(selection: FamilyActivitySelection, minutes: Int) -> DeviceActivityEvent {
        let threshold = RewardSchedule.threshold(minutes: minutes)
        if #available(iOS 17.4, *) {
            // Only usage after the unlock counts.
            return DeviceActivityEvent(applications: selection.applicationTokens,
                                       categories: selection.categoryTokens,
                                       threshold: threshold, includesPastActivity: false)
        }
        // Unreachable: `unlockPending` refuses to register rewards below
        // iOS 17.4 (past usage would satisfy the threshold at once).
        return DeviceActivityEvent(applications: selection.applicationTokens,
                                   categories: selection.categoryTokens,
                                   threshold: threshold)
    }
}
