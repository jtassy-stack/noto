import SwiftUI
import SwiftData

struct ENTLoginView: View {
    let provider: ENTProvider

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var login = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showWebLogin = false

    private var family: Family? { families.first }
    private var needsWebAuth: Bool { provider == .monlycee }

    var body: some View {
        Group {
            if needsWebAuth {
                // MonLycée: embedded web view for Keycloak OIDC
                VStack(spacing: NotoTheme.Spacing.md) {
                    if isLoading {
                        VStack(spacing: NotoTheme.Spacing.md) {
                            ProgressView()
                            Text("Récupération des données…")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = errorMessage {
                        VStack(spacing: NotoTheme.Spacing.md) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(NotoTheme.Colors.danger)
                            Button("Réessayer") { showWebLogin = true }
                                .buttonStyle(.borderedProminent)
                                .tint(NotoTheme.Colors.brand)
                        }
                        .padding(NotoTheme.Spacing.xl)
                    } else {
                        // Show the web login view inline
                        ENTWebLoginView(
                            loginURL: URL(string: "\(provider.baseURL.absoluteString)/auth/login")!,
                            providerDomain: provider.baseURL.host ?? "monlycee.net",
                            onSuccess: { json in Task { await handleWebLoginSuccess(json: json) } },
                            onError: { msg in errorMessage = msg }
                        )
                    }
                }
            } else {
                // PCN: username + password form
                Form {
                    Section {
                        TextField("Identifiant", text: $login)
                            .textContentType(.username)
                            .autocapitalization(.none)
                        SecureField("Mot de passe", text: $password)
                            .textContentType(.password)
                    } header: {
                        Text("Connexion \(provider.name)")
                    } footer: {
                        Text("Utilisez vos identifiants \(provider.name).")
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
                            Task { await performFormLogin() }
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
                        .disabled(login.isEmpty || password.isEmpty || isLoading)
                    }
                }
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Web Login Success (MonLycée)

    @MainActor
    private func handleWebLoginSuccess(json: [String: Any]) async {
        isLoading = true
        errorMessage = nil

        #if DEBUG
        NSLog("[noto] Web login data keys: \(json.keys.sorted())")
        #endif

        // Extract children from /logbook response
        var entChildren: [ENTChildInfo] = []
        if let logbook = json["logbook"] as? [String: Any],
           let structures = logbook["structures"] as? [[String: Any]] {
            for structure in structures {
                if let individuals = structure["individuals"] as? [[String: Any]] {
                    for individual in individuals {
                        guard let firstName = individual["firstName"] as? String,
                              let lastName = individual["lastName"] as? String,
                              let id = individual["id"] as? String else { continue }
                        let displayName = "\(lastName) \(firstName)"
                        // Skip the parent entry (first one with no work data)
                        let hasWork = individual["work"] != nil && !(individual["work"] is NSNull)
                        if hasWork {
                            entChildren.append(ENTChildInfo(id: id, displayName: displayName, className: ""))
                        }
                    }
                }
            }
        }

        // Fallback: profile greeting
        if entChildren.isEmpty {
            let greeting = json["greeting"] as? String ?? ""
            let parentName = greeting
                .replacingOccurrences(of: "Bonjour ", with: "")
                .replacingOccurrences(of: " !", with: "")
                .replacingOccurrences(of: "!", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !parentName.isEmpty {
                entChildren.append(ENTChildInfo(id: "monlycee-\(parentName)", displayName: parentName, className: ""))
            }
        }

        // Check if Pronote SSO succeeded
        let pronoteSSO = json["_pronoteSSO"] as? String
        let pronoteURL = json["_pronoteURL"] as? String
        let pronoteHTML = json["_pronoteHTML"] as? String
        let hasPronote = pronoteSSO == "success" && pronoteHTML != nil

        #if DEBUG
        NSLog("[noto] MonLycée: \(entChildren.count) children, pronoteSSO=\(pronoteSSO ?? "nil"), pronoteURL=\(pronoteURL ?? "nil")")
        if let html = pronoteHTML {
            NSLog("[noto] Pronote HTML prefix: \(String(html.prefix(300)))")
        }
        #endif

        // Store logbook + news for ENT data sync
        if let logbook = json["logbook"] {
            if let data = try? JSONSerialization.data(withJSONObject: logbook),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: "monlycee_logbook")
            }
        }
        if let news = json["news"] {
            if let data = try? JSONSerialization.data(withJSONObject: news),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: "monlycee_news")
            }
        }

        NSLog("[noto] \(provider.name) found \(entChildren.count) children, pronote=\(hasPronote)")

        guard let family, !entChildren.isEmpty else {
            errorMessage = "Connexion réussie mais aucun enfant trouvé."
            isLoading = false
            return
        }

        // Create children — as Pronote type if SSO succeeded, ENT type otherwise
        for ec in entChildren {
            let nameParts = ec.displayName.components(separatedBy: " ")
            let firstName = nameParts.count > 1
                ? nameParts.drop(while: { $0 == $0.uppercased() }).first ?? nameParts.last ?? ec.displayName
                : ec.displayName

            let child = Child(
                firstName: firstName,
                level: .lycee,
                grade: inferGrade(from: ""),
                schoolType: hasPronote ? .pronote : .ent,
                establishment: pronoteURL ?? provider.name
            )
            child.entChildId = ec.id
            child.entProvider = provider
            child.family = family
            modelContext.insert(child)
        }

        do { try modelContext.save() }
        catch { NSLog("[noto] Failed to save children: \(error)") }

        // If Pronote SSO succeeded, store the HTML for PawnoteBridge to parse later
        if hasPronote, let html = pronoteHTML, let url = pronoteURL {
            UserDefaults.standard.set(html, forKey: "monlycee_pronote_html")
            UserDefaults.standard.set(url, forKey: "monlycee_pronote_url")
        }

        // Immediately sync data from the logbook we captured
        let syncService = MonLyceeSyncService(modelContext: modelContext)
        for child in family.children where child.entProvider == provider {
            syncService.syncFromStoredLogbook(for: child)
        }

        dismiss()

        isLoading = false
    }

    // MARK: - Form Login (PCN)

    @MainActor
    private func performFormLogin() async {
        isLoading = true
        errorMessage = nil

        let client = ENTClient(provider: provider)

        do {
            try await client.login(email: login, password: password)

            let creds = "\(login):\(password)"
            do {
                try KeychainService.save(key: "ent_credentials_\(provider.rawValue)", data: Data(creds.utf8))
            } catch {
                errorMessage = "Impossible de sauvegarder les identifiants. La synchronisation automatique ne fonctionnera pas."
                NSLog("[noto] Keychain save failed: \(error)")
            }

            let entChildren = try await client.fetchChildren()
            NSLog("[noto] \(provider.name) found \(entChildren.count) children: \(entChildren.map(\.displayName))")
            createChildren(entChildren)
            dismiss()
        } catch let error as ENTError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Erreur : \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Create Children

    private func createChildren(_ entChildren: [ENTChildInfo]) {
        guard let family else { return }

        if entChildren.isEmpty {
            let child = Child(
                firstName: login.isEmpty ? "Enfant" : login.components(separatedBy: ".").first?.capitalized ?? "Enfant",
                level: provider == .monlycee ? .lycee : .elementaire,
                grade: "?",
                schoolType: .ent,
                establishment: provider.name
            )
            child.entProvider = provider
            child.family = family
            modelContext.insert(child)
        } else {
            for ec in entChildren {
                let nameParts = ec.displayName.components(separatedBy: " ")
                let firstName = nameParts.count > 1
                    ? nameParts.drop(while: { $0 == $0.uppercased() }).first ?? nameParts.last ?? ec.displayName
                    : ec.displayName
                let child = Child(
                    firstName: firstName,
                    level: inferLevel(from: ec.className),
                    grade: inferGrade(from: ec.className),
                    schoolType: .ent,
                    establishment: provider.name
                )
                child.entChildId = ec.id
                child.entProvider = provider
                child.family = family
                modelContext.insert(child)
            }
        }

        do {
            try modelContext.save()
        } catch {
            NSLog("[noto] Failed to save children: \(error)")
        }
    }

    /// Parse children from the raw JSON returned by /userbook/api/person
    private func parseChildrenFromJSON(_ data: Data) -> [ENTChildInfo] {
        let results: [[String: Any]]
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let r = json["result"] as? [[String: Any]] {
            results = r
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            results = arr
        } else {
            NSLog("[noto] parseChildrenFromJSON: unexpected format")
            return []
        }

        var seen = Set<String>()
        var children: [ENTChildInfo] = []

        for entry in results {
            let relatedName = entry["relatedName"] as? String ?? ""
            let relatedId = entry["relatedId"] as? String ?? ""
            guard !relatedName.isEmpty, !seen.contains(relatedName) else { continue }
            seen.insert(relatedName)
            children.append(ENTChildInfo(id: relatedId, displayName: relatedName, className: ""))
        }

        // If no relatedName entries, try displayName (might be the user themselves)
        if children.isEmpty {
            for entry in results {
                if let name = entry["displayName"] as? String, let id = entry["id"] as? String {
                    children.append(ENTChildInfo(id: id, displayName: name, className: ""))
                }
            }
        }

        return children
    }

    private func inferLevel(from className: String) -> SchoolLevel {
        if provider == .monlycee { return .lycee }
        let lower = className.lowercased()
        if lower.contains("ps") || lower.contains("ms") || lower.contains("gs") { return .maternelle }
        if lower.contains("cp") || lower.contains("ce") || lower.contains("cm") { return .elementaire }
        return .elementaire
    }

    private func inferGrade(from className: String) -> String {
        if provider == .monlycee {
            for p in ["2nde", "1ère", "Tle", "2de", "1re", "Term"] where className.lowercased().contains(p.lowercased()) { return p }
            return className.prefix(6).trimmingCharacters(in: .whitespaces)
        }
        for p in ["PS", "MS", "GS", "CP", "CE1", "CE2", "CM1", "CM2"] where className.uppercased().contains(p) { return p }
        return className.prefix(4).trimmingCharacters(in: .whitespaces)
    }
}
