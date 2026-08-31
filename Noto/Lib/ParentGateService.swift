import Foundation

/// A 4-digit PIN, Keychain-backed, that gates access to parent-only screens
/// (restriction management, disconnect, etc.) from a child-mode device.
/// Separate from Apple's own Screen Time passcode — that one protects the
/// OS-level Screen Time settings, this one protects nōto's own Settings
/// screen from being reached by whoever is holding the child's phone.
enum ParentGateService {
    private static let keychainKey = "noto_parent_gate_pin"

    static var isConfigured: Bool {
        (try? KeychainService.load(key: keychainKey))?.isEmpty == false
    }

    static func setPIN(_ pin: String) throws {
        try KeychainService.save(key: keychainKey, data: Data(pin.utf8))
    }

    static func verify(_ pin: String) -> Bool {
        guard let data = try? KeychainService.load(key: keychainKey),
              let stored = String(data: data, encoding: .utf8) else { return false }
        return stored == pin
    }

    static func clear() throws {
        try KeychainService.delete(key: keychainKey)
    }
}
