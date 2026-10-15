import Testing
import Foundation
@testable import Noto

/// `RewardGate.canConsume` (« crédit ≠ verrou cours »), `ClassBlock.contains`
/// and `ClassBlockStore`.
@Suite("RewardGate")
struct RewardGateTests {
    let calendar = RewardClock.calendar
    let wed = RewardClock.wednesday

    private var blocks: [ClassBlock] {
        [ClassBlock(weekday: wed, half: .am, startHour: 8, startMinute: 0, endHour: 12, endMinute: 0),
         ClassBlock(weekday: wed, half: .pm, startHour: 13, startMinute: 30, endHour: 16, endMinute: 30)]
    }

    @Test("no block → minutes can always be consumed")
    func noBlocks() {
        #expect(RewardGate.canConsume(now: RewardClock.date(hour: 10), blocks: [], calendar: calendar))
    }

    @Test("inside a block → reserve; start inclusive, end exclusive")
    func insideBlock() {
        #expect(!RewardGate.canConsume(now: RewardClock.date(hour: 8), blocks: blocks, calendar: calendar))
        #expect(!RewardGate.canConsume(now: RewardClock.date(hour: 10, minute: 15), blocks: blocks, calendar: calendar))
        #expect(!RewardGate.canConsume(now: RewardClock.date(hour: 11, minute: 59, second: 59), blocks: blocks,
                                       calendar: calendar))
        #expect(RewardGate.canConsume(now: RewardClock.date(hour: 12), blocks: blocks, calendar: calendar))
        #expect(!RewardGate.canConsume(now: RewardClock.date(hour: 14), blocks: blocks, calendar: calendar))
        #expect(RewardGate.canConsume(now: RewardClock.date(hour: 16, minute: 30), blocks: blocks, calendar: calendar))
    }

    @Test("lunch break, evening and another weekday are outside")
    func outside() {
        #expect(RewardGate.canConsume(now: RewardClock.date(hour: 12, minute: 45), blocks: blocks, calendar: calendar))
        #expect(RewardGate.canConsume(now: RewardClock.date(hour: 19), blocks: blocks, calendar: calendar))
        #expect(RewardGate.canConsume(now: RewardClock.date(day: 1, hour: 10), blocks: blocks, calendar: calendar))
    }

    @Test("blocks round-trip through the app-group store; unreadable → no gate")
    func store() {
        let defaults = RewardClock.privateDefaults("RewardGateTests")
        #expect(ClassBlockStore.load(defaults: defaults).isEmpty)
        ClassBlockStore.store(blocks, defaults: defaults)
        #expect(ClassBlockStore.load(defaults: defaults) == blocks)
        defaults.set(Data("x".utf8), forKey: ClassBlockStore.key)
        #expect(ClassBlockStore.load(defaults: defaults).isEmpty)
    }

    @Test("block activity names keep the class-lock prefix")
    func activityName() {
        #expect(blocks[0].activityName.rawValue == "noto.classlock.4.am")
        #expect(ExtensionRouter.route(blocks[1].activityName.rawValue) == .classLock)
    }

    @Test("class-lock end lifts only when no block still runs")
    func classBlockEnded() {
        let am = blocks[0].activityName.rawValue, pm = blocks[1].activityName.rawValue
        // Natural end of the AM block (or a few seconds early).
        #expect(RewardGate.classBlockEnded(am, now: RewardClock.date(hour: 12), blocks: blocks, calendar: calendar))
        #expect(RewardGate.classBlockEnded(am, now: RewardClock.date(hour: 11, minute: 59, second: 30),
                                           blocks: blocks, calendar: calendar))
        // Stop/replace mid-block, or the AM end while the PM block runs.
        #expect(!RewardGate.classBlockEnded(am, now: RewardClock.date(hour: 10), blocks: blocks, calendar: calendar))
        #expect(!RewardGate.classBlockEnded(am, now: RewardClock.date(hour: 14), blocks: blocks, calendar: calendar))
        #expect(RewardGate.classBlockEnded(pm, now: RewardClock.date(hour: 16, minute: 30), blocks: blocks,
                                           calendar: calendar))
        // Nothing stored (older build): unchanged behaviour.
        #expect(RewardGate.classBlockEnded(am, now: RewardClock.date(hour: 10), blocks: [], calendar: calendar))
    }
}
