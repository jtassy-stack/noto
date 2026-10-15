import Testing
import Foundation
@testable import Noto

/// The extension's dispatch (`ExtensionRouter`): reward names first, then
/// class lock, then the unchanged app-limit catch-all (PHASE3_DESIGN §C.2).
@Suite("ExtensionRouter")
struct ExtensionRouterTests {
    let reward = RewardConstants.activityName(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let daily = RewardConstants.dailyActivityName
    let classLock = "noto.classlock.4.am"
    let appLimit = RewardConstants.appLimitActivityName

    @Test("prefix order: daily (exact) → reward → class lock → app limit")
    func routes() {
        #expect(reward == "noto.reward.00000000-0000-0000-0000-000000000001")
        #expect(ExtensionRouter.route(daily) == .rewardDaily)
        #expect(ExtensionRouter.route(reward) == .reward)
        #expect(ExtensionRouter.route(classLock) == .classLock)
        #expect(ExtensionRouter.route(appLimit) == .appLimit)
        // Anything unknown keeps the pre-3.4 behaviour (app-limit branch).
        #expect(ExtensionRouter.route("legacy.activity") == .appLimit)
        // The reward prefix wins even if a name also mentions another prefix.
        #expect(ExtensionRouter.route("noto.reward.noto.classlock.4.am") == .reward)
    }

    @Test("a reward's intervalDidStart never reaches the app-limit lift")
    func rewardStartIgnored() {
        #expect(ExtensionRouter.action(for: .intervalDidStart, activityName: reward) == .ignore)
        #expect(ExtensionRouter.action(for: .eventDidReachThreshold, activityName: reward) == .rewardThresholdReached)
        #expect(ExtensionRouter.action(for: .intervalDidEnd, activityName: reward) == .rewardIntervalEnded)
    }

    @Test("daily reset activity only acts on its start")
    func dailyActions() {
        #expect(ExtensionRouter.action(for: .intervalDidStart, activityName: daily) == .rewardDayStart)
        #expect(ExtensionRouter.action(for: .intervalDidEnd, activityName: daily) == .ignore)
        #expect(ExtensionRouter.action(for: .eventDidReachThreshold, activityName: daily) == .ignore)
    }

    @Test("class-lock and app-limit callbacks map to their unchanged branches")
    func existingBranches() {
        #expect(ExtensionRouter.action(for: .intervalDidStart, activityName: classLock) == .ignore)
        #expect(ExtensionRouter.action(for: .intervalDidEnd, activityName: classLock) == .classLockEnded)
        #expect(ExtensionRouter.action(for: .eventDidReachThreshold, activityName: classLock) == .classLockThreshold)
        #expect(ExtensionRouter.action(for: .intervalDidStart, activityName: appLimit) == .appLimitDayStart)
        #expect(ExtensionRouter.action(for: .intervalDidEnd, activityName: appLimit) == .ignore)
        #expect(ExtensionRouter.action(for: .eventDidReachThreshold, activityName: appLimit) == .appLimitThreshold)
    }

    @Test("isRewardActivity excludes the daily reset name")
    func isRewardActivity() {
        #expect(RewardConstants.isRewardActivity(reward))
        #expect(!RewardConstants.isRewardActivity(daily))
        #expect(!RewardConstants.isRewardActivity(classLock))
        #expect(!RewardConstants.isRewardActivity(appLimit))
    }
}
