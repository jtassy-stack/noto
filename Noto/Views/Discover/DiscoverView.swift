import SwiftUI

struct DiscoverView: View {
    let selectedChild: Child?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Découvrir",
                systemImage: "safari",
                description: Text("Des recommandations culturelles adaptées aux cours et centres d'intérêt.")
            )
            .navigationTitle("Découvrir")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
