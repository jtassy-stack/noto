import SwiftUI
import SwiftData

struct RootView: View {
    @Query private var families: [Family]
    @State private var showAddChild = false
    @Environment(\.modelContext) private var modelContext

    private var family: Family? { families.first }

    var body: some View {
        Group {
            if families.isEmpty {
                OnboardingView()
            } else if family?.children.isEmpty == true {
                // Family exists but no children yet — prompt to add
                VStack(spacing: NotoTheme.Spacing.xl) {
                    Spacer()
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(NotoTheme.Colors.brand)
                    Text("Ajoutez votre premier enfant")
                        .font(NotoTheme.Typography.title)
                    Text("Connectez un compte Pronote ou ENT pour commencer.")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, NotoTheme.Spacing.xl)
                    Button {
                        showAddChild = true
                    } label: {
                        Text("Ajouter un enfant")
                            .font(NotoTheme.Typography.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotoTheme.Colors.brand)
                    .padding(.horizontal, NotoTheme.Spacing.xl)
                    Spacer()
                }
                .sheet(isPresented: $showAddChild) {
                    AddChildView()
                }
            } else {
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Attempt silent reconnect on every launch using stored refresh tokens.
            // Runs in background — UI is not blocked.
            await PronoteAutoConnect.autoConnect(modelContext: modelContext)
        }
    }
}
