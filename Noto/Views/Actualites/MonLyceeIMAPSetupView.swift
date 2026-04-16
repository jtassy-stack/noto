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

    /// True once the user has typed a monlycée address. Drives the
    /// "dedicated channel" framing — copy + title change to convey
    /// that this is a school-parent channel rather than a generic
    /// inbox about to be filtered.
    private var isDedicatedSchoolChannel: Bool {
        resolvedPreset?.isDedicatedSchoolChannel ?? false
    }

    private var headerTitle: String {
        isDedicatedSchoolChannel
            ? "Connecter MonLycée.net"
            : "Connecter une boîte mail"
    }

    private var headerSubtitle: String {
        if isDedicatedSchoolChannel {
            return "MonLycée.net est le canal officiel de communication entre votre lycée et vous. Tous les messages reçus dans cette boîte sont affichés dans nōto — aucun courrier personnel n'y transite."
        }
        return "Entrez votre adresse e-mail et mot de passe. nōto détecte automatiquement votre fournisseur (Gmail, Outlook, iCloud, MonLycée ou autre) et ne synchronise que les mails scolaires."
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
                        Image(systemName: isDedicatedSchoolChannel
                              ? "building.columns"
                              : "envelope.badge.shield.half.filled")
                            .font(.system(size: 48))
                            .foregroundStyle(NotoTheme.Colors.cobalt)

                        Text(headerTitle)
                            .font(NotoTheme.Typography.title)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)

                        Text(headerSubtitle)
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
            errorMessage = AppPasswordGuidance.userErrorMessage(for: error, preset: preset)
        }
    }
}

// MARK: - App-password guidance

/// Providers that force third-party IMAP clients to use a short-lived
/// app-specific password instead of the account's main password. Basic
/// IMAP LOGIN with the account password has been disabled for years on
/// these providers (Gmail May 2022, iCloud since 2017 when 2FA became
/// mandatory, Outlook.com rolling through 2022–2023).
///
/// Rendered by `AppPasswordHelpCard` above the password field so users
/// don't waste a login attempt with their main password. The init is
/// private so instances can only come from the curated `forProviderID`
/// factory — no empty `steps` or empty `label` can be fabricated.
struct AppPasswordGuidance: Equatable {
    let label: String
    let setupURL: URL
    let steps: [String]

    private init(label: String, setupURL: URL, steps: [String]) {
        self.label = label
        self.setupURL = setupURL
        self.steps = steps
    }

    static func forProviderID(_ id: String) -> AppPasswordGuidance? {
        switch id {
        case "gmail":
            return AppPasswordGuidance(
                label: "Gmail",
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

    /// Maps an IMAP `validate`/`saveConfig` failure to a parent-addressed
    /// French message. Extracted from the view so the classification
    /// logic (which branch is chosen for which error text) can be tested
    /// without spinning up SwiftUI or mocking `IMAPService`.
    static func userErrorMessage(for error: Error, preset: IMAPServerConfig.Preset) -> String {
        let msg = error.localizedDescription.lowercased()
        let guidance = forProviderID(preset.providerID)

        // Tight match on provider-specific "you used the wrong kind of
        // password" signatures. Bare "app password" is intentionally not
        // matched — it would false-positive on "app password expired" or
        // "app password rate-limited" which are different failure modes.
        let needsAppPasswordHint =
            msg.contains("application-specific password") ||
            msg.contains("web login required") ||
            msg.contains("invalidsecondfactor")

        if needsAppPasswordHint, let g = guidance {
            return "\(g.label) refuse votre mot de passe de compte. Utilisez un mot de passe d'application (voir l'aide ci-dessus)."
        }
        if msg.contains("authentication") || msg.contains("login") || msg.contains("credentials") {
            if let g = guidance {
                // User likely followed the guidance but typoed the 16-char
                // code — don't send them back to regenerate a fresh one.
                return "Mot de passe refusé. Vérifiez que votre mot de passe d'application \(g.label) a bien été copié sans espace (voir l'aide ci-dessus)."
            }
            return "Identifiants incorrects. Vérifiez votre e-mail et mot de passe."
        }
        if msg.contains("network") || msg.contains("connection") || msg.contains("timeout") {
            if preset.providerID == "custom" {
                return "Impossible de joindre \(preset.host). Vérifiez votre adresse e-mail ou votre connexion."
            }
            return "Impossible de joindre le serveur. Vérifiez votre connexion."
        }
        // Raw `localizedDescription` is often an English SSL/TLS string —
        // wrap it so the parent doesn't see "errSSLPeerHandshakeFail" bare.
        return "Une erreur inattendue est survenue. Détail technique : \(error.localizedDescription)"
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
