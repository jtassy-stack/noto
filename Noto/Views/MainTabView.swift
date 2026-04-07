import SwiftUI
import SwiftData

struct MainTabView: View {
    @Query private var families: [Family]
    @State private var selectedTab: Tab = .home
    @State private var selectedChild: Child?

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            // Fratrie selector
            ChildSelectorBar(
                children: children,
                selectedChild: $selectedChild
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

                InsightsView(selectedChild: selectedChild)
                    .tabItem {
                        Label("Suivi", systemImage: "chart.xyaxis.line")
                    }
                    .tag(Tab.insights)
            }
            .tint(NotoTheme.Colors.brand)
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
