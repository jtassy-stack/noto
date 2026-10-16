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

    /// One AM or PM lockdown window for a given weekday (`Shared/ClassBlock.swift`,
    /// so the extension can read the windows back for the reward gate).
    typealias Block = ClassBlock

    /// Days of timetable that make up "this week", from the start of today
    /// (`hasLessonsInWindow`).
    static let blockWindowDays = 7

    /// Groups the child's schedule into at most one AM + one PM block per
    /// weekday (cancelled lessons excluded), splitting at 13:00.
    ///
    /// Each weekday is built from ONE calendar day, so a multi-week
    /// `Child.schedule` never merges two different Tuesdays into one
    /// over-wide block (safe for the lock, wrong for the reward reserve):
    /// the nearest day of that weekday from the start of today (`now`)
    /// onwards, else — stale or partial data, e.g. a sync that failed for a
    /// week, or a sync after school that returned nothing for earlier today
    /// — the most recent past one. A weekday is never dropped just because
    /// the stored timetable is old: the class lock must stay on
    /// (CLAUDE.md « verrou cours absolu »).
    ///
    /// An AM block that runs past the start of the PM block (a 12:00–14:00
    /// lab) is merged with it into one block, so the AM `intervalDidEnd`
    /// never lifts the shield in the middle of the afternoon.
    static func computeBlocks(from schedule: [ScheduleEntry], now: Date = .now,
                              calendar: Calendar = .current) -> [Block] {
        let today = calendar.startOfDay(for: now)
        let active = schedule.filter { !$0.cancelled }
        let byDay = Dictionary(grouping: active) { calendar.startOfDay(for: $0.start) }
        let daysByWeekday = Dictionary(grouping: byDay.keys) { calendar.component(.weekday, from: $0) }

        var blocks: [Block] = []
        for (weekday, days) in daysByWeekday {
            guard let day = days.filter({ $0 >= today }).min() ?? days.filter({ $0 < today }).max(),
                  let lessons = byDay[day] else { continue }
            let am = lessons.filter { calendar.component(.hour, from: $0.start) < 13 }
            let pm = lessons.filter { calendar.component(.hour, from: $0.start) >= 13 }

            let amBlock = block(for: am, weekday: weekday, half: .am, calendar: calendar)
            let pmBlock = block(for: pm, weekday: weekday, half: .pm, calendar: calendar)
            if let amBlock, let pmBlock, amBlock.endMinutes >= pmBlock.startMinutes {
                blocks.append(Block(weekday: weekday, half: .am,
                                    startHour: amBlock.startHour, startMinute: amBlock.startMinute,
                                    endHour: max(amBlock.endMinutes, pmBlock.endMinutes) / 60,
                                    endMinute: max(amBlock.endMinutes, pmBlock.endMinutes) % 60))
                continue
            }
            if let amBlock { blocks.append(amBlock) }
            if let pmBlock { blocks.append(pmBlock) }
        }
        return blocks.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
    }

    /// The timetable holds at least one non-cancelled lesson from the start
    /// of today to `blockWindowDays` later: a fresh week was synced. A school
    /// sync whose timetable fetch failed (empty, or only old lessons kept)
    /// must not re-register the class lock (`FullSyncService`).
    static func hasLessonsInWindow(_ schedule: [ScheduleEntry], now: Date = .now,
                                   calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: blockWindowDays, to: start) ?? start
        return schedule.contains { !$0.cancelled && $0.start >= start && $0.start < end }
    }

    /// Blocks the reward gate and the foreground clear trust: those actually
    /// registered (`ClassBlockStore`, written by `sync` only) united with
    /// those the current timetable gives. Never smaller than what is
    /// registered, so stale or empty SwiftData cannot open a class block.
    static func knownBlocks(schedule: [ScheduleEntry], now: Date = .now,
                            calendar: Calendar = .current) -> [Block] {
        mergedBlocks(ClassBlockStore.load(), computeBlocks(from: schedule, now: now, calendar: calendar))
    }

    /// Union of two block lists, deduplicated, in a stable order. Pure.
    nonisolated static func mergedBlocks(_ a: [Block], _ b: [Block]) -> [Block] {
        Array(Set(a).union(b)).sorted {
            ($0.weekday, $0.startMinutes, $0.endMinutes) < ($1.weekday, $1.startMinutes, $1.endMinutes)
        }
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
    /// e.g. a course dropped from the timetable). Called after a successful
    /// school sync (`FullSyncService`), from the parent's toggle and from a
    /// manual "Actualiser" action, since there's no reliable background
    /// trigger for this (confirmed: BGAppRefreshTask isn't guaranteed to run
    /// on any particular cadence).
    ///
    /// The registered names are persisted after EACH successful
    /// `startMonitoring`, so a throw mid-loop never leaks a schedule that
    /// `disable()` could not stop.
    ///
    /// Class-lock safety (the lock is absolute, CLAUDE.md):
    /// - A timetable that yields no block while blocks are registered
    ///   (failed or partial timetable fetch) changes nothing: only the
    ///   parent's toggle (`disable()`) removes the lock. No throw, since
    ///   `ScreenTimeView` turns the lock off on any error.
    /// - The block running right now is neither stopped (even if the new
    ///   timetable drops it — stopped at the next sync) nor re-registered
    ///   when unchanged: either may deliver `intervalDidEnd` mid-class and
    ///   would restart its 1-minute threshold from zero.
    /// - `ClassBlockStore` (the extension's gate) holds the union of the old
    ///   and new blocks while registering, the exact registered set after.
    static func sync(schedule: [ScheduleEntry], now: Date = .now) throws {
        let center = DeviceActivityCenter()
        let calendar = Calendar.current
        let previousNames = Set(ScreenTimeEventStore.loadClassLockActivityNames())
        let previousBlocks = ClassBlockStore.load()

        let blocks = computeBlocks(from: schedule, now: now, calendar: calendar)
        guard !blocks.isEmpty || previousNames.isEmpty else {
            NSLog("[noto][warn] ClassScheduleShieldService: timetable gives no block, %d registered — kept",
                  previousNames.count)
            return
        }
        let newNames = Set(blocks.map { $0.activityName.rawValue })

        // Dropped by the new timetable but running now: kept until next sync.
        let runningDropped = previousBlocks.filter {
            $0.contains(now, calendar: calendar) && previousNames.contains($0.activityName.rawValue)
                && !newNames.contains($0.activityName.rawValue)
        }
        let deferredNames = Set(runningDropped.map { $0.activityName.rawValue })

        let stale = previousNames.subtracting(newNames).subtracting(deferredNames).map { DeviceActivityName($0) }
        if !stale.isEmpty { center.stopMonitoring(stale) }

        ClassBlockStore.store(mergedBlocks(previousBlocks, blocks))
        var succeeded = Set<String>()
        ScreenTimeEventStore.storeClassLockActivityNames(
            Array(registeredNames(previous: previousNames, new: newNames, succeeded: succeeded)
                .union(deferredNames)).sorted())

        for block in blocks {
            let name = block.activityName.rawValue
            if block.contains(now, calendar: calendar), previousNames.contains(name), previousBlocks.contains(block) {
                // Running and unchanged: already registered as is.
                succeeded.insert(name)
                continue
            }
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
            succeeded.insert(name)
            ScreenTimeEventStore.storeClassLockActivityNames(
                Array(registeredNames(previous: previousNames, new: newNames, succeeded: succeeded)
                    .union(deferredNames)).sorted())
        }

        ClassBlockStore.store(mergedBlocks(blocks, runningDropped))
        ScreenTimeEventStore.storeClassLockLastSync(.now)
    }

    /// Names still registered with `DeviceActivityCenter` at some point of
    /// `sync`: the previous names kept by the new timetable (registered
    /// before, stale ones were already stopped) plus those re-registered so
    /// far. Pure.
    nonisolated static func registeredNames(previous: Set<String>, new: Set<String>,
                                            succeeded: Set<String>) -> Set<String> {
        previous.intersection(new).union(succeeded)
    }

    /// Resync the class lock after a school sync (`FullSyncService`): only
    /// when the lock is on and this device's linked child was among the
    /// synced children AND its sync succeeded during this run (each sync
    /// service stamps `lastSyncedAt` on success only). Pure.
    nonisolated static func shouldResyncAfterSchoolSync(
        classLockEnabled: Bool,
        linkedChildID: String?,
        syncedChildren: [(id: String, lastSyncedAt: Date?)],
        syncStartedAt: Date
    ) -> Bool {
        guard classLockEnabled, let linkedChildID else { return false }
        guard let child = syncedChildren.first(where: { $0.id == linkedChildID }),
              let synced = child.lastSyncedAt else { return false }
        return synced >= syncStartedAt
    }

    static func disable() {
        let center = DeviceActivityCenter()
        let names = ScreenTimeEventStore.loadClassLockActivityNames().map { DeviceActivityName($0) }
        // Never an empty list: stopMonitoring([]) stops EVERY activity
        // (app limit and rewards included).
        if !names.isEmpty { center.stopMonitoring(names) }
        ScreenTimeEventStore.storeClassLockActivityNames([])
        ManagedSettingsStore(named: ClassLockConstants.storeName).shield.applicationCategories = nil
        ManagedSettingsStore(named: ClassLockConstants.storeName).shield.applications = nil
    }

    /// Defensive foreground check — clears the lock if we're not actually
    /// inside any registered block right now, guarding against a missed
    /// `intervalDidEnd` leaving the phone stuck shielded. Cheap (no I/O
    /// beyond UserDefaults) so it's safe to call on every app foreground.
    ///
    /// Trusts the registered blocks (`ClassBlockStore`) united with the
    /// timetable's, never the timetable alone: stale SwiftData must not
    /// open a running block. When class-lock names are registered but no
    /// window is known for them today, nothing is cleared.
    static func clearIfOutsideClassHours(schedule: [ScheduleEntry], now: Date = .now) {
        let calendar = Calendar.current
        let blocks = knownBlocks(schedule: schedule, now: now, calendar: calendar)
        let names = ScreenTimeEventStore.loadClassLockActivityNames()
        guard shouldClearClassLock(now: now, blocks: blocks, registeredNames: names, calendar: calendar) else { return }
        let store = ManagedSettingsStore(named: ClassLockConstants.storeName)
        if store.shield.applicationCategories != nil || store.shield.applications != nil {
            store.shield.applicationCategories = nil
            store.shield.applications = nil
        }
    }

    /// Outside every known block ("can consume", same test as the reward
    /// gate), and no registered name for today's weekday lacks a known
    /// window (`noto.classlock.<weekday>.<half>`). Pure.
    nonisolated static func shouldClearClassLock(now: Date, blocks: [Block], registeredNames: [String],
                                                 calendar: Calendar) -> Bool {
        guard RewardGate.canConsume(now: now, blocks: blocks, calendar: calendar) else { return false }
        let weekday = calendar.component(.weekday, from: now)
        let todayPrefix = "\(ClassLockConstants.activityNamePrefix)\(weekday)."
        let registeredToday = registeredNames.filter { $0.hasPrefix(todayPrefix) }
        let knownToday = Set(blocks.filter { $0.weekday == weekday }.map { $0.activityName.rawValue })
        return registeredToday.allSatisfy { knownToday.contains($0) }
    }
}
