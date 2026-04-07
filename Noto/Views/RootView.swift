import SwiftUI
import SwiftData

struct RootView: View {
    @Query private var families: [Family]

    var body: some View {
        if families.isEmpty {
            OnboardingView()
        } else {
            MainTabView()
        }
    }
}
