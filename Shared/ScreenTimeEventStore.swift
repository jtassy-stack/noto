import Foundation

/// Persists DeviceActivity threshold-crossing events in the shared App Group container.
/// Compiled into both the Noto app (reader) and NotoDeviceActivity extension (writer).
enum ScreenTimeEventStore {
    static let appGroupID = "group.fr.noto.app.shared"
    static let eventsKey = "noto_screentime_events"
    static let thresholdHoursKey = "noto_screentime_threshold_hours"

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let activityName: String
        let label: String
        let thresholdHours: Int
    }

    static func append(_ event: Event) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var events = load()
        events.append(event)
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        events = events.filter { $0.date >= cutoff }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    static func load() -> [Event] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: eventsKey),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return events
    }

    static func recentEvents(withinDays days: Int = 7) -> [Event] {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        return load().filter { $0.date >= cutoff }
    }

    static func storeThreshold(hours: Int) {
        UserDefaults(suiteName: appGroupID)?.set(hours, forKey: thresholdHoursKey)
    }

    static func loadThreshold() -> Int {
        UserDefaults(suiteName: appGroupID)?.integer(forKey: thresholdHoursKey) ?? 2
    }
}
