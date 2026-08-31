import Foundation

/// Which experience this physical device shows — set once at onboarding.
/// nōto has no cross-device sync (SwiftData is local-only, see the
/// Skolengo/CloudKit scoping notes), so a family with one child on nōto
/// on their own phone and a parent on theirs are two independent local
/// stores; this flag only controls which UI this specific install shows.
enum DeviceMode: String {
    case parent
    case child

    private static let storageKey = "noto_device_mode"

    static var current: DeviceMode {
        get {
            UserDefaults.standard.string(forKey: storageKey).flatMap(DeviceMode.init(rawValue:)) ?? .parent
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}
