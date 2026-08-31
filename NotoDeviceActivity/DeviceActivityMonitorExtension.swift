import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation

@objc(DeviceActivityMonitorExtension)
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let appLimitStore = ManagedSettingsStore()
    private let classLockStore = ManagedSettingsStore(named: ClassLockConstants.storeName)

    private func isClassLockActivity(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue.hasPrefix(ClassLockConstants.activityNamePrefix)
    }

    /// Daily app-limit budget spent, OR the child used the phone during a
    /// class-lock block — shield accordingly. The main app never shields
    /// upfront; this is the only place restrictions actually get applied.
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        if isClassLockActivity(activity) {
            classLockStore.shield.applicationCategories = .all(except: Set())
            return
        }

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
    }

    /// New day (schedule interval restart, 00:00) — lift yesterday's
    /// app-limit shield so the budget resets, matching how native App
    /// Limits reset daily. Not used for class-lock blocks: those reset
    /// naturally each time their own weekly-recurring interval restarts.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard !isClassLockActivity(activity) else { return }
        appLimitStore.shield.applications = nil
        appLimitStore.shield.applicationCategories = nil
    }

    /// Best-effort immediate lift when a class block ends — documented as
    /// unreliable on recent iOS, which is why `ClassScheduleShieldService`
    /// also defensively clears the shield on the main app's next foreground.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard isClassLockActivity(activity) else { return }
        classLockStore.shield.applicationCategories = nil
        classLockStore.shield.applications = nil
    }
}
