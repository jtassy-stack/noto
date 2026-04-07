import Foundation

/// Singleton that holds the active pawnote bridge session.
/// Persists across views for pull-to-refresh and background sync.
@MainActor
final class PronoteService: ObservableObject {
    static let shared = PronoteService()

    @Published var isConnected = false
    @Published var isSyncing = false

    private(set) var bridge: PawnoteBridge?

    private init() {}

    /// Store bridge after successful login.
    func setBridge(_ bridge: PawnoteBridge) {
        self.bridge = bridge
        self.isConnected = true
    }

    /// Clear session (logout).
    func disconnect() {
        bridge = nil
        isConnected = false
    }
}
