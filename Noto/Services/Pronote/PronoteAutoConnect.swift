import Foundation
import SwiftData

/// Attempts to silently restore the Pronote sessions on app launch
/// using stored refresh tokens — no QR scan required after first login.
@MainActor
enum PronoteAutoConnect {

    /// The auto-connect currently running, if any. Concurrent callers
    /// (RootView's launch task, a sync that finds the bridge missing) await
    /// this one instead of starting a second login with the same single-use
    /// refresh token.
    private static var inFlight: Task<Bool, Never>?

    /// Try to reconnect using all stored refresh tokens.
    /// Returns `true` if at least one account reconnected successfully.
    /// Re-entrant: a call made while another is in progress shares its result.
    @discardableResult
    static func autoConnect(modelContext: ModelContext) async -> Bool {
        if PronoteService.shared.bridge != nil { return true }
        if let inFlight { return await inFlight.value }

        let task = Task<Bool, Never> { await performAutoConnect() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    private static func performAutoConnect() async -> Bool {
        let service = PronoteService.shared
        let accounts = PronoteAccountStore.all()
        let unreadable = PronoteAccountStore.unreadableUsernames
        guard !accounts.isEmpty || !unreadable.isEmpty else { return false }

        service.isReconnecting = true
        defer { service.isReconnecting = false }

        for username in unreadable {
            // Listed but no readable token: typically an app reinstall (the
            // Keychain items are ThisDeviceOnly). Say so instead of a silent skip.
            service.recordReconnectFailure(
                username: username,
                message: "Identifiants Pronote introuvables sur cet appareil. Rescannez le QR code."
            )
        }

        let deviceUUID = PronoteAccountStore.deviceUUID()
        var anySuccess = false

        for stored in accounts {
            // One attempt per account and per launch: a refused token is
            // refused again, and repeated attempts get the IP suspended.
            do {
                let bridge = try PawnoteBridge()
                let renewed = try await bridge.loginWithToken(stored, deviceUUID: deviceUUID)

                // The token Pronote just handed out replaces the single-use
                // one we presented. Failing to persist it means the next
                // launch replays a dead token, so this is a real failure.
                try PronoteAccountStore.save(renewed)

                service.setBridge(bridge, for: renewed.username)
                anySuccess = true
                NSLog("[noto] Auto-reconnect succeeded (kind=%d, navigator=%@)",
                      renewed.kind.rawValue, renewed.navigatorIdentifier == nil ? "none" : "kept")
            } catch {
                let message = userMessage(for: error)
                service.recordReconnectFailure(username: stored.username, message: message)
                NSLog("[noto] Auto-reconnect failed: %@", error.localizedDescription)
                // Keep the stored token: a network error is not a refusal,
                // and the parent decides when to rescan.
            }
        }

        return anySuccess
    }

    /// A short, parent-facing reason shown on the Accueil reconnect card.
    static func userMessage(for error: Error) -> String {
        if let pronoteError = error as? PronoteError {
            switch pronoteError {
            case .doubleAuthRequired:
                return pronoteError.localizedDescription
            case .suspendedIP, .rateLimited:
                return "Pronote limite les connexions pour le moment. Réessayez dans quelques minutes."
            case .networkError:
                return "Pronote est injoignable. Vérifiez votre connexion."
            default:
                break
            }
        }
        let raw = error.localizedDescription.lowercased()
        if raw.contains("network") || raw.contains("timeout") || raw.contains("connexion")
            || raw.contains("offline") || raw.contains("internet") {
            return "Pronote est injoignable. Vérifiez votre connexion."
        }
        return "Pronote a refusé la reconnexion automatique. Rescannez le QR code pour rouvrir la session."
    }
}
