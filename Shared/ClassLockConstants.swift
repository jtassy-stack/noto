import Foundation
import ManagedSettings

/// Shared between the main app (`ClassScheduleShieldService`, which computes
/// and registers the blocks) and the `NotoDeviceActivity` extension (which
/// applies/lifts the shield when a block's threshold fires) — kept in
/// `Shared/` since the extension target doesn't compile `Noto/Services`.
enum ClassLockConstants {
    static var storeName: ManagedSettingsStore.Name { ManagedSettingsStore.Name("noto.classTimeLock") }
    static let activityNamePrefix = "noto.classlock."
}
