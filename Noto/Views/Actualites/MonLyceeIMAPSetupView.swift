import SwiftUI

/// Sheet that collects MonLycée IMAP credentials and validates them.
struct MonLyceeIMAPSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var didSucceed = false

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: NotoTheme.Spacing.lg) {
                // Header
                VStack(spacing: NotoTheme.Spacing.sm) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 48))
                        .foregroundStyle(NotoTheme.Colors.cobalt)

                    Text("MonLycée.net — Messages")
                        .font(NotoTheme.Typography.title)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)

                    Text("Entrez vos identifiants MonLycée.net pour recevoir les messages directement dans Actualités.")
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
                Label("Identifiants stockés uniquement sur votre iPhone", systemImage: "lock.shield")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(.bottom, NotoTheme.Spacing.lg)
            }
            } // ScrollView
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
        email.contains("@")
    }

    @MainActor
    private func connect() async {
        isValidating = true
        errorMessage = nil

        let creds = IMAPCredentials(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password
        )

        do {
            try await IMAPService.validate(credentials: creds)
            try IMAPService.saveCredentials(creds)
            dismiss()
        } catch {
            let msg = error.localizedDescription
            if msg.contains("Authentication") || msg.contains("LOGIN") || msg.contains("credentials") {
                errorMessage = "Identifiants incorrects. Vérifiez votre e-mail et mot de passe MonLycée."
            } else if msg.contains("network") || msg.contains("connection") || msg.contains("timeout") {
                errorMessage = "Impossible de joindre le serveur. Vérifiez votre connexion."
            } else {
                errorMessage = "Erreur : \(msg)"
            }
        }

        isValidating = false
    }
}
