import DeviceActivity
import ManagedSettings
import Foundation

/// Locks the phone down during class hours, driven by the child's synced
/// timetable (`Child.schedule`, from Pronote/ENT/École Directe/Skolengo).
///
/// Uses a SEPARATE named `ManagedSettingsStore` from the graduated app-limit
/// shield (`ScreenTimeMonitorService`) — this is a near-total lockdown, not
/// a per-app budget, and the two must never clobber each other.
///
/// Real API constraints this design works around (confirmed against Apple's
/// docs/forums before building):
/// - `DeviceActivitySchedule` can't express arbitrary weekday sets, only a
///   continuous weekday range applied daily — so each block is registered
///   as its own single-weekday schedule (start.weekday == end.weekday).
/// - `DeviceActivityCenter` caps concurrent schedules at 20
///   (`.excessiveActivities`) — one block per weekday half-day (AM/PM) stays
///   at 10 max for a full week, vs. one-per-class which could exceed it.
/// - `intervalDidStart`/`intervalDidEnd` are documented as unreliable on
///   recent iOS — the actual shield-apply is triggered by a usage-threshold
///   event (`eventDidReachThreshold`, the same mechanism already proven
///   reliable for the app-limit feature), with `intervalDidStart`/`intervalDidEnd`
///   only as a best-effort bonus. The main app also defensively clears the
///   shield on foreground if the current time falls outside every block,
///   so a missed `intervalDidEnd` can't leave the phone stuck locked.
@MainActor
enum ClassScheduleShieldService {

    /// One AM or PM lockdown window for a given weekday, derived from the
    /// child's schedule. `weekday` follows `Calendar`'s convention (1 = Sunday).
    struct Block {
        let weekday: Int
        let half: Half
        let startHour: Int
        let startMinute: Int
        let endHour: Int
        let endMinute: Int

        enum Half: String { case am, pm }

        var activityName: DeviceActivityName {
            DeviceActivityName("\(ClassLockConstants.activityNamePrefix)\(weekday).\(half.rawValue)")
        }
    }

    /// Groups the child's schedule into at most one AM + one PM block per
    /// weekday (cancelled lessons excluded), splitting at 13:00.
    static func computeBlocks(from schedule: [ScheduleEntry]) -> [Block] {
        let calendar = Calendar.current
        let active = schedule.filter { !$0.cancelled }
        let byWeekday = Dictionary(grouping: active) { calendar.component(.weekday, from: $0.start) }

        var blocks: [Block] = []
        for (weekday, lessons) in byWeekday {
            let am = lessons.filter { calendar.component(.hour, from: $0.start) < 13 }
            let pm = lessons.filter { calendar.component(.hour, from: $0.start) >= 13 }

            if let block = block(for: am, weekday: weekday, half: .am, calendar: calendar) { blocks.append(block) }
            if let block = block(for: pm, weekday: weekday, half: .pm, calendar: calendar) { blocks.append(block) }
        }
        return blocks
    }

    private static func block(for lessons: [ScheduleEntry], weekday: Int, half: Block.Half, calendar: Calendar) -> Block? {
        guard let first = lessons.min(by: { $0.start < $1.start }),
              let last = lessons.max(by: { $0.end < $1.end }) else { return nil }
        let startComps = calendar.dateComponents([.hour, .minute], from: first.start)
        let endComps = calendar.dateComponents([.hour, .minute], from: last.end)
        guard let startHour = startComps.hour, let startMinute = startComps.minute,
              let endHour = endComps.hour, let endMinute = endComps.minute else { return nil }
        // DeviceActivitySchedule requires a minimum 15-minute interval —
        // a single short lesson could fall under that.
        let totalMinutes = (endHour * 60 + endMinute) - (startHour * 60 + startMinute)
        guard totalMinutes >= 15 else { return nil }
        return Block(weekday: weekday, half: half, startHour: startHour, startMinute: startMinute, endHour: endHour, endMinute: endMinute)
    }

    /// Registers this week's blocks, replacing whatever was registered
    /// before (stops any previously-active block name no longer present —
    /// e.g. a course dropped from the timetable). Call whenever the child's
    /// schedule syncs, and from a manual "Actualiser" action, since there's
    /// no reliable background trigger for this (confirmed: BGAppRefreshTask
    /// isn't guaranteed to run on any particular cadence).
    static func sync(schedule: [ScheduleEntry]) throws {
        let center = DeviceActivityCenter()
        let previousNames = Set(ScreenTimeEventStore.loadClassLockActivityNames())

        let blocks = computeBlocks(from: schedule)
        let newNames = Set(blocks.map { $0.activityName.rawValue })

        let stale = previousNames.subtracting(newNames).map { DeviceActivityName($0) }
        if !stale.isEmpty { center.stopMonitoring(stale) }

        for block in blocks {
            let daSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: block.startHour, minute: block.startMinute, weekday: block.weekday),
                intervalEnd: DateComponents(hour: block.endHour, minute: block.endMinute, weekday: block.weekday),
                repeats: true
            )
            // Fires as soon as the child actually uses the phone during the
            // block (1 minute of cumulative screen-on time) — the reliable
            // trigger, unlike the schedule-boundary callbacks alone.
            let event = DeviceActivityEvent(threshold: DateComponents(minute: 1))
            try center.startMonitoring(
                block.activityName,
                during: daSchedule,
                events: [DeviceActivityEvent.Name("threshold"): event]
            )
        }

        ScreenTimeEventStore.storeClassLockActivityNames(Array(newNames))
        ScreenTimeEventStore.storeClassLockLastSync(.now)
    }

    static func disable() {
        let center = DeviceActivityCenter()
        let names = ScreenTimeEventStore.loadClassLockActivityNames().map { DeviceActivityName($0) }
        center.stopMonitoring(names)
        ScreenTimeEventStore.storeClassLockActivityNames([])
        ManagedSettingsStore(named: ClassLockConstants.storeName).shield.applicationCategories = nil
        ManagedSettingsStore(named: ClassLockConstants.storeName).shield.applications = nil
    }

    /// Defensive foreground check — clears the lock if we're not actually
    /// inside any registered block right now, guarding against a missed
    /// `intervalDidEnd` leaving the phone stuck shielded. Cheap (no I/O
    /// beyond UserDefaults) so it's safe to call on every app foreground.
    static func clearIfOutsideClassHours(schedule: [ScheduleEntry]) {
        let now = Date.now
        let calendar = Calendar.current
        let blocks = computeBlocks(from: schedule)
        let weekday = calendar.component(.weekday, from: now)
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        let insideABlock = blocks.contains { block in
            guard block.weekday == weekday else { return false }
            let startMinutes = block.startHour * 60 + block.startMinute
            let endMinutes = block.endHour * 60 + block.endMinute
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        }

        guard !insideABlock else { return }
        let store = ManagedSettingsStore(named: ClassLockConstants.storeName)
        if store.shield.applicationCategories != nil || store.shield.applications != nil {
            store.shield.applicationCategories = nil
            store.shield.applications = nil
        }
    }
}
