import SwiftUI

/// One-time setup screen for MonLycée IMAP.
/// Shown inline in the Messages tab when no credentials are stored.
struct MailboxSetupView: View {
    let onComplete: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.lg) {
            VStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 44))
                    .foregroundStyle(NotoTheme.Colors.brand)

                Text("Messagerie MonLycée")
                    .font(NotoTheme.Typography.title)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                Text("Entrez vos identifiants MonLycée pour accéder aux messages de l'école.\nVos informations restent sur cet appareil.")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: NotoTheme.Spacing.sm) {
                TextField("Adresse e-mail", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .padding(NotoTheme.Spacing.md)
                    .background(NotoTheme.Colors.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))

                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                    .padding(NotoTheme.Spacing.md)
                    .background(NotoTheme.Colors.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
            }

            if let error = errorMessage {
                Text(error)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.danger)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await connect() }
            } label: {
                Group {
                    if isConnecting {
                        ProgressView()
                            .tint(NotoTheme.Colors.shadow)
                    } else {
                        Text("Connexion")
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(NotoTheme.Colors.shadow)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NotoTheme.Spacing.md)
                .background(canConnect ? NotoTheme.Colors.brand : NotoTheme.Colors.brand.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
            }
            .disabled(!canConnect || isConnecting)
        }
        .padding(NotoTheme.Spacing.xl)
    }

    private var canConnect: Bool {
        !email.isEmpty && !password.isEmpty && email.contains("@")
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let creds = IMAPCredentials(email: email, password: password)
        do {
            try await IMAPService.validate(credentials: creds)
            try IMAPService.saveCredentials(creds)
            onComplete()
        } catch {
            errorMessage = "Connexion échouée. Vérifiez vos identifiants."
        }
    }
}
