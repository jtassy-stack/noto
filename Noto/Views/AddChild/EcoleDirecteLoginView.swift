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
            // Step 1 — discovery login to determine the real accountId.
            // Uses a temporary accountId key; the "setup" Keychain entry is cleaned up below.
            let discoveryClient = EcoleDirecteClient(accountId: "setup")
            let loginResponse = try await discoveryClient.login(username: username, password: password)

            guard let account = loginResponse.accounts.first else {
                throw EcoleDirecteError.noAccountFound
            }
            guard !account.eleves.isEmpty else {
                errorMessage = "Aucun élève trouvé sur ce compte."
                isLoading = false
                return
            }

            let accountIdStr = String(account.id)

            // Step 2 — create the real client, transfer the already-acquired token
            // (avoids a second HTTP round-trip), then save credentials under the real key.
            let client = EcoleDirecteClient(accountId: accountIdStr)
            await client.setToken(loginResponse.token)
            await client.storeCredentials(username: username, password: password)

            // Clean up the temporary "setup" Keychain entry created during discovery
            try? KeychainService.delete(key: "ed_credentials_setup")

            // Step 3 — persist children
            for eleve in account.eleves {
                let alreadyExists = family.children.contains {
                    $0.schoolType == .ecoledirecte && $0.entChildId == String(eleve.id)
                }
                guard !alreadyExists else { continue }

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

            // Step 4 — immediate sync (non-fatal: child is saved even if sync fails)
            let syncService = EcoleDirecteSyncService(modelContext: modelContext)
            for child in family.children where child.schoolType == .ecoledirecte {
                do {
                    try await syncService.sync(child: child, client: client)
                } catch {
                    NSLog("[noto][warn] ED initial sync for %@: %@", child.firstName, error.localizedDescription)
                    // Non-fatal — HomeView will retry and surface errors via the sync banner
                }
            }

            if let onDismissAll { onDismissAll() } else { dismiss() }
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
