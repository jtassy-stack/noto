import Testing
import Foundation
@testable import Noto

/// `RewardConfigStore` on a private `UserDefaults` suite (never the app
/// group, which the test host shares with the installed app).
@Suite("RewardConfigStore")
struct RewardConfigStoreTests {
    let defaults: UserDefaults

    init() {
        let suite = "RewardConfigStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("absent key → defaults")
    func absent() {
        #expect(RewardConfigStore.load(defaults: defaults) == .default)
        #expect(RewardConfigStore.load(defaults: nil) == .default)
    }

    @Test("round-trip keeps every field")
    func roundTrip() {
        let config = RewardConfig(tiers: [15, 10, 5], passThreshold: 0.6, dailyCap: 35, examEveBonus: 8,
                                  examEveBonusEnabled: false, minDurationSec: 45, replayWindow: .sameDay,
                                  minQuestionCount: 3)
        RewardConfigStore.save(config, defaults: defaults)
        #expect(RewardConfigStore.load(defaults: defaults) == config)
    }

    @Test("stored in a versioned envelope")
    func envelope() throws {
        RewardConfigStore.save(.default, defaults: defaults)
        let data = try #require(defaults.data(forKey: RewardConfigStore.key))
        let envelope = try JSONDecoder().decode(RewardConfigStore.Envelope.self, from: data)
        #expect(envelope.version == RewardConfigStore.Envelope.currentVersion)
        #expect(envelope.config == .default)
    }

    @Test("corrupt data → defaults, and the stored value is not overwritten by the read")
    func corrupt() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: RewardConfigStore.key)
        #expect(RewardConfigStore.load(defaults: defaults) == .default)
        #expect(defaults.data(forKey: RewardConfigStore.key) == garbage)
    }

    @Test("another envelope version → defaults")
    func versionMismatch() throws {
        let json = #"{"version":99,"config":{"tiers":[1,1,1],"dailyCap":5}}"#
        defaults.set(Data(json.utf8), forKey: RewardConfigStore.key)
        #expect(RewardConfigStore.load(defaults: defaults) == .default)
    }

    @Test("out-of-range values are clamped on read and on write")
    func sanitizes() {
        RewardConfigStore.save(RewardConfig(passThreshold: 2, dailyCap: 500, minQuestionCount: 1), defaults: defaults)
        let loaded = RewardConfigStore.load(defaults: defaults)
        #expect(loaded.passThreshold == 1)
        #expect(loaded.dailyCap == RewardConfig.dailyCapRange.upperBound)
        #expect(loaded.minQuestionCount == RewardConfig.minQuestionCountRange.lowerBound)
    }

    @Test("reset → defaults")
    func reset() {
        RewardConfigStore.save(RewardConfig(dailyCap: 40), defaults: defaults)
        RewardConfigStore.reset(defaults: defaults)
        #expect(RewardConfigStore.load(defaults: defaults) == .default)
    }
}
