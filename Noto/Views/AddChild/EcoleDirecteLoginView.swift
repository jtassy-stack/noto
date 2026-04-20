import SwiftUI
import SwiftData

struct EcoleDirecteLoginView: View {
    var onDismissAll: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var family: Family? { families.first }

    var body: some View {
        Form {
            Section {
                TextField("Identifiant", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Connexion École Directe")
            } footer: {
                Text("Utilisez vos identifiants du portail École Directe (ecoledirecte.com). Vos identifiants sont chiffrés localement — ils ne transitent jamais par nos serveurs.")
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
                    Task { await performLogin() }
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
                .disabled(username.isEmpty || password.isEmpty || isLoading)
            }
        }
        .navigationTitle("École Directe")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Login

    @MainActor
    private func performLogin() async {
        isLoading = true
        errorMessage = nil

        guard let family else {
            errorMessage = "Aucune famille configurée. Relancez l'application."
            isLoading = false
            return
        }

        do {
            // We don't know the accountId yet — use a temporary key for initial login
            let tempClient = EcoleDirecteClient(accountId: "setup")
            let loginResponse = try await tempClient.login(username: username, password: password)

            guard let account = loginResponse.accounts.first else {
                throw EcoleDirecteError.noAccountFound
            }

            guard !account.eleves.isEmpty else {
                errorMessage = "Aucun élève trouvé sur ce compte."
                isLoading = false
                return
            }

            // Persist children
            let accountIdStr = String(account.id)
            for eleve in account.eleves {
                let existing = family.children.first {
                    $0.schoolType == .ecoledirecte && $0.entChildId == String(eleve.id)
                }
                if existing != nil { continue }   // already added — skip

                let child = Child(
                    firstName: eleve.firstName,
                    level: inferLevel(from: eleve.grade),
                    grade: eleve.grade,
                    schoolType: .ecoledirecte,
                    establishment: eleve.establishmentName
                )
                child.entChildId = String(eleve.id)
                child.edAccountId = accountIdStr
                child.family = family
                modelContext.insert(child)
            }
            try modelContext.save()

            // Immediate sync using a fresh client keyed by the real accountId
            let client = EcoleDirecteClient(accountId: accountIdStr)
            _ = try await client.login(username: username, password: password)

            let syncService = EcoleDirecteSyncService(modelContext: modelContext)
            for child in family.children where child.schoolType == .ecoledirecte {
                try? await syncService.sync(child: child, client: client)
            }

            onDismissAll?() ?? dismiss()
        } catch EcoleDirecteError.badCredentials {
            errorMessage = "Identifiants incorrects. Vérifiez votre identifiant et mot de passe."
        } catch EcoleDirecteError.accountBlocked {
            errorMessage = "Compte bloqué. Connectez-vous sur ecoledirecte.com pour le débloquer."
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func inferLevel(from grade: String) -> SchoolLevel {
        let lower = grade.lowercased()
        if lower.contains("ps") || lower.contains("ms") || lower.contains("gs") { return .maternelle }
        if lower.contains("cp") || lower.contains("ce") || lower.contains("cm") { return .elementaire }
        if lower.contains("6") || lower.contains("5") || lower.contains("4") || lower.contains("3") { return .college }
        if lower.contains("2nd") || lower.contains("1") || lower.contains("tle") || lower.contains("ter") { return .lycee }
        return .college
    }
}
