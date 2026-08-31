import DeviceActivity
import FamilyControls
import Foundation

/// Starts and stops DeviceActivity monitoring from the main app.
///
/// Graduated-limit model (matches Apple's native "App Limits", not a
/// blanket block): the parent picks apps/categories to watch and a daily
/// time budget; those apps stay usable until the combined budget is spent,
/// at which point the `NotoDeviceActivity` extension's `eventDidReachThreshold`
/// shields exactly that selection — not immediately on selection, and not
/// the whole device. The extension can't re-run the picker, so the
/// selection is persisted via `ScreenTimeEventStore.storeWatchedSelection`
/// for it to read back when the threshold fires.
@MainActor
final class ScreenTimeMonitorService: Sendable {
    static let shared = ScreenTimeMonitorService()

    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("noto.screentime.daily")
    private let eventName = DeviceActivityEvent.Name("noto.screentime.threshold")

    /// Starts (or restarts) monitoring for the given apps/categories with a
    /// combined daily budget. Selecting a new app or changing the threshold
    /// calls this again — DeviceActivityCenter treats a re-registration of
    /// the same `DeviceActivityName` as a replace, not a duplicate.
    func startMonitoring(selection: FamilyActivitySelection, thresholdHours: Int) throws {
        ScreenTimeEventStore.storeWatchedSelection(selection)

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            threshold: DateComponents(hour: thresholdHours, minute: 0)
        )
        do {
            try center.startMonitoring(
                activityName,
                during: schedule,
                events: [eventName: event]
            )
        } catch {
            NSLog("[noto][warn] ScreenTimeMonitorService: startMonitoring failed: %@", error.localizedDescription)
            throw error
        }
        ScreenTimeEventStore.storeThreshold(hours: thresholdHours)
    }

    func stopMonitoring() {
        center.stopMonitoring([activityName])
    }

    var isMonitoring: Bool {
        center.activities.contains(activityName)
    }
}
