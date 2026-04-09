import SwiftUI

/// Persists and exposes the user's preferred color scheme.
/// Inject via .environment(AppearanceManager.shared) at the root.
@Observable
@MainActor
final class AppearanceManager {
    static let shared = AppearanceManager()

    enum Preference: String, CaseIterable {
        case system = "system"
        case light  = "light"
        case dark   = "dark"

        var label: String {
            switch self {
            case .system: "Système"
            case .light:  "Clair"
            case .dark:   "Sombre"
            }
        }

        var icon: String {
            switch self {
            case .system: "iphone"
            case .light:  "sun.max"
            case .dark:   "moon"
            }
        }

        /// The SwiftUI ColorScheme to pass to .preferredColorScheme()
        /// nil means "follow the system" (no override)
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light:  .light
            case .dark:   .dark
            }
        }
    }

    private static let key = "noto_appearance"

    var preference: Preference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.key)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        preference = Preference(rawValue: saved) ?? .system
    }
}
