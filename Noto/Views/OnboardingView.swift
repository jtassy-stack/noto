import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @State private var parentName = ""
    @State private var showAddChild = false

    var body: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.xl) {
                Spacer()

                Text("nōto.")
                    .font(.system(size: 48, weight: .bold, design: .serif))

                Text("Le suivi scolaire\npensé pour les parents.")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: NotoTheme.Spacing.md) {
                    TextField("Votre prénom", text: $parentName)
                        .textFieldStyle(.roundedBorder)
                        .font(NotoTheme.Typography.body)

                    Button {
                        createFamilyAndAddChild()
                    } label: {
                        Text("Commencer")
                            .font(NotoTheme.Typography.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotoTheme.Colors.brand)
                    .disabled(parentName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, NotoTheme.Spacing.xl)
                .padding(.bottom, NotoTheme.Spacing.xl)
            }
            .sheet(isPresented: $showAddChild) {
                AddChildView()
            }
        }
    }

    private func createFamilyAndAddChild() {
        let family = Family(parentName: parentName.trimmingCharacters(in: .whitespaces))
        context.insert(family)
        try? context.save()
        showAddChild = true
    }
}
