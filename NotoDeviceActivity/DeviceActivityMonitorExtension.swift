import DeviceActivity
import Foundation

@objc(DeviceActivityMonitorExtension)
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        let hours = ScreenTimeEventStore.loadThreshold()
        ScreenTimeEventStore.append(ScreenTimeEventStore.Event(
            id: UUID(),
            date: .now,
            activityName: activity.rawValue,
            label: "Temps d'écran total",
            thresholdHours: hours
        ))
    }
}
