import Foundation

/// Persists DeviceActivity threshold-crossing events in the shared App Group container.
/// Compiled into both the Noto app (reader) and NotoDeviceActivity extension (writer).
enum ScreenTimeEventStore {
    static let appGroupID = "group.fr.noto.app.shared"
    static let eventsKey = "noto_screentime_events"
    static let thresholdHoursKey = "noto_screentime_threshold_hours"

    // MARK: - Models

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let activityName: String
        let label: String
        let thresholdHours: Int

        enum CodingKeys: String, CodingKey {
            case id
            case date
            case activityName
            case label
            case thresholdHours
        }
    }

    /// Version envelope — bumping `currentVersion` forces a clean slate on schema changes.
    private struct StorageEnvelope: Codable {
        static let currentVersion = 1
        let version: Int
        let events: [Event]
    }

    // MARK: - Write

    static func append(_ event: Event) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in append")
            return
        }
        guard let existing = loadRaw() else {
            NSLog("[noto][error] ScreenTimeEventStore: decode failure in append — existing data preserved, new event dropped")
            return
        }
        var events = existing
        events.append(event)
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        events = events.filter { $0.date >= cutoff }
        let envelope = StorageEnvelope(version: StorageEnvelope.currentVersion, events: events)
        do {
            let data = try JSONEncoder().encode(envelope)
            defaults.set(data, forKey: eventsKey)
        } catch {
            NSLog("[noto][error] ScreenTimeEventStore: JSONEncoder failed in append — %@", error.localizedDescription)
        }
    }

    // MARK: - Read

    private static func loadRaw() -> [Event]? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        guard let data = defaults.data(forKey: eventsKey) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(StorageEnvelope.self, from: data)
            guard envelope.version == StorageEnvelope.currentVersion else { return nil }
            return envelope.events
        } catch {
            return nil
        }
    }

    /// Loads stored events. Returns `[]` on first install (absent key) or unrecoverable
    /// decode failure; both cases are distinguishable via the logs.
    static func load() -> [Event] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in load")
            return []
        }

        // Key absent on first install — not an error, just return empty.
        guard let data = defaults.data(forKey: eventsKey) else {
            return []
        }

        // Decode envelope; log and return [] on failure WITHOUT overwriting existing data.
        do {
            let envelope = try JSONDecoder().decode(StorageEnvelope.self, from: data)
            if envelope.version != StorageEnvelope.currentVersion {
                NSLog("[noto][error] ScreenTimeEventStore: stored version %d != expected %d — discarding",
                      envelope.version, StorageEnvelope.currentVersion)
                return []
            }
            return envelope.events
        } catch {
            NSLog("[noto][error] ScreenTimeEventStore: JSONDecoder failed in load — %@", error.localizedDescription)
            return []
        }
    }

    static func recentEvents(withinDays days: Int = 7) -> [Event] {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        return load().filter { $0.date >= cutoff }
    }

    // MARK: - Threshold

    static func storeThreshold(hours: Int) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in storeThreshold")
            return
        }
        defaults.set(hours, forKey: thresholdHoursKey)
    }

    static func loadThreshold() -> Int {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in loadThreshold")
            return 2
        }
        // UserDefaults.integer(forKey:) returns 0 for an absent key — not nil —
        // so the ?? operator cannot be used here to detect a missing key.
        let stored = defaults.integer(forKey: thresholdHoursKey)
        return stored > 0 ? stored : 2
    }
}
