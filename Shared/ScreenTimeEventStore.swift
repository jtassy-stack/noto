import Foundation
import FamilyControls

/// Persists DeviceActivity threshold-crossing events in the shared App Group container.
/// Compiled into both the Noto app (reader) and NotoDeviceActivity extension (writer).
enum ScreenTimeEventStore {
    static let appGroupID = "group.fr.noto.app.shared"
    static let eventsKey = "noto_screentime_events"
    static let thresholdHoursKey = "noto_screentime_threshold_hours"
    static let linkedChildIDKey = "noto_screentime_linked_child_id"
    static let watchedSelectionKey = "noto_screentime_watched_selection"
    static let classLockEnabledKey = "noto_screentime_classlock_enabled"
    static let classLockActivityNamesKey = "noto_screentime_classlock_activity_names"
    static let classLockLastSyncKey = "noto_screentime_classlock_last_sync"

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

    // MARK: - Linked child
    //
    // Screen Time authorization (.individual) is inherently device-scoped —
    // it restricts whichever device the app runs on, not a specific child
    // in the family. In a multi-child family, the parent's own nōto install
    // shows briefings for every child; without this link, a screen-time
    // alert from THIS device would surface as a generic "Appareil" card
    // regardless of which child is being viewed, which reads as attributed
    // to the wrong kid the moment there's more than one. Set once during
    // Screen Time setup (ScreenTimeView) to whichever `Child` this specific
    // device belongs to.

    // Stored as the string form of `Child.id` (a SwiftData `PersistentIdentifier`,
    // not a `UUID`) — matching the existing codebase convention of interpolating
    // `child.id` directly into storage keys (see `KeychainService` callers).
    static func storeLinkedChildID(_ childIDDescription: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in storeLinkedChildID")
            return
        }
        if let childIDDescription {
            defaults.set(childIDDescription, forKey: linkedChildIDKey)
        } else {
            defaults.removeObject(forKey: linkedChildIDKey)
        }
    }

    static func loadLinkedChildID() -> String? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        return defaults.string(forKey: linkedChildIDKey)
    }

    // MARK: - Watched selection
    //
    // The apps/categories a parent picked to limit. Persisted (not just kept
    // in ManagedSettingsStore/DeviceActivityCenter, which don't expose a way
    // to read back "what was selected") so: (a) ScreenTimeView can restore
    // its picker state across launches, and (b) the DeviceActivityMonitor
    // extension — which can't re-run the picker — knows which tokens to
    // shield when `eventDidReachThreshold` fires. `FamilyActivitySelection`
    // is `Codable`; its tokens are opaque and device-local, so this is safe
    // to store in the shared App Group container.

    static func storeWatchedSelection(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            NSLog("[noto][error] ScreenTimeEventStore: UserDefaults(suiteName:) returned nil in storeWatchedSelection")
            return
        }
        do {
            let data = try JSONEncoder().encode(selection)
            defaults.set(data, forKey: watchedSelectionKey)
        } catch {
            NSLog("[noto][error] ScreenTimeEventStore: encode failed in storeWatchedSelection — %@", error.localizedDescription)
        }
    }

    static func loadWatchedSelection() -> FamilyActivitySelection {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: watchedSelectionKey) else {
            return FamilyActivitySelection()
        }
        return (try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)) ?? FamilyActivitySelection()
    }

    // MARK: - Class-time lock
    //
    // Opt-in, separate from the graduated app-limit shield (a different
    // named ManagedSettingsStore — see ClassScheduleShieldService) since
    // it's a near-total lockdown, not a per-app budget.

    static func setClassLockEnabled(_ enabled: Bool) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(enabled, forKey: classLockEnabledKey)
    }

    static func isClassLockEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return false }
        return defaults.bool(forKey: classLockEnabledKey)
    }

    /// Names of the `DeviceActivityName`s currently registered for class
    /// blocks — tracked so a resync can `stopMonitoring` ones that no
    /// longer correspond to this week's timetable before registering the
    /// new set (e.g. a course dropped from Tuesday afternoon).
    static func storeClassLockActivityNames(_ names: [String]) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(names, forKey: classLockActivityNamesKey)
    }

    static func loadClassLockActivityNames() -> [String] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        return defaults.stringArray(forKey: classLockActivityNamesKey) ?? []
    }

    static func storeClassLockLastSync(_ date: Date) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(date, forKey: classLockLastSyncKey)
    }

    static func loadClassLockLastSync() -> Date? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        return defaults.object(forKey: classLockLastSyncKey) as? Date
    }
}
