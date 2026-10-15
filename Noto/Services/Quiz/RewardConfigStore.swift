import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "RewardConfigStore")

/// The parent's `RewardConfig`, persisted as JSON in the app group
/// (`ScreenTimeEventStore.appGroupID`) inside a versioned envelope, the same
/// pattern as `ScreenTimeEventStore`.
///
/// - Absent key (fresh install), unreadable JSON or another envelope version:
///   `RewardConfig.default`. A corrupt value is logged and left in place
///   (never overwritten by a read); the next `save` replaces it.
/// - Values are `sanitized()` on read and on write.
/// - Lives in the app target for now (`RewardConfig` is not compiled into
///   the DeviceActivity extension); phase 3.4 moves it to `Shared/` next to
///   `RewardLedger` when the extension needs it (PHASE3_DESIGN C.2).
enum RewardConfigStore {
    static let key = "noto_reward_config"

    struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let config: RewardConfig
    }

    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: ScreenTimeEventStore.appGroupID) }

    static func load(defaults: UserDefaults? = appGroupDefaults) -> RewardConfig {
        guard let defaults, let data = defaults.data(forKey: key) else { return .default }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Envelope.currentVersion else {
                logger.error("Stored reward config version \(envelope.version) != \(Envelope.currentVersion), using defaults")
                return .default
            }
            return envelope.config.sanitized()
        } catch {
            logger.error("Reward config unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    static func save(_ config: RewardConfig, defaults: UserDefaults? = appGroupDefaults) {
        guard let defaults else {
            logger.error("App group defaults unavailable, reward config not saved")
            return
        }
        do {
            let envelope = Envelope(version: Envelope.currentVersion, config: config.sanitized())
            defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        } catch {
            logger.error("Encoding reward config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Back to `RewardConfig.default` (the key is removed).
    static func reset(defaults: UserDefaults? = appGroupDefaults) {
        defaults?.removeObject(forKey: key)
    }
}
