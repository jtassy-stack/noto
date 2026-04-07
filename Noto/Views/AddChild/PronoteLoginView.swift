import SwiftUI
import SwiftData

struct PronoteLoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var children: [PronoteChildResource] = []
    @State private var showChildPicker = false

    private var family: Family? { families.first }

    var body: some View {
        Form {
            Section {
                TextField("URL Pronote", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                TextField("Identifiant", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Connexion Pronote")
            } footer: {
                Text("L'URL se trouve dans la barre d'adresse quand vous êtes sur Pronote (ex: demo.index-education.net/pronote)")
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
                .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isLoading)
            }
        }
        .navigationTitle("Pronote")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChildPicker) {
            ChildPickerView(
                children: children,
                schoolType: .pronote,
                serverURL: normalizedURL,
                onSelect: { selectedChildren in
                    addChildren(selectedChildren)
                    dismiss()
                }
            )
        }
    }

    private var normalizedURL: String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http") { url = "https://\(url)" }
        return url
    }

    private func login() async {
        isLoading = true
        errorMessage = nil

        let deviceUUID = getOrCreateDeviceUUID()
        let client = PronoteClient(url: normalizedURL, deviceUUID: deviceUUID)

        do {
            let refreshToken = try await client.login(username: username, password: password)

            // Store refresh token in Keychain
            if let tokenData = try? JSONEncoder().encode(refreshToken) {
                try? KeychainService.save(key: "pronote_token_\(username)", data: tokenData)
            }

            // Get children from session
            children = await client.children

            if children.count == 1 {
                // Single child — add directly
                addChildren(children)
                dismiss()
            } else if children.count > 1 {
                // Multiple children — show picker
                showChildPicker = true
            } else {
                errorMessage = "Aucun enfant trouvé sur ce compte."
            }
        } catch let error as PronoteError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Erreur de connexion : \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func addChildren(_ pronoteChildren: [PronoteChildResource]) {
        guard let family else { return }

        for pc in pronoteChildren {
            let child = Child(
                firstName: pc.name.components(separatedBy: " ").first ?? pc.name,
                level: inferLevel(from: pc.className),
                grade: inferGrade(from: pc.className),
                schoolType: .pronote,
                establishment: pc.establishment
            )
            child.family = family
            modelContext.insert(child)
        }
        try? modelContext.save()
    }

    private func getOrCreateDeviceUUID() -> String {
        if let data = try? KeychainService.load(key: "device_uuid"),
           let uuid = String(data: data, encoding: .utf8) {
            return uuid
        }
        let uuid = UUID().uuidString
        try? KeychainService.save(key: "device_uuid", data: Data(uuid.utf8))
        return uuid
    }

    private func inferLevel(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        if lower.contains("cp") || lower.contains("ce") || lower.contains("cm") {
            return .elementaire
        }
        if lower.contains("6") || lower.contains("5") || lower.contains("4") || lower.contains("3") {
            return .college
        }
        if lower.contains("2nde") || lower.contains("1") || lower.contains("tle") || lower.contains("terminale") {
            return .lycee
        }
        return .college
    }

    private func inferGrade(from className: String) -> String {
        // Extract grade from class name like "6e2", "3eA", "CM1-B"
        let patterns = ["CP", "CE1", "CE2", "CM1", "CM2", "6e", "5e", "4e", "3e", "2nde", "1re", "Tle"]
        let lower = className.lowercased()
        for p in patterns {
            if lower.contains(p.lowercased()) { return p }
        }
        return className.prefix(3).trimmingCharacters(in: .whitespaces)
    }
}
