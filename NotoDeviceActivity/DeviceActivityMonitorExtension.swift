import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation

@objc(DeviceActivityMonitorExtension)
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let appLimitStore = ManagedSettingsStore()
    private let classLockStore = ManagedSettingsStore(named: ClassLockConstants.storeName)

    // Dispatch goes through `ExtensionRouter` (unit-tested): reward names
    // first (`noto.reward.daily`, then `noto.reward.*`), then class lock,
    // then the app-limit catch-all. The class-lock and app-limit bodies below
    // are unchanged from before 3.4; reward steps only ever touch the default
    // store (`appLimitStore`), never `classLockStore`.

    /// Daily app-limit budget spent, OR the child used the phone during a
    /// class-lock block — shield accordingly. The main app never shields
    /// upfront; this is the only place restrictions actually get applied.
    /// A reward used up re-locks the selection here as well.
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        // Usage milestone of a reward (not its end): record what is used,
        // so a credit stacked on it counts only what is left.
        if RewardConstants.isRewardActivity(activity.rawValue),
           let used = RewardConstants.usedMinutes(fromEventName: event.rawValue) {
            let now = Date.now
            RewardLedgerStore.update(now: now) {
                $0.recordUsed(name: activity.rawValue, minutes: used, now: now, calendar: .current)
            }
            return
        }

        switch ExtensionRouter.action(for: .eventDidReachThreshold, activityName: activity.rawValue) {
        case .rewardThresholdReached:
            rewardEnded(activity, thresholdReached: true)
        case .classLockThreshold:
            classLockStore.shield.applicationCategories = .all(except: Set())
        case .appLimitThreshold:
            let selection = ScreenTimeEventStore.loadWatchedSelection()
            appLimitStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
            appLimitStore.shield.applicationCategories = selection.categoryTokens.isEmpty
                ? nil
                : .specific(selection.categoryTokens, except: Set())

            let hours = ScreenTimeEventStore.loadThreshold()
            ScreenTimeEventStore.append(ScreenTimeEventStore.Event(
                id: UUID(),
                date: .now,
                activityName: activity.rawValue,
                label: "Temps d'écran total",
                thresholdHours: hours
            ))
            // Additive (3.4): minutes earned earlier today, while the budget
            // still had time left, are unlocked now that it is spent.
            unlockPendingReward(selection: selection)
        default:
            NSLog("[noto][ext] threshold ignored for %@", activity.rawValue)
        }
    }

    /// New day (schedule interval restart, 00:00) — lift yesterday's
    /// app-limit shield so the budget resets, matching how native App
    /// Limits reset daily. Not used for class-lock blocks: those reset
    /// naturally each time their own weekly-recurring interval restarts.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        switch ExtensionRouter.action(for: .intervalDidStart, activityName: activity.rawValue) {
        case .rewardDayStart:
            // Only registered when app-limit monitoring is off: nothing else
            // lifts the default store at midnight then.
            if rewardMidnightReset() {
                appLimitStore.shield.applications = nil
                appLimitStore.shield.applicationCategories = nil
            }
        case .appLimitDayStart:
            appLimitStore.shield.applications = nil
            appLimitStore.shield.applicationCategories = nil
            rewardMidnightReset()
        default:
            // A reward's own start must NOT fall into the app-limit lift.
            break
        }
    }

    /// Best-effort immediate lift when a class block ends — documented as
    /// unreliable on recent iOS, which is why `ClassScheduleShieldService`
    /// also defensively clears the shield on the main app's next foreground.
    /// The reserve earned during the block is released here too (and on the
    /// app's next foreground).
    ///
    /// Ignored while a registered class block still runs (`ClassBlockStore`):
    /// a stop/replace from the app's resync, or an AM block overlapping the
    /// PM one, can deliver this mid-class, and the class lock is absolute.
    /// The ending block itself counts as running only if more than a minute
    /// of it is left, so its own (possibly slightly early) end still lifts.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        switch ExtensionRouter.action(for: .intervalDidEnd, activityName: activity.rawValue) {
        case .rewardIntervalEnded:
            rewardEnded(activity, thresholdReached: false)
        case .classLockEnded:
            let now = Date.now
            guard RewardGate.classBlockEnded(activity.rawValue, now: now, blocks: ClassBlockStore.load()) else {
                NSLog("[noto][ext] %@ ended while a class block runs — lock kept", activity.rawValue)
                return
            }
            classLockStore.shield.applicationCategories = nil
            classLockStore.shield.applications = nil
            let released = RewardLedgerStore.update(now: now) { $0.releaseReserve(now: now, calendar: .current) }
            if released > 0 {
                NSLog("[noto][reward] class block ended: %d min released from reserve", released)
                unlockPendingReward(selection: ScreenTimeEventStore.loadWatchedSelection())
            }
        default:
            break
        }
    }

    // MARK: - Reward steps (default store only)

    /// A reward activity was used up (threshold) or its interval ended
    /// (23:59): decrement the ledger, re-lock if no other reward still runs
    /// and the daily budget is still spent (`RewardBudget`), stop the
    /// activity — in both cases: a one-shot activity left registered after
    /// its interval would hold one of the 20 schedule slots for good.
    private func rewardEnded(_ activity: DeviceActivityName, thresholdReached: Bool) {
        let now = Date.now
        let reshield = RewardLedgerStore.update(now: now) { ledger in
            thresholdReached
                ? ledger.thresholdReached(name: activity.rawValue, now: now, calendar: .current)
                : ledger.expire(name: activity.rawValue, now: now, calendar: .current)
        }
        let relock = reshield && RewardBudget.isSpentNow(now: now)
        if relock {
            RewardShield.apply(ScreenTimeEventStore.loadWatchedSelection(), to: appLimitStore)
        }
        NSLog("[noto][reward] %@ %@ — re-lock: %@", activity.rawValue,
              thresholdReached ? "used up" : "interval ended", relock ? "yes" : (reshield ? "no (budget not spent)" : "no"))
        RewardEngine.stop([activity.rawValue])
    }

    /// Stops yesterday's reward activities and resets the ledger. Day-keyed:
    /// a daily activity re-registered mid-day changes nothing. Returns
    /// whether the day changed.
    @discardableResult
    private func rewardMidnightReset() -> Bool {
        let now = Date.now
        let reset = RewardLedgerStore.update(now: now) { $0.midnightReset(now: now, calendar: .current) }
        RewardEngine.stop(reset.namesToStop)
        if reset.rolledOver || !reset.namesToStop.isEmpty {
            NSLog("[noto][reward] midnight reset: stopped %d reward activities", reset.namesToStop.count)
        }
        return reset.rolledOver
    }

    private func unlockPendingReward(selection: FamilyActivitySelection) {
        let outcome = RewardEngine.unlockPending(blocks: ClassBlockStore.load(), selection: selection,
                                                 store: appLimitStore)
        if outcome != .nothingPending {
            NSLog("[noto][reward] extension unlock: %@", String(describing: outcome))
        }
    }
}
