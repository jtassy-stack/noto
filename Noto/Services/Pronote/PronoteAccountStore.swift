import Foundation

/// The single owner of what nōto keeps about a Pronote account between
/// launches: one `PronoteRefreshToken` per Pronote username in the
/// Keychain (`pronote_token_<username>`), the list of usernames in
/// UserDefaults (`pronote_known_usernames`, the Keychain cannot be listed
/// by prefix) and the device UUID pawnote presents to Pronote.
///
/// Before this type, the QR view, the ENT view and the auto-reconnect each
/// wrote these keys on their own, with `try?` around the Keychain save: a
/// token that failed to persist was lost silently and the next launch
/// replayed the one Pronote had just invalidated. Saving throws here;
/// callers decide how to surface it.
///
/// Nothing in here ever leaves the device.
enum PronoteAccountStore {
    private static let usernamesKey = "pronote_known_usernames"
    private static let deviceUUIDKey = "device_uuid"

    private static func tokenKey(_ username: String) -> String { "pronote_token_\(username)" }

    /// Every stored account, in the order they were added. Entries whose
    /// Keychain item is missing or unreadable are skipped (and reported via
    /// `unreadableUsernames` so the caller can tell the parent).
    static func all() -> [PronoteRefreshToken] {
        usernames.compactMap { load(username: $0) }
    }

    static var usernames: [String] {
        UserDefaults.standard.stringArray(forKey: usernamesKey) ?? []
    }

    /// Usernames listed in UserDefaults whose token cannot be read back.
    /// Typical cause: an app reinstall (UserDefaults restored from backup,
    /// Keychain items were `ThisDeviceOnly`). The parent has to rescan.
    static var unreadableUsernames: [String] {
        usernames.filter { load(username: $0) == nil }
    }

    static func load(username: String) -> PronoteRefreshToken? {
        guard let data = try? KeychainService.load(key: tokenKey(username)) else { return nil }
        return try? JSONDecoder().decode(PronoteRefreshToken.self, from: data)
    }

    /// Persists the token and registers its username. Throws on a Keychain
    /// or encoding failure: the caller must not treat the login as kept.
    static func save(_ token: PronoteRefreshToken) throws {
        let data = try JSONEncoder().encode(token)
        try KeychainService.save(key: tokenKey(token.username), data: data)
        var names = usernames
        if !names.contains(token.username) {
            names.append(token.username)
            UserDefaults.standard.set(names, forKey: usernamesKey)
        }
    }

    static func remove(username: String) throws {
        try KeychainService.delete(key: tokenKey(username))
        let names = usernames.filter { $0 != username }
        UserDefaults.standard.set(names, forKey: usernamesKey)
    }

    /// Drops every Pronote account (« Effacer toutes les données »).
    static func removeAll() {
        for username in usernames {
            try? KeychainService.delete(key: tokenKey(username))
        }
        UserDefaults.standard.removeObject(forKey: usernamesKey)
    }

    /// The UUID pawnote registers with Pronote as this device. Pronote ties
    /// the mobile token to it, so it is created once and never regenerated
    /// while a token exists.
    static func deviceUUID() -> String {
        if let data = try? KeychainService.load(key: deviceUUIDKey),
           let uuid = String(data: data, encoding: .utf8), !uuid.isEmpty {
            return uuid
        }
        let uuid = UUID().uuidString
        try? KeychainService.save(key: deviceUUIDKey, data: Data(uuid.utf8))
        return uuid
    }
}
