import Foundation

/// Pure dispatch of the `NotoDeviceActivity` callbacks, extracted so the
/// prefix order is unit-tested (PHASE3_DESIGN §C.2). Order matters:
/// 1. `noto.reward.daily` (exact name, it carries the reward prefix),
/// 2. `noto.reward.*`,
/// 3. `noto.classlock.*`,
/// 4. anything else = the app-limit activity, exactly as before 3.4.
/// Without 1–2 first, a reward's `intervalDidStart` would fall into the
/// app-limit branch and lift the daily budget shield.
enum ExtensionRouter {
    enum Callback: Sendable {
        case intervalDidStart
        case intervalDidEnd
        case eventDidReachThreshold
    }

    enum Route: Equatable, Sendable {
        case rewardDaily
        case reward
        case classLock
        case appLimit
    }

    enum Action: Equatable, Sendable {
        /// Nothing to do (logged).
        case ignore
        /// `noto.reward.daily` started: stop yesterday's reward activities,
        /// reset the ledger, lift the default shield if the day changed.
        case rewardDayStart
        /// A reward was used up: re-lock (if it was the last one), log,
        /// decrement the ledger, stop the activity.
        case rewardThresholdReached
        /// A reward's interval ended (23:59): same as above, without the log
        /// counting it as used.
        case rewardIntervalEnded
        /// Unchanged class-lock behaviour: shield the class store.
        case classLockThreshold
        /// Unchanged class-lock behaviour (lift the class store), then the
        /// ledger releases the reserve earned during the block.
        case classLockEnded
        /// Unchanged app-limit behaviour (lift the default store at 00:00),
        /// then the reward midnight reset (day-keyed, no-op mid-day).
        case appLimitDayStart
        /// Unchanged app-limit behaviour (shield + « Temps d'écran total »
        /// event), then minutes earned earlier today, if any, are unlocked.
        case appLimitThreshold
    }

    static func route(_ activityName: String) -> Route {
        if activityName == RewardConstants.dailyActivityName { return .rewardDaily }
        if activityName.hasPrefix(RewardConstants.prefix) { return .reward }
        if activityName.hasPrefix(ClassLockConstants.activityNamePrefix) { return .classLock }
        return .appLimit
    }

    static func action(for callback: Callback, activityName: String) -> Action {
        switch (route(activityName), callback) {
        case (.rewardDaily, .intervalDidStart): return .rewardDayStart
        case (.rewardDaily, _): return .ignore
        case (.reward, .intervalDidStart): return .ignore
        case (.reward, .intervalDidEnd): return .rewardIntervalEnded
        case (.reward, .eventDidReachThreshold): return .rewardThresholdReached
        case (.classLock, .intervalDidStart): return .ignore
        case (.classLock, .intervalDidEnd): return .classLockEnded
        case (.classLock, .eventDidReachThreshold): return .classLockThreshold
        case (.appLimit, .intervalDidStart): return .appLimitDayStart
        case (.appLimit, .intervalDidEnd): return .ignore
        case (.appLimit, .eventDidReachThreshold): return .appLimitThreshold
        }
    }
}
