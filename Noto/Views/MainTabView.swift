import SwiftUI
import SwiftData

struct MainTabView: View {
    @Query private var families: [Family]
    @State private var selectedTab: Tab = .home
    @State private var showAddChild = false

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

    private var urgentHomeworkBadge: Int {
        let in24h = Date.now.addingTimeInterval(86_400)
        return children.flatMap(\.homework).filter { !$0.done && $0.dueDate <= in24h }.count
    }

    private var unreadMessagesBadge: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .conversation }.count
    }

    private var unsignedCarnetsCount: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .schoolbook }.count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(onAddChild: { showAddChild = true })
                .tabItem {
                    Label("Accueil", systemImage: "house")
                }
                .tag(Tab.home)

            ActualitesView()
                .tabItem {
                    Label("Messages", systemImage: "newspaper")
                }
                .badge(unreadMessagesBadge + unsignedCarnetsCount)
                .tag(Tab.actualites)

            SchoolView()
                .tabItem {
                    Label("École", systemImage: "book")
                }
                .badge(urgentHomeworkBadge)
                .tag(Tab.school)

            DiscoverView()
                .tabItem {
                    Label("Découvrir", systemImage: "safari")
                }
                .tag(Tab.discover)
        }
        .tint(NotoTheme.Colors.brand)
        .background(NotoTheme.Colors.background.ignoresSafeArea())
        .sheet(isPresented: $showAddChild) {
            AddChildView()
        }
        .onAppear { configureTabBarAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selectedTab = .home
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMessages)) { _ in
            selectedTab = .actualites
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSchool)) { _ in
            selectedTab = .school
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDiscover)) { _ in
            selectedTab = .discover
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
    static let navigateToHome     = Notification.Name("noto.navigateToHome")
    static let navigateToMessages = Notification.Name("noto.navigateToMessages")
    static let navigateToSchool   = Notification.Name("noto.navigateToSchool")
    static let navigateToDiscover = Notification.Name("noto.navigateToDiscover")
    /// Request a full sync from any surface. HomeView observes it and runs
    /// `performFullRefresh()`. Pair with `navigateToHome` when the caller
    /// also wants the user to see the result.
    static let triggerFullSync    = Notification.Name("noto.triggerFullSync")
    /// Posted after ENT cookies are imported and the session is valid.
    /// PhotoGridView observes this to retry thumbnail loading.
    static let entSessionReady    = Notification.Name("noto.entSessionReady")
}

#Preview("App — Dark") {
    MainTabView().withPreviewData().preferredColorScheme(.dark)
}

#Preview("App — Light") {
    MainTabView().withPreviewData().preferredColorScheme(.light)
}
