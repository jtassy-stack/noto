import Testing
import Foundation
@testable import Noto

/// The cooldown counts *attempts*, not successes: a failed first sync must
/// not be retried on every view appearance (each retry re-submits stored
/// credentials to the school server), while explicit user actions always run.
@Suite("SyncCooldownPolicy")
struct SyncCooldownPolicyTests {

    private let cooldown: TimeInterval = 60
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("first automatic request runs")
    func noPriorAttemptRuns() {
        #expect(!SyncCooldownPolicy.shouldSkip(force: false, lastAttempt: nil, now: now, cooldown: cooldown))
    }

    @Test("automatic request inside the cooldown is skipped")
    func recentAttemptSkips() {
        let last = now.addingTimeInterval(-10)
        #expect(SyncCooldownPolicy.shouldSkip(force: false, lastAttempt: last, now: now, cooldown: cooldown))
    }

    @Test("automatic request after the cooldown runs")
    func staleAttemptRuns() {
        let last = now.addingTimeInterval(-61)
        #expect(!SyncCooldownPolicy.shouldSkip(force: false, lastAttempt: last, now: now, cooldown: cooldown))
    }

    @Test("forced request ignores the cooldown")
    func forcedAlwaysRuns() {
        let last = now.addingTimeInterval(-1)
        #expect(!SyncCooldownPolicy.shouldSkip(force: true, lastAttempt: last, now: now, cooldown: cooldown))
    }
}
