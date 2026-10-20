import Testing
import Foundation
import SwiftData
@testable import Noto

/// Class-lock fixes of 3.4 (PHASE3_DESIGN §C.2): `computeBlocks` limited to
/// one occurrence of each weekday, names persisted after each successful
/// registration, resync after a successful school sync.
@MainActor
@Suite("ClassScheduleShieldService blocks")
struct ClassScheduleBlocksTests {
    let context: ModelContext
    let calendar = RewardClock.calendar

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
    }

    private func lesson(day: Int, _ startHour: Int, _ startMinute: Int = 0, to endHour: Int, _ endMinute: Int = 0,
                        cancelled: Bool = false) -> ScheduleEntry {
        let entry = ScheduleEntry(subject: "Maths",
                                  start: RewardClock.date(day: day, hour: startHour, minute: startMinute),
                                  end: RewardClock.date(day: day, hour: endHour, minute: endMinute),
                                  cancelled: cancelled)
        context.insert(entry)
        return entry
    }

    private func blocks(_ schedule: [ScheduleEntry], now: Date = RewardClock.date(hour: 7)) -> [ClassBlock] {
        ClassScheduleShieldService.computeBlocks(from: schedule, now: now, calendar: calendar)
    }

    @Test("AM / PM split at 13:00, cancelled lessons ignored")
    func split() {
        let schedule = [lesson(day: 0, 8, to: 10), lesson(day: 0, 10, to: 12),
                        lesson(day: 0, 14, to: 16), lesson(day: 0, 16, to: 17, cancelled: true)]
        let result = blocks(schedule)
        #expect(result == [
            ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0),
            ClassBlock(weekday: 4, half: .pm, startHour: 14, startMinute: 0, endHour: 16, endMinute: 0),
        ])
    }

    @Test("the same weekday a week later does not widen the block")
    func noMultiWeekMerge() {
        // This Wednesday 8–12, next Wednesday 7–13 (different timetable).
        let schedule = [lesson(day: 0, 8, to: 12), lesson(day: 7, 7, to: 12, 30)]
        let result = blocks(schedule)
        #expect(result == [ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0)])
    }

    @Test("rolling window: next Monday counts on a Wednesday, last Monday does not")
    func rollingWindow() {
        let lastMonday = lesson(day: -2, 9, to: 11)
        let nextMonday = lesson(day: 5, 8, to: 10)
        let nextTuesday = lesson(day: 6, 8, to: 10)
        let result = blocks([lastMonday, nextMonday, nextTuesday])
        #expect(result.map(\.weekday) == [2, 3])
        #expect(result.first?.startHour == 8)
        // Later the same day, this morning's lessons still count (today's blocks).
        let today = lesson(day: 0, 8, to: 12)
        #expect(blocks([today], now: RewardClock.date(hour: 23)).count == 1)
    }

    @Test("blocks shorter than 15 minutes are dropped")
    func tooShort() {
        #expect(blocks([lesson(day: 0, 8, to: 8, 10)]).isEmpty)
    }

    @Test("persisted names after each success: kept previous ∪ re-registered")
    func registeredNames() {
        let previous: Set = ["noto.classlock.2.am", "noto.classlock.3.am", "noto.classlock.5.pm"]
        let new: Set = ["noto.classlock.2.am", "noto.classlock.3.am", "noto.classlock.4.am"]
        // Before the loop: stale 5.pm already stopped, the kept ones are still registered.
        #expect(ClassScheduleShieldService.registeredNames(previous: previous, new: new, succeeded: [])
                == ["noto.classlock.2.am", "noto.classlock.3.am"])
        // Throw after registering 4.am only: 4.am is recorded, so disable() can stop it.
        #expect(ClassScheduleShieldService.registeredNames(previous: previous, new: new,
                                                           succeeded: ["noto.classlock.4.am"])
                == ["noto.classlock.2.am", "noto.classlock.3.am", "noto.classlock.4.am"])
    }

    @Test("resync after a school sync only for the linked child synced in this run, lock on")
    func resyncDecision() {
        let start = RewardClock.date(hour: 10)
        let fresh = [(id: "child-1", lastSyncedAt: Optional(start.addingTimeInterval(5))),
                     (id: "child-2", lastSyncedAt: Optional(start.addingTimeInterval(-3600)))]
        #expect(ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: true, linkedChildID: "child-1", syncedChildren: fresh, syncStartedAt: start))
        #expect(!ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: false, linkedChildID: "child-1", syncedChildren: fresh, syncStartedAt: start))
        #expect(!ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: true, linkedChildID: "child-2", syncedChildren: fresh, syncStartedAt: start))
        #expect(!ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: true, linkedChildID: "child-3", syncedChildren: fresh, syncStartedAt: start))
        #expect(!ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: true, linkedChildID: nil, syncedChildren: fresh, syncStartedAt: start))
        #expect(!ClassScheduleShieldService.shouldResyncAfterSchoolSync(
            classLockEnabled: true, linkedChildID: "child-1",
            syncedChildren: [(id: "child-1", lastSyncedAt: nil)], syncStartedAt: start))
    }

    @Test("stale timetable (sync failed for 10 days): the weekday keeps its block")
    func staleTimetable() {
        let result = blocks([lesson(day: -14, 8, to: 12), lesson(day: -7, 9, to: 12)])
        // Most recent past Wednesday wins (9–12), never [] → lock not lifted.
        #expect(result == [ClassBlock(weekday: 4, half: .am, startHour: 9, startMinute: 0, endHour: 12, endMinute: 0)])
    }

    @Test("today's lessons missing (synced after school): next week's same weekday is used")
    func sameWeekdayNextWeek() {
        let result = blocks([lesson(day: 7, 8, to: 12)], now: RewardClock.date(hour: 18))
        #expect(result == [ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0)])
    }

    @Test("an AM block running past the PM start is merged into one block")
    func overlapMerged() {
        let result = blocks([lesson(day: 0, 8, to: 10), lesson(day: 0, 12, to: 14), lesson(day: 0, 13, to: 16)])
        #expect(result == [ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 16, endMinute: 0)])
    }

    @Test("lessons in this week's window: fresh vs failed timetable")
    func lessonsInWindow() {
        let now = RewardClock.date(hour: 7)
        #expect(ClassScheduleShieldService.hasLessonsInWindow([lesson(day: 2, 8, to: 9)], now: now, calendar: calendar))
        #expect(!ClassScheduleShieldService.hasLessonsInWindow([lesson(day: -3, 8, to: 9)], now: now, calendar: calendar))
        #expect(!ClassScheduleShieldService.hasLessonsInWindow([lesson(day: 1, 8, to: 9, cancelled: true)],
                                                               now: now, calendar: calendar))
        #expect(!ClassScheduleShieldService.hasLessonsInWindow([], now: now, calendar: calendar))
    }

    @Test("foreground clear: never inside a known block, never with today's names but no window")
    func shouldClear() {
        let am = ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0)
        let inClass = RewardClock.date(hour: 10)
        let evening = RewardClock.date(hour: 19)
        #expect(!ClassScheduleShieldService.shouldClearClassLock(
            now: inClass, blocks: [am], registeredNames: ["noto.classlock.4.am"], calendar: calendar))
        #expect(ClassScheduleShieldService.shouldClearClassLock(
            now: evening, blocks: [am], registeredNames: ["noto.classlock.4.am"], calendar: calendar))
        // Stale SwiftData gave nothing, but a Wednesday block is registered.
        #expect(!ClassScheduleShieldService.shouldClearClassLock(
            now: inClass, blocks: [], registeredNames: ["noto.classlock.4.am"], calendar: calendar))
        // Nothing registered for today: the old behaviour.
        #expect(ClassScheduleShieldService.shouldClearClassLock(
            now: inClass, blocks: [], registeredNames: ["noto.classlock.2.am"], calendar: calendar))
    }

    @Test("merged blocks: union without duplicates")
    func merged() {
        let a = ClassBlock(weekday: 4, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0)
        let b = ClassBlock(weekday: 2, half: .pm, startHour: 14, startMinute: 0, endHour: 16, endMinute: 0)
        #expect(ClassScheduleShieldService.mergedBlocks([a], [a, b]) == [b, a])
    }
}
