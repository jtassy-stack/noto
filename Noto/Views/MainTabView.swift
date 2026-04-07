import SwiftUI
import SwiftData

struct MainTabView: View {
    @Query private var families: [Family]
    @State private var selectedTab: Tab = .home
    @State private var selectedChild: Child?
    @State private var showAddChild = false

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

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

                SchoolView(selectedChild: selectedChild)
                    .tabItem {
                        Label("École", systemImage: "book")
                    }
                    .tag(Tab.school)

                DiscoverView(selectedChild: selectedChild)
                    .tabItem {
                        Label("Découvrir", systemImage: "safari")
                    }
                    .tag(Tab.discover)

                InsightsView(
                    selectedChild: selectedChild,
                    onNavigateToHomework: {
                        // Navigate to School tab, Devoirs section
                        NotificationCenter.default.post(name: .navigateToHomework, object: nil)
                        selectedTab = .school
                    },
                    onNavigateToDiscover: { subject in
                        // Deep link to Discover tab with subject filter
                        NotificationCenter.default.post(name: .navigateToDiscover, object: subject)
                        selectedTab = .discover
                    }
                )
                .tabItem {
                    Label("Suivi", systemImage: "chart.xyaxis.line")
                }
                .tag(Tab.insights)
            }
            .tint(NotoTheme.Colors.brand)
        }
        .sheet(isPresented: $showAddChild) {
            AddChildView()
        }
    }
}

// MARK: - Tab

enum Tab: String {
    case home
    case school
    case discover
    case insights
}

// MARK: - Notification Names

extension Notification.Name {
    static let navigateToHomework = Notification.Name("noto.navigateToHomework")
    static let navigateToDiscover = Notification.Name("noto.navigateToDiscover")
}
