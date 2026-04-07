import SwiftUI

struct InsightsView: View {
    let selectedChild: Child?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Suivi",
                systemImage: "chart.xyaxis.line",
                description: Text("Tendances, progressions et signaux de bien-être — analysés sur l'appareil.")
            )
            .navigationTitle("Suivi")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
