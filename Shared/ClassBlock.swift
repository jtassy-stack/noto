import DeviceActivity
import Foundation

/// One AM or PM class window for a given weekday, derived from the child's
/// timetable by `ClassScheduleShieldService.computeBlocks` (app target).
/// Lives in `Shared/` so the `NotoDeviceActivity` extension, which has no
/// SwiftData, can read the windows back (`ClassBlockStore`) and apply the
/// same reward gate (`RewardGate`) as the app.
///
/// `weekday` follows `Calendar`'s convention (1 = Sunday).
struct ClassBlock: Codable, Equatable, Hashable, Sendable {
    let weekday: Int
    let half: Half
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int

    enum Half: String, Codable, Sendable { case am, pm }

    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }

    var activityName: DeviceActivityName {
        DeviceActivityName("\(ClassLockConstants.activityNamePrefix)\(weekday).\(half.rawValue)")
    }

    /// `date` falls inside this window: same weekday, start ≤ time < end
    /// (minute precision, like the `DeviceActivitySchedule` it registers).
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard calendar.component(.weekday, from: date) == weekday else { return false }
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return minutes >= startMinutes && minutes < endMinutes
    }
}

/// The current class windows, persisted in the app group for the extension.
/// Written by `ClassScheduleShieldService.sync` (the registered set), and by
/// the app's reward refresh only when no class lock is registered or the
/// store is still empty (never shrunk from SwiftData); empty (no gate) when
/// never written.
enum ClassBlockStore {
    static let key = "noto_screentime_class_blocks"

    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let blocks: [ClassBlock]
    }

    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: ScreenTimeEventStore.appGroupID) }

    static func store(_ blocks: [ClassBlock], defaults: UserDefaults? = appGroupDefaults) {
        guard let defaults else { return }
        do {
            let envelope = Envelope(version: Envelope.currentVersion, blocks: blocks)
            defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        } catch {
            NSLog("[noto][error] ClassBlockStore: encode failed — %@", error.localizedDescription)
        }
    }

    static func load(defaults: UserDefaults? = appGroupDefaults) -> [ClassBlock] {
        guard let defaults, let data = defaults.data(forKey: key) else { return [] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Envelope.currentVersion else {
            NSLog("[noto][error] ClassBlockStore: unreadable or other version — no blocks")
            return []
        }
        return envelope.blocks
    }
}

/// The class-hours invariant for reward credit (CLAUDE.md « crédit ≠ verrou
/// cours »): minutes are never consumed while a class block is running, they
/// go to the ledger's reserve and are released after class. Pure.
///
/// Rewards never touch `ManagedSettingsStore(named: ClassLockConstants.storeName)`;
/// this gate only decides whether the DEFAULT store may be lifted now.
enum RewardGate {
    static func canConsume(now: Date, blocks: [ClassBlock], calendar: Calendar = .current) -> Bool {
        !blocks.contains { $0.contains(now, calendar: calendar) }
    }

    /// A class-lock `intervalDidEnd` for `endingName` may lift the class
    /// store: none of the other stored blocks contains `now`, and the ending
    /// one has at most a minute left (its own, possibly slightly early, end).
    /// A stop/replace from a resync or an overlapping block delivers the
    /// callback mid-class: then false. Empty store (never synced by this
    /// build): true, the behaviour before the store existed.
    static func classBlockEnded(_ endingName: String, now: Date, blocks: [ClassBlock],
                                calendar: Calendar = .current) -> Bool {
        let others = blocks.filter { $0.activityName.rawValue != endingName }
        let ending = blocks.filter { $0.activityName.rawValue == endingName }
        return canConsume(now: now, blocks: others, calendar: calendar)
            && canConsume(now: now.addingTimeInterval(60), blocks: ending, calendar: calendar)
    }
}
