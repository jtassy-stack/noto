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

                NotoLogo(size: 48)

                Text("l'essentiel de la scolarité,\nen un coup d'œil.")
                    .font(NotoTheme.Typography.human(18))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: NotoTheme.Spacing.md) {
                    TextField("Votre prénom", text: $parentName)
                        .font(NotoTheme.Typography.body)
                        .padding(NotoTheme.Spacing.md)
                        .background(NotoTheme.Colors.card)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                                .stroke(NotoTheme.Colors.border, lineWidth: 0.5)
                        )

                    Button {
                        createFamilyAndAddChild()
                    } label: {
                        Text("Commencer")
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(NotoTheme.Colors.shadow)
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

#Preview("Onboarding") {
    OnboardingView()
        .modelContainer(PreviewData.container)
}
