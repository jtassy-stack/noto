import DeviceActivity
import Foundation

/// Starts and stops DeviceActivity monitoring from the main app.
/// The NotoDeviceActivity extension handles threshold callbacks and writes events
/// to the shared App Group container; this service only configures the schedule.
@MainActor
final class ScreenTimeMonitorService: Sendable {
    static let shared = ScreenTimeMonitorService()

    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("noto.screentime.daily")
    private let eventName = DeviceActivityEvent.Name("noto.screentime.threshold")

    func startMonitoring(thresholdHours: Int) throws {
        ScreenTimeEventStore.storeThreshold(hours: thresholdHours)

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
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
    }

    func stopMonitoring() {
        center.stopMonitoring([activityName])
    }

    var isMonitoring: Bool {
        center.activities.contains(activityName)
    }
}
