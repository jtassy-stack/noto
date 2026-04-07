import Foundation
import SwiftData

/// Attempts to silently restore the Pronote session on app launch
/// using stored refresh tokens — no QR scan required after first login.
@MainActor
enum PronoteAutoConnect {

    /// Try to reconnect using all stored refresh tokens.
    /// Returns `true` if at least one account reconnected successfully.
    @discardableResult
    static func autoConnect(modelContext: ModelContext) async -> Bool {
        let usernames = UserDefaults.standard.stringArray(forKey: "pronote_known_usernames") ?? []
        guard !usernames.isEmpty else { return false }

        PronoteService.shared.isReconnecting = true
        defer { PronoteService.shared.isReconnecting = false }

        let deviceUUID = getOrCreateDeviceUUID()
        var anySuccess = false

        for username in usernames {
            guard
                let tokenData = try? KeychainService.load(key: "pronote_token_\(username)"),
                let tokenData,
                let refreshToken = try? JSONDecoder().decode(PronoteRefreshToken.self, from: tokenData)
            else { continue }

            do {
                let bridge = try PawnoteBridge()
                let newToken = try await bridge.loginWithToken(
                    url: refreshToken.url,
                    username: refreshToken.username,
                    token: refreshToken.token,
                    deviceUUID: deviceUUID
                )

                // Persist updated token
                if let updatedData = try? JSONEncoder().encode(newToken) {
                    try? KeychainService.save(key: "pronote_token_\(newToken.username)", data: updatedData)
                }

                PronoteService.shared.setBridge(bridge)
                anySuccess = true
                NSLog("[noto] Auto-reconnect succeeded for %@", username)
            } catch {
                NSLog("[noto] Auto-reconnect failed for %@: %@", username, error.localizedDescription)
                // Keep the stored token — it may just be a network error; don't purge it.
            }
        }

        return anySuccess
    }

    // MARK: - Private

    private static func getOrCreateDeviceUUID() -> String {
        if let data = try? KeychainService.load(key: "device_uuid"),
           let uuidData = data,
           let uuid = String(data: uuidData, encoding: .utf8) {
            return uuid
        }
        let uuid = UUID().uuidString
        try? KeychainService.save(key: "device_uuid", data: Data(uuid.utf8))
        return uuid
    }
}
