import Foundation
import Security

/// Wrapper Keychain pour stocker les credentials scolaires on-device.
/// Aucun credential ne transite par un serveur tiers.
enum KeychainService {
    private static let service = "com.pmf.noto"

    static func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Delete existing
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data

        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    /// Delete a key. `errSecItemNotFound` is treated as success (idempotent).
    /// Any other OSStatus error is thrown so callers can decide whether
    /// to surface it — silently discarding delete failures produced
    /// "Déconnecter la boîte mail" no-ops when the device was locked,
    /// which then led to credentials lingering after the user thought
    /// they were gone.
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Échec d'enregistrement sécurisé (code \(status)). Vérifiez que votre iPhone est déverrouillé et réessayez."
        case .loadFailed(let status):
            return "Échec de lecture sécurisée (code \(status)). Redémarrez l'application."
        case .deleteFailed(let status):
            return "Échec de suppression sécurisée (code \(status))."
        }
    }
}
