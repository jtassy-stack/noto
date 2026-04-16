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
            if msg.contains("authentication") || msg.contains("login") || msg.contains("credentials") {
                errorMessage = "Identifiants incorrects. Vérifiez votre e-mail et mot de passe."
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
