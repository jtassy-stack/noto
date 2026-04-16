import SwiftUI

/// Sheet that collects IMAP credentials and validates them against
/// the provider auto-resolved from the email address.
///
/// Name kept for backward compatibility with existing call sites.
/// Despite the name, this handles any provider supported by
/// `IMAPProviderResolver` (Gmail, Outlook, iCloud, MonLycée, or a
/// `imap.{domain}:993` fallback).
struct MonLyceeIMAPSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    /// Live resolver preview — updates as the user types, so they see
    /// "Gmail" / "Outlook" / "MonLycée" picked up before they submit.
    private var resolvedPreset: IMAPServerConfig.Preset? {
        IMAPProviderResolver.resolve(email: email.trimmingCharacters(in: .whitespaces))
    }

    private var providerLabel: String {
        guard let preset = resolvedPreset else { return "Configuration automatique" }
        switch preset.providerID {
        case "gmail":    return "Gmail"
        case "outlook":  return "Outlook / Hotmail"
        case "icloud":   return "iCloud"
        case "monlycee": return "MonLycée.net"
        default:         return "Serveur : \(preset.host)"
        }
    }

    /// Providers that reject the account's main password over IMAP and
    /// require a provider-issued "app password" (or equivalent). Drives
    /// the contextual help card shown above the password field.
    private var appPasswordGuidance: AppPasswordGuidance? {
        guard let id = resolvedPreset?.providerID else { return nil }
        return AppPasswordGuidance.forProviderID(id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NotoTheme.Spacing.lg) {
                    // Header
                    VStack(spacing: NotoTheme.Spacing.sm) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.system(size: 48))
                            .foregroundStyle(NotoTheme.Colors.cobalt)

                        Text("Connecter une boîte mail")
                            .font(NotoTheme.Typography.title)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)

                        Text("Entrez votre adresse e-mail et mot de passe. nōto détecte automatiquement votre fournisseur (Gmail, Outlook, iCloud, MonLycée ou autre) et ne synchronise que les mails scolaires.")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                    }
                    .padding(.top, NotoTheme.Spacing.xl)

                    // Form
                    VStack(spacing: NotoTheme.Spacing.sm) {
                        TextField("Adresse e-mail", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(NotoTheme.Spacing.md)
                            .background(NotoTheme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))

                        SecureField("Mot de passe", text: $password)
                            .textContentType(.password)
                            .padding(NotoTheme.Spacing.md)
                            .background(NotoTheme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))

                        if !email.isEmpty && resolvedPreset != nil {
                            HStack(spacing: NotoTheme.Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(NotoTheme.Colors.green)
                                Text("Détecté : \(providerLabel)")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, NotoTheme.Spacing.xs)
                        }
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)

                    if let guidance = appPasswordGuidance {
                        AppPasswordHelpCard(guidance: guidance)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                    }

                    // Error
                    if let error = errorMessage {
                        Text(error)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.amber)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                    }

                    // Connect button
                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if isValidating {
                                ProgressView()
                                    .tint(NotoTheme.Colors.shadow)
                            } else {
                                Text("Connecter")
                                    .font(NotoTheme.Typography.headline)
                                    .foregroundStyle(NotoTheme.Colors.shadow)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(NotoTheme.Spacing.md)
                        .background(isFormValid ? NotoTheme.Colors.cobalt : NotoTheme.Colors.cobalt.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                    }
                    .disabled(!isFormValid || isValidating)
                    .padding(.horizontal, NotoTheme.Spacing.md)

                    // Privacy note
                    Label("Connexion directe — identifiants stockés uniquement sur votre iPhone, aucune donnée ne transite par nos serveurs.", systemImage: "lock.shield")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.bottom, NotoTheme.Spacing.lg)
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        resolvedPreset != nil
    }

    @MainActor
    private func connect() async {
        isValidating = true
        errorMessage = nil
        defer { isValidating = false }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard let preset = IMAPProviderResolver.resolve(email: trimmedEmail) else {
            errorMessage = "Adresse e-mail invalide. Format attendu : nom@domaine.fr"
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
            dismiss()
        } catch {
            let msg = error.localizedDescription.lowercased()
            // Gmail/iCloud/Outlook reject the account's main password with
            // provider-specific text ("application-specific password
            // required", "web login required", …). Surface the app-password
            // guidance explicitly so the user doesn't re-enter the same
            // wrong credential.
            let needsAppPassword =
                msg.contains("application-specific password") ||
                msg.contains("app password") ||
                msg.contains("web login required") ||
                msg.contains("invalidsecondfactor")
            if needsAppPassword, let guidance = AppPasswordGuidance.forProviderID(preset.providerID) {
                errorMessage = "\(guidance.label) refuse votre mot de passe de compte. Utilisez un mot de passe d'application (voir ci-dessus)."
            } else if msg.contains("authentication") || msg.contains("login") || msg.contains("credentials") {
                if let guidance = AppPasswordGuidance.forProviderID(preset.providerID) {
                    errorMessage = "Identifiants refusés. \(guidance.label) demande un mot de passe d'application (voir ci-dessus), pas votre mot de passe de compte."
                } else {
                    errorMessage = "Identifiants incorrects. Vérifiez votre e-mail et mot de passe."
                }
            } else if msg.contains("network") || msg.contains("connection") || msg.contains("timeout") {
                if preset.providerID == "custom" {
                    errorMessage = "Impossible de joindre \(preset.host). Vérifiez votre adresse e-mail ou votre connexion."
                } else {
                    errorMessage = "Impossible de joindre le serveur. Vérifiez votre connexion."
                }
            } else {
                errorMessage = "Erreur : \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - App-password guidance

/// Providers that force third-party IMAP clients to use a short-lived
/// app-specific password instead of the account's main password. For
/// Gmail/iCloud/Outlook this is non-optional — basic IMAP LOGIN with the
/// account password has been disabled on consumer accounts since ~2022.
///
/// Rendered by `AppPasswordHelpCard` above the password field so users
/// don't waste a login attempt with their main password.
struct AppPasswordGuidance: Equatable {
    let label: String                // "Gmail", "iCloud", …
    let requiresTwoFactor: Bool      // true for Gmail; iCloud/Outlook may vary
    let setupURL: URL
    let steps: [String]

    static func forProviderID(_ id: String) -> AppPasswordGuidance? {
        switch id {
        case "gmail":
            return AppPasswordGuidance(
                label: "Gmail",
                requiresTwoFactor: true,
                setupURL: URL(string: "https://myaccount.google.com/apppasswords")!,
                steps: [
                    "Activez la validation en deux étapes sur votre compte Google (obligatoire).",
                    "Ouvrez la page “Mots de passe des applications” Google.",
                    "Créez un mot de passe pour “nōto” et copiez les 16 caractères.",
                    "Collez-le dans le champ Mot de passe ci-dessous."
                ]
            )
        case "icloud":
            return AppPasswordGuidance(
                label: "iCloud",
                requiresTwoFactor: true,
                setupURL: URL(string: "https://account.apple.com/account/manage")!,
                steps: [
                    "Ouvrez appleid.apple.com et connectez-vous.",
                    "Dans “Sécurité”, créez un mot de passe pour une app (“nōto”).",
                    "Copiez le mot de passe généré.",
                    "Collez-le dans le champ Mot de passe ci-dessous."
                ]
            )
        case "outlook":
            return AppPasswordGuidance(
                label: "Outlook / Hotmail",
                requiresTwoFactor: true,
                setupURL: URL(string: "https://account.microsoft.com/security/app-passwords")!,
                steps: [
                    "Activez la validation en deux étapes sur votre compte Microsoft.",
                    "Ouvrez la page “Mots de passe d'application”.",
                    "Créez un mot de passe pour “nōto” et copiez-le.",
                    "Collez-le dans le champ Mot de passe ci-dessous."
                ]
            )
        default:
            return nil
        }
    }
}

private struct AppPasswordHelpCard: View {
    let guidance: AppPasswordGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack(spacing: NotoTheme.Spacing.xs) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(NotoTheme.Colors.cobalt)
                Text("\(guidance.label) demande un mot de passe d'application")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }

            Text("Votre mot de passe de compte \(guidance.label) ne fonctionne pas avec les apps de mail tierces. Générez un mot de passe d'application — c'est gratuit, ça prend 2 minutes.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: NotoTheme.Spacing.xs) {
                        Text("\(index + 1).")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .frame(width: 16, alignment: .leading)
                        Text(step)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Link(destination: guidance.setupURL) {
                HStack(spacing: NotoTheme.Spacing.xs) {
                    Text("Ouvrir la page \(guidance.label)")
                        .font(NotoTheme.Typography.caption)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .foregroundStyle(NotoTheme.Colors.cobalt)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
    }
}
