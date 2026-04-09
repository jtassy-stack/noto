import SwiftUI
import SwiftData

struct MainTabView: View {
    @Query private var families: [Family]
    @State private var selectedTab: Tab = .home
    @State private var selectedChild: Child?
    @State private var showAddChild = false

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

    private var urgentHomeworkBadge: Int {
        let in24h = Date.now.addingTimeInterval(86_400)
        let scope = selectedChild.map { [$0] } ?? children
        return scope.flatMap(\.homework).filter { !$0.done && $0.dueDate <= in24h }.count
    }

    private var unreadMessagesBadge: Int {
        let scope = selectedChild.map { [$0] } ?? children
        return scope.flatMap(\.messages).filter { !$0.read }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fratrie selector
            ChildSelectorBar(
                children: children,
                selectedChild: $selectedChild,
                onAddChild: { showAddChild = true }
            )

            // Tab content
            TabView(selection: $selectedTab) {
                HomeView(selectedChild: selectedChild)
                    .tabItem {
                        Label("Accueil", systemImage: "house")
                    }
                    .tag(Tab.home)

                ActualitesView()
                    .tabItem {
                        Label("Actualités", systemImage: "newspaper")
                    }
                    .badge(unreadMessagesBadge)
                    .tag(Tab.actualites)

                SchoolView(selectedChild: selectedChild)
                    .tabItem {
                        Label("École", systemImage: "book")
                    }
                    .badge(urgentHomeworkBadge)
                    .tag(Tab.school)

                DiscoverView(selectedChild: selectedChild)
                    .tabItem {
                        Label("Découvrir", systemImage: "safari")
                    }
                    .tag(Tab.discover)
            }
            .tint(NotoTheme.Colors.brand)
        }
        .background(NotoTheme.Colors.background.ignoresSafeArea())
        .sheet(isPresented: $showAddChild) {
            AddChildView()
        }
        .onAppear { configureTabBarAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selectedTab = .home
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(NotoTheme.Colors.shadow)
        appearance.shadowColor = UIColor(white: 1, alpha: 0.08)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - Tab

enum Tab: String {
    case home
    case actualites
    case school
    case discover
}

// MARK: - Notification Names

extension Notification.Name {
    static let navigateToHome = Notification.Name("noto.navigateToHome")
    static let navigateToHomework = Notification.Name("noto.navigateToHomework")
    static let navigateToDiscover = Notification.Name("noto.navigateToDiscover")
}

#Preview("MainTabView") {
    MainTabView()
        .withPreviewData()
}
