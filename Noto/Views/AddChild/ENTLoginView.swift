import SwiftUI
import SwiftData
import WebKit

struct ENTLoginView: View {
    let provider: ENTProvider
    var onDismissAll: (() -> Void)? = nil

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
                            provider: provider,
                            loginURL: URL(string: "\(provider.baseURL.absoluteString)/auth/login")!,
                            providerDomain: provider.baseURL.host ?? "ent.parisclassenumerique.fr",
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

    // MARK: - Web Login Success

    @MainActor
    private func handleWebLoginSuccess(json: [String: Any]) async {
        isLoading = true
        errorMessage = nil

        #if DEBUG
        NSLog("[noto] Web login data keys: \(json.keys.sorted())")
        #endif

        // PCN uses a simpler flow — no Pronote SSO, no Zimbra
        if provider == .pcn {
            await handlePCNWebLoginSuccess(json: json)
            return
        }

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
                            let className = MonLyceeClassReader.className(in: individual) ?? ""
                            entChildren.append(ENTChildInfo(id: id, displayName: displayName, className: className))
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

        // Pronote token captured on Pronote's own mobile page (ENTWebLoginView)
        var pronoteToken: PronoteRefreshToken?
        if let raw = json["_pronoteToken"] as? [String: Any],
           let login = raw["login"] as? String, !login.isEmpty,
           let mdp = raw["mdp"] as? String, !mdp.isEmpty,
           let url = raw["url"] as? String, !url.isEmpty {
            pronoteToken = PronoteRefreshToken(url: url, token: mdp, username: login, kind: .parent)
        }

        #if DEBUG
        NSLog("[noto] MonLycée: \(entChildren.count) children, pronote=\(json["_pronoteSSO"] as? String ?? "nil")")
        #endif

        // Store logbook + news for ENT data sync. Mail is no longer captured
        // here (the login JS always returned `zimbraMail: null`); it goes
        // through `MonLyceeMailService` instead. Purge the legacy keys so no
        // stale payload lingers in UserDefaults (the Pronote HTML/URL pair
        // belonged to the removed cookie-based login).
        for legacy in ["monlycee_zimbra_mail", "monlycee_pronote_html", "monlycee_pronote_url"] {
            UserDefaults.standard.removeObject(forKey: legacy)
        }
        for (key, udKey) in [("logbook", "monlycee_logbook"), ("news", "monlycee_news")] {
            if let obj = json[key], !(obj is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: udKey)
            }
        }

        NSLog("[noto] \(provider.name) found \(entChildren.count) children, pronote=\(pronoteToken != nil)")

        guard let family else {
            errorMessage = "Aucune famille configurée."
            isLoading = false
            return
        }

        // Cookies to HTTPCookieStorage: the monlycee.net mail client needs them.
        await transferMonlyceeCookies()

        // Pronote first: the session's own roster creates (or refreshes) the
        // Pronote children, deduped exactly like after a QR scan.
        var pronoteOpened = false
        if let pronoteToken {
            pronoteOpened = await establishPronoteSession(token: pronoteToken, family: family)
        }

        guard !entChildren.isEmpty || pronoteOpened else {
            errorMessage = "Connexion réussie mais aucun enfant trouvé."
            isLoading = false
            return
        }

        // ENT children: attach the logbook identity to the matching child
        // (the Pronote row when the token login listed the same first name,
        // or an existing ENT row), create an ENT child otherwise. Never a
        // second row for the same child.
        for ec in entChildren {
            let nameParts = ec.displayName.components(separatedBy: " ")
            let firstName = nameParts.count > 1
                ? nameParts.drop(while: { $0 == $0.uppercased() }).first ?? nameParts.last ?? ec.displayName
                : ec.displayName

            if let existing = ChildDedupe.matchENT(
                in: family.children,
                entChildId: ec.id,
                firstName: firstName,
                provider: provider
            ) {
                existing.entChildId = ec.id
                existing.entProvider = provider
                if !ec.className.isEmpty { existing.entClassName = ec.className }
                continue
            }

            let resolved = GradeInference.resolve(ec.className)
            let child = Child(
                firstName: firstName,
                level: resolved?.level ?? .lycee,
                grade: resolved?.grade ?? inferGrade(from: ""),
                schoolType: .ent,
                establishment: provider.name
            )
            child.entClassName = ec.className.isEmpty ? nil : ec.className
            child.entChildId = ec.id
            child.entProvider = provider
            child.family = family
            modelContext.insert(child)
        }

        do { try modelContext.save() }
        catch { NSLog("[noto] Failed to save children: \(error)") }

        // Immediately sync data from the logbook we captured
        let syncService = MonLyceeSyncService(modelContext: modelContext)
        for child in family.children where child.entProvider == provider {
            syncService.syncFromStoredLogbook(for: child)
        }

        // Mail via the SSO session cookies — skipped when the parent
        // already connected the monlycee.net inbox over IMAP, so the two
        // mechanisms never double-fetch the same inbox. Fired in the
        // background *after* the sheet closes: up to ~50 sequential webmail
        // calls per child must not keep the login spinner up. The Task
        // inherits the MainActor (MonLyceeMailService and `Child` require
        // it) and the environment's main ModelContext outlives the sheet.
        let mailChildren = family.children.filter { $0.entProvider == provider }
        let mailContext = modelContext

        isLoading = false
        onDismissAll?() ?? dismiss()

        if provider == .monlycee {
            let imapConfigs = IMAPService.loadConfigs()
            Task {
                for child in mailChildren
                where MonLyceeMailService.shouldSync(child: child, configs: imapConfigs) {
                    await MonLyceeMailService.sync(child: child, modelContext: mailContext)
                }
            }
        }
    }

    /// Transfers monlycee.net cookies (session + CSRF) from the SSO
    /// WKWebView into `HTTPCookieStorage.shared`, where `URLSession.shared`
    /// (and pawnote's own fetch) picks them up automatically.
    @MainActor
    private func transferMonlyceeCookies() async {
        let cookies = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        for cookie in cookies where MonLyceeWebmailClient.isMonLyceeDomain(cookie.domain) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    // MARK: - PCN Web Login Success

    @MainActor
    private func handlePCNWebLoginSuccess(json: [String: Any]) async {
        // Cookies were already transferred to ENTClient by ENTWebLoginView's success handler

        // Parse children from /userbook/api/person response
        var entChildren: [ENTChildInfo] = []
        if let person = json["person"] as? [String: Any],
           let results = person["result"] as? [[String: Any]] {
            var seen = Set<String>()
            for entry in results {
                let name = entry["relatedName"] as? String ?? ""
                let id = entry["relatedId"] as? String ?? ""
                guard !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                entChildren.append(ENTChildInfo(id: id, displayName: name, className: ""))
            }
        }

        NSLog("[noto] PCN found \(entChildren.count) children")

        guard !entChildren.isEmpty else {
            errorMessage = "Connexion réussie mais aucun enfant trouvé."
            isLoading = false
            return
        }

        createChildren(entChildren)

        // Immediately sync data using the session cookies already transferred from WebView.
        // Goes through SyncCoordinator like every other sync (isSyncing, de-dup,
        // attempt timestamp). createChildren already saved.
        let client = ENTClient(provider: .pcn)
        let syncService = ENTSyncService(modelContext: modelContext)
        let pcnChildren = (family?.children ?? []).filter { $0.entProvider == .pcn }
        await SyncCoordinator.shared.requestSync(force: true) {
            for child in pcnChildren {
                guard let entChildId = child.entChildId else { continue }
                do {
                    try await syncService.sync(child: child, client: client, entChildId: entChildId)
                } catch {
                    NSLog("[noto][warn] PCN initial sync for %@: %@", child.firstName, error.localizedDescription)
                }
            }
        }

        onDismissAll?() ?? dismiss()
        isLoading = false
    }

    // MARK: - Pronote Session from the ENT token

    /// Opens the Pronote session with the single-use token the web view
    /// captured, stores the renewed token (PronoteAutoConnect replays it on
    /// the next launches) and imports the roster through the shared
    /// importer. A failure is not fatal: the ENT data still works and the
    /// parent can retry or scan a QR code.
    @MainActor
    @discardableResult
    private func establishPronoteSession(token: PronoteRefreshToken, family: Family) async -> Bool {
        let deviceUUID = PronoteAccountStore.deviceUUID()
        do {
            let bridge = try PawnoteBridge()
            let renewed = try await bridge.loginWithToken(token, deviceUUID: deviceUUID)
            do {
                try PronoteAccountStore.save(renewed)
            } catch {
                NSLog("[noto] ENT→Pronote token not saved: %@", error.localizedDescription)
            }
            PronoteService.shared.setBridge(bridge, for: renewed.username)

            let children = try PronoteChildImporter.importChildren(
                from: bridge, token: renewed, family: family, modelContext: modelContext
            )
            _ = await PronoteChildImporter.initialSync(children: children, bridge: bridge, modelContext: modelContext)
            NSLog("[noto] ENT→Pronote session established (%d children)", children.count)
            return true
        } catch {
            if case PronoteError.doubleAuthRequired(let info) = error, let rescued = info?.rescuedToken {
                try? PronoteAccountStore.save(rescued)
            }
            NSLog("[noto] ENT→Pronote session failed: %@", error.localizedDescription)
            return false
        }
    }


    // MARK: - Form Login (PCN — headless WKWebView)
    // Edifice/PCN login page is a JS SPA — URLSession cannot authenticate.
    // We use a hidden WKWebView that auto-fills and submits the native form,
    // then transfer cookies to ENTClient for all subsequent API calls.

    @MainActor
    private func performFormLogin() async {
        isLoading = true
        errorMessage = nil

        do {
            let loginURL = URL(string: "\(provider.baseURL.absoluteString)/auth/login")!
            let cookies = try await HeadlessENTAuth.login(loginURL: loginURL, email: login, password: password)
            ENTClient.importCookies(cookies)

            // Save credentials for background sync (re-auth when session expires)
            let creds = "\(login):\(password)"
            try? KeychainService.save(key: "ent_credentials_\(provider.rawValue)", data: Data(creds.utf8))

            let client = ENTClient(provider: provider)
            let entChildren = try await client.fetchChildren()
            NSLog("[noto] %@ found %d children", provider.name, entChildren.count)
            createChildren(entChildren)

            // Immediate sync (through the coordinator)
            let syncService = ENTSyncService(modelContext: modelContext)
            let providerChildren = (family?.children ?? []).filter { $0.entProvider == provider }
            await SyncCoordinator.shared.requestSync(force: true) {
                for child in providerChildren {
                    guard let id = child.entChildId else { continue }
                    do {
                        try await syncService.sync(child: child, client: client, entChildId: id)
                    } catch {
                        NSLog("[noto][warn] %@ initial sync for %@: %@", provider.name, child.firstName, error.localizedDescription)
                    }
                }
            }

            onDismissAll?() ?? dismiss()
        } catch ENTError.badCredentials {
            errorMessage = "Identifiants incorrects."
        } catch {
            errorMessage = error.localizedDescription
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
                // Canonical grade first ("1ère" → "1re", "Term" → "Tle", "CM2 A"
                // → "CM2"); legacy parsing only when nothing is recognised.
                let resolved = GradeInference.resolve(ec.className)
                let child = Child(
                    firstName: firstName,
                    level: resolved?.level ?? inferLevel(from: ec.className),
                    grade: resolved?.grade ?? inferGrade(from: ec.className),
                    schoolType: .ent,
                    establishment: provider.name
                )
                child.entChildId = ec.id
                child.entProvider = provider
                child.entClassName = ec.className.isEmpty ? nil : ec.className
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
