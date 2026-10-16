import Foundation

/// Names and limits of the reward mechanism (plan §3.4, PHASE3_DESIGN §C.2),
/// shared by the app (`RewardUnlockService`) and the `NotoDeviceActivity`
/// extension, which dispatches on these prefixes (`ExtensionRouter`).
enum RewardConstants {
    /// Every reward `DeviceActivityName` starts with this, including the
    /// daily reset activity: the extension must test it before the class-lock
    /// and app-limit branches, or a reward's `intervalDidStart` would lift the
    /// app-limit shield (C.2 dispatch bug).
    static let prefix = "noto.reward."

    /// Midnight reset of the ledger when the app-limit activity
    /// (`appLimitActivityName`, which already starts at 00:00) is not
    /// registered. One more schedule, which is why the reward cap is 3.
    static let dailyActivityName = "noto.reward.daily"

    /// The single threshold event of a reward activity.
    static let thresholdEventName = "noto.reward.threshold"

    /// The graduated app-limit activity (`ScreenTimeMonitorService`).
    static let appLimitActivityName = "noto.screentime.daily"

    /// Reward activities registered at the same time. Budget: 1 app-limit
    /// (or `noto.reward.daily`) + up to 14 class-lock half-days + 3 = 18 < 20.
    static let maxSimultaneousRewardActivities = 3

    /// `DeviceActivityCenter` refuses more schedules (`.excessiveActivities`).
    static let appleActivityLimit = 20

    /// `DeviceActivitySchedule` refuses shorter intervals (`.intervalTooShort`).
    static let minimumIntervalMinutes = 15

    /// `noto.reward.<uuid>`, lowercased so names compare as stored.
    static func activityName(id: UUID = UUID()) -> String {
        prefix + id.uuidString.lowercased()
    }

    /// Usage milestones of a reward activity: `noto.reward.used.<minutes>`.
    /// The extension records the minutes in the ledger, so a credit stacked
    /// on a running reward counts only what is left of it.
    static let usageEventPrefix = "noto.reward.used."

    /// At most this many milestone events per reward activity.
    static let maxUsageMilestones = 20

    static func usageEventName(minutes: Int) -> String {
        usageEventPrefix + String(minutes)
    }

    /// The minutes of a milestone event name, nil for any other event.
    static func usedMinutes(fromEventName name: String) -> Int? {
        guard name.hasPrefix(usageEventPrefix),
              let minutes = Int(name.dropFirst(usageEventPrefix.count)), minutes > 0 else { return nil }
        return minutes
    }

    /// Milestone minutes below `thresholdMinutes` (the threshold event itself
    /// covers the end), every `step` minutes, step = ⌈threshold / max⌉ ≥ 1.
    static func usageMilestones(thresholdMinutes: Int) -> [Int] {
        guard thresholdMinutes > 1 else { return [] }
        let step = max(1, (thresholdMinutes + maxUsageMilestones - 1) / maxUsageMilestones)
        return Array(stride(from: step, to: thresholdMinutes, by: step))
    }

    /// A per-credit reward activity (not the daily reset one).
    static func isRewardActivity(_ rawName: String) -> Bool {
        rawName.hasPrefix(prefix) && rawName != dailyActivityName
    }
}
