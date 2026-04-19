import FamilyControls
import ManagedSettings
import Foundation

/// Manages the FamilyControls authorization lifecycle.
/// Wraps Apple's AuthorizationCenter so callers stay decoupled from the framework.
@MainActor
final class ScreenTimeManager: ObservableObject {
    static let shared = ScreenTimeManager()

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published private(set) var lastAuthorizationError: Error?

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
        lastAuthorizationError = nil
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            if let fcError = error as? FamilyControlsError, fcError == .authorizationCanceled {
                NSLog("[noto][warn] ScreenTimeManager: authorization canceled by user")
            } else {
                NSLog("[noto][error] ScreenTimeManager: authorization request failed: %@", error.localizedDescription)
                lastAuthorizationError = error
            }
        }
        refresh()
    }

    func revokeAuthorization() async {
        await AuthorizationCenter.shared.revokeAuthorization { result in
            if case .failure(let error) = result {
                Task { @MainActor in
                    NSLog("[noto][error] ScreenTimeManager: revokeAuthorization failed: %@", error.localizedDescription)
                    self.lastAuthorizationError = error
                }
            }
        }
        refresh()
    }
}
