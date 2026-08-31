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

    @State private var step: Step = .role
    @State private var parentName = ""
    @State private var showAddChild = false
    @State private var emailConfigured = false

    private enum Step {
        case role
        case parentGateSetup
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
            case .role:
                roleScreen
            case .parentGateSetup:
                ParentGateView(mode: .setUp, onComplete: { _ in step = .welcome }, onCancel: { step = .role })
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
            if let family = families.first, !family.children.isEmpty, step == .role || step == .welcome {
                emailConfigured = IMAPService.isConfigured
                step = emailConfigured ? .summary : .email
            }
        }
    }

    // MARK: - Role screen (step 0)

    private var roleScreen: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.xl) {
                Spacer()

                NotoLogo(size: 48)

                VStack(spacing: NotoTheme.Spacing.sm) {
                    Text("Qui utilise nōto sur cet appareil ?")
                        .font(NotoTheme.Typography.title)
                        .multilineTextAlignment(.center)
                    Text("Si toute la famille utilise le même téléphone, choisissez « parent ».")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, NotoTheme.Spacing.xl)

                Spacer()

                VStack(spacing: NotoTheme.Spacing.md) {
                    Button {
                        DeviceMode.current = .parent
                        step = .welcome
                    } label: {
                        roleCard(icon: "figure.2.and.child.holdinghands", title: "Un parent", subtitle: "Suivi scolaire, réglages, temps d'écran")
                    }
                    .buttonStyle(.plain)

                    Button {
                        DeviceMode.current = .child
                        step = .parentGateSetup
                    } label: {
                        roleCard(icon: "person.fill", title: "Un enfant", subtitle: "Emploi du temps et temps d'écran")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, NotoTheme.Spacing.xl)
                .padding(.bottom, NotoTheme.Spacing.xl)
            }
        }
    }

    private func roleCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(NotoTheme.Colors.brand)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: NotoTheme.Radius.card)
                .stroke(NotoTheme.Colors.border, lineWidth: 0.5)
        )
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
        // Child-mode device: exactly one child uses this phone, so link it
        // for Screen Time attribution automatically — no need to make a
        // kid navigate Settings to pick themselves from a list.
        if DeviceMode.current == .child, let child = family.children.last {
            ScreenTimeEventStore.storeLinkedChildID("\(child.id)")
        }
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
