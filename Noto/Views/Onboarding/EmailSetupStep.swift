import SwiftUI

/// Optional onboarding step to connect the parent's email account
/// (MonLycée / IMAP). Runs after school connection.
///
/// Privacy: identifiants stockés en Keychain, connexion directe
/// iPhone ↔ serveur IMAP — aucune donnée ne transite par un serveur tiers.
struct EmailSetupStep: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && email.contains("@")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                // Header
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                    Text("Votre boîte mail")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text("Recevez les emails de l'école directement dans nōto. Seuls les messages scolaires sont synchronisés.")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, NotoTheme.Spacing.xl)
                .padding(.horizontal, NotoTheme.Spacing.md)

                // Form
                VStack(spacing: NotoTheme.Spacing.sm) {
                    TextField("votre@email.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(NotoTheme.Typography.body)
                        .padding(NotoTheme.Spacing.md)
                        .background(NotoTheme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                                .stroke(NotoTheme.Colors.border, lineWidth: 0.5)
                        )

                    SecureField("Mot de passe", text: $password)
                        .textContentType(.password)
                        .font(NotoTheme.Typography.body)
                        .padding(NotoTheme.Spacing.md)
                        .background(NotoTheme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                                .stroke(NotoTheme.Colors.border, lineWidth: 0.5)
                        )
                }
                .padding(.horizontal, NotoTheme.Spacing.md)

                // Privacy row
                HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
                    Text("🔒")
                        .font(.system(size: 14))
                    Text("Connexion directe iPhone ↔ serveur mail — Aucune donnée ne passe par nos serveurs")
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm + 2)
                .background(NotoTheme.Colors.success.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: NotoTheme.Radius.card,
                        bottomLeadingRadius: NotoTheme.Radius.card
                    )
                    .fill(NotoTheme.Colors.success.opacity(0.5))
                    .frame(width: 3)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                }

                Spacer(minLength: NotoTheme.Spacing.lg)

                // Footer: step indicator + primary/secondary actions
                VStack(spacing: NotoTheme.Spacing.md) {
                    StepIndicator(currentStep: 1, totalSteps: 3)

                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if isValidating {
                                ProgressView().tint(.white)
                            } else {
                                Text("Connecter ma boîte mail")
                                    .font(NotoTheme.Typography.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.md)
                        .background(
                            isFormValid
                                ? NotoTheme.Colors.brand
                                : NotoTheme.Colors.brand.opacity(0.3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                    }
                    .disabled(!isFormValid || isValidating)

                    Button(action: onSkip) {
                        Text("Passer cette étape")
                            .font(NotoTheme.Typography.functional(13, weight: .medium))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.bottom, NotoTheme.Spacing.xl)
            }
        }
        .background(NotoTheme.Colors.background)
    }

    @MainActor
    private func connect() async {
        isValidating = true
        errorMessage = nil

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        guard let preset = IMAPProviderResolver.resolve(email: trimmedEmail) else {
            errorMessage = "Adresse e-mail invalide. Format attendu : nom@domaine.fr"
            isValidating = false
            return
        }

        let config = IMAPServerConfig(
            preset: preset,
            username: trimmedEmail,
            password: password
        )

        do {
            try await IMAPService.validate(config: config)
            try IMAPService.saveConfig(config)
            isValidating = false
            onComplete()
        } catch {
            let msg = error.localizedDescription
            if msg.contains("Authentication") || msg.contains("LOGIN") || msg.contains("credentials") {
                errorMessage = "Identifiants incorrects. Vérifiez votre e-mail et mot de passe."
            } else if msg.contains("network") || msg.contains("connection") || msg.contains("timeout") {
                errorMessage = "Impossible de joindre le serveur. Vérifiez votre connexion."
            } else {
                errorMessage = "Erreur : \(msg)"
            }
            isValidating = false
        }
    }
}

#Preview {
    EmailSetupStep(onComplete: {}, onSkip: {})
}
