import SwiftUI

struct SchoolView: View {
    let selectedChild: Child?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "École",
                systemImage: "book.closed",
                description: Text("Connectez un compte Pronote ou ENT pour voir les données scolaires.")
            )
            .navigationTitle("École")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
