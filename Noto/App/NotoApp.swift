import SwiftUI
import SwiftData
import TipKit

@main
struct NotoApp: App {
    private let appearance = AppearanceManager.shared

    private let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: NotoSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: NotoMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        try? Tips.configure()
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.preference.colorScheme)
                .environment(appearance)
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Global UIKit appearance

    private func configureAppearance() {
        let paper  = UIColor(hex: 0xF5F3EE)   // Paper light bg
        let shadow = UIColor(hex: 0x0A0A08)   // Shadow dark bg / text
        let brand  = UIColor(hex: 0x5BD45B)   // 1-Up green

        let adaptive: (UIColor, UIColor) -> UIColor = { dark, light in
            UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }

        // Navigation bar — Paper/Shadow bg, Space Mono titles
        let navBg = adaptive(shadow, paper)
        let navText = adaptive(paper, shadow)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = navBg
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [
            .foregroundColor: navText,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        navAppearance.largeTitleTextAttributes = [
            .foregroundColor: navText,
            .font: UIFont.systemFont(ofSize: 28, weight: .semibold)
        ]
        UINavigationBar.appearance().standardAppearance  = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance   = navAppearance
        UINavigationBar.appearance().tintColor           = brand

        // Tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = navBg
        UITabBar.appearance().standardAppearance   = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor            = brand

        // List / Settings — Paper background in light
        UITableView.appearance().backgroundColor = navBg
        UITableViewCell.appearance().backgroundColor = adaptive(UIColor(hex: 0x222222), UIColor(hex: 0xFDFCF9))
    }
}
