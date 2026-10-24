import Foundation

/// Holds the live pawnote sessions, one per Pronote account (username).
/// Persists across views for pull-to-refresh and background sync.
///
/// A family can have children on two Pronote accounts (one per parent
/// login, or a parent space plus a student QR). Each account has its own
/// session: the former single `bridge` slot meant the last account to
/// reconnect silently replaced the previous one, and the children of the
/// first account were reported as « introuvables » at every sync.
@MainActor
final class PronoteService: ObservableObject {
    static let shared = PronoteService()

    @Published var isConnected = false
    @Published var isSyncing = false
    @Published var isReconnecting = false

    /// Why the last automatic reconnect failed, per username, in the
    /// parent's words. Empty when every stored account reopened (or none
    /// is stored). Read by the Accueil reconnect card.
    @Published private(set) var reconnectFailures: [String: String] = [:]

    private(set) var bridges: [String: PawnoteBridge] = [:]

    private init() {}

    /// Any live session, for callers that only need to know whether Pronote
    /// is reachable at all (banners, « reconnexion requise » states).
    var bridge: PawnoteBridge? { bridges.values.first }

    /// Store a session after a successful login for `username`.
    func setBridge(_ bridge: PawnoteBridge, for username: String) {
        bridges[username] = bridge
        reconnectFailures[username] = nil
        isConnected = true
    }

    func recordReconnectFailure(username: String, message: String) {
        reconnectFailures[username] = message
    }

    func clearReconnectFailures() {
        reconnectFailures = [:]
    }

    /// The session whose roster carries `child`, with the child's index in
    /// that roster. Scans every account: a SwiftData child knows its pawnote
    /// resource id, not which parent login listed it.
    func resolve(child: Child) -> (bridge: PawnoteBridge, index: Int)? {
        for bridge in bridges.values {
            if let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: bridge.getChildren()) {
                return (bridge, idx)
            }
        }
        return nil
    }

    /// Clear every session (logout / « effacer toutes les données »).
    func disconnect() {
        bridges = [:]
        reconnectFailures = [:]
        isConnected = false
    }
}
