import FamilyControls
import ManagedSettings
import Foundation

/// Manages the FamilyControls authorization lifecycle.
/// Wraps Apple's AuthorizationCenter so callers stay decoupled from the framework.
@MainActor
final class ScreenTimeManager: ObservableObject {
    static let shared = ScreenTimeManager()

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined

    private init() {
        refresh()
    }

    var isAuthorized: Bool { authorizationStatus == .approved }

    func refresh() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    }

    /// Requests FamilyControls authorization for the individual (child on this device).
    /// Call from a user gesture — iOS will show a system alert.
    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            NSLog("[noto][warn] ScreenTimeManager: authorization request failed: %@", error.localizedDescription)
        }
        refresh()
    }

    func revokeAuthorization() async {
        await AuthorizationCenter.shared.revokeAuthorization(completionHandler: { _ in })
        refresh()
    }
}
