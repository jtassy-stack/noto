import SwiftUI
import SwiftData

struct ENTLoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var family: Family? { families.first }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Connexion ENT")
            } footer: {
                Text("Utilisez vos identifiants Paris Classe Numérique.")
                    .font(NotoTheme.Typography.caption)
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(NotoTheme.Colors.danger)
                }
            }

            Section {
                Button {
                    Task { await login() }
                } label: {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Se connecter")
                                .font(NotoTheme.Typography.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(email.isEmpty || password.isEmpty || isLoading)
            }
        }
        .navigationTitle("ENT")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func login() async {
        isLoading = true
        errorMessage = nil

        let client = ENTClient()

        do {
            try await client.login(email: email, password: password)

            // Store credentials in Keychain
            let creds = "\(email):\(password)"
            try? KeychainService.save(key: "ent_credentials", data: Data(creds.utf8))

            // Fetch children
            let entChildren = try await client.fetchChildren()

            guard let family else { return }

            if entChildren.isEmpty {
                // No children found — create one with email as name
                let child = Child(
                    firstName: email.components(separatedBy: "@").first ?? "Enfant",
                    level: .elementaire,
                    grade: "?",
                    schoolType: .ent,
                    establishment: "Paris Classe Numérique"
                )
                child.family = family
                modelContext.insert(child)
            } else {
                for ec in entChildren {
                    let child = Child(
                        firstName: ec.displayName.components(separatedBy: " ").first ?? ec.displayName,
                        level: inferLevel(from: ec.className),
                        grade: inferGrade(from: ec.className),
                        schoolType: .ent,
                        establishment: "Paris Classe Numérique"
                    )
                    child.family = family
                    modelContext.insert(child)
                }
            }

            try? modelContext.save()
            dismiss()
        } catch let error as ENTError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Erreur : \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func inferLevel(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        if lower.contains("ps") || lower.contains("ms") || lower.contains("gs") {
            return .maternelle
        }
        if lower.contains("cp") || lower.contains("ce") || lower.contains("cm") {
            return .elementaire
        }
        return .elementaire
    }

    private func inferGrade(from className: String) -> String {
        let patterns = ["PS", "MS", "GS", "CP", "CE1", "CE2", "CM1", "CM2"]
        let upper = className.uppercased()
        for p in patterns {
            if upper.contains(p) { return p }
        }
        return className.prefix(4).trimmingCharacters(in: .whitespaces)
    }
}
