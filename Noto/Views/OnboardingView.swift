import SwiftUI
import SwiftData

/// Multi-step onboarding flow.
///
/// Steps:
///   0 — Welcome + parent name input → creates Family, launches AddChild sheet
///   1 — Email setup (optional, can be skipped)
///   2 — Summary recap + finish
///
/// Completion is tracked via `@AppStorage("onboarding_complete")` which
/// RootView consults alongside `families.isEmpty`. Defaulted to `true` so
/// upgrading users aren't sent back through onboarding.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Query private var families: [Family]

    @AppStorage("onboarding_complete") private var onboardingComplete: Bool = true

    @State private var step: Step = .welcome
    @State private var parentName = ""
    @State private var showAddChild = false
    @State private var emailConfigured = false

    private enum Step {
        case welcome
        case email
        case summary
    }

    private var latestChild: Child? {
        families.first?.children.last
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                welcomeScreen
            case .email:
                EmailSetupStep(
                    onComplete: {
                        emailConfigured = true
                        step = .summary
                    },
                    onSkip: { step = .summary }
                )
            case .summary:
                OnboardingSummaryStep(
                    child: latestChild,
                    emailConfigured: emailConfigured,
                    onFinish: finish
                )
            }
        }
        .task {
            // Mark onboarding incomplete while this view is visible so a
            // cold launch mid-flow returns here (RootView gate).
            onboardingComplete = false
            // Resume mid-flow: if a Family+Child already exist (user
            // force-quit after AddChild dismissed), jump straight to
            // EmailSetupStep instead of redoing the welcome screen.
            if let family = families.first, !family.children.isEmpty, step == .welcome {
                emailConfigured = IMAPService.loadCredentials() != nil
                step = emailConfigured ? .summary : .email
            }
        }
    }

    // MARK: - Welcome screen (step 0)

    private var welcomeScreen: some View {
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
                            .foregroundStyle(.white)
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
            .sheet(isPresented: $showAddChild, onDismiss: handleAddChildDismiss) {
                AddChildView()
            }
        }
    }

    // MARK: - Actions

    private func createFamilyAndAddChild() {
        // Reuse an existing Family if present (resume case) rather than
        // inserting a second one.
        if families.isEmpty {
            let family = Family(parentName: parentName.trimmingCharacters(in: .whitespaces))
            context.insert(family)
            try? context.save()
        }
        showAddChild = true
    }

    /// Called when the AddChildView sheet closes.
    /// Proceeds to the email step only if a child was actually added.
    private func handleAddChildDismiss() {
        guard let family = families.first, !family.children.isEmpty else { return }
        step = .email
    }

    private func finish() {
        onboardingComplete = true
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .modelContainer(PreviewData.container)
}
