import SwiftUI
import SwiftData
import WebKit
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "PronoteWeb")

/// Pronote login through the establishment's ENT, without a QR code.
///
/// The parent gives (or the ENT discovery gave) the establishment's Pronote
/// URL; the web view opens Pronote's mobile page in « accès depuis une
/// application » mode (`PronoteMobileLogin`), Pronote redirects to the ENT's
/// CAS where the parent signs in on the real ENT page, and on the way back
/// Pronote's page hands out a single-use mobile token. The session then
/// opens like after a QR scan (`loginToken`), the token is stored in the
/// Keychain and the children are imported through the shared importer.
/// nōto never sees the ENT password: it is typed on the ENT's own page.
struct PronoteWebLoginView: View {
    /// Pronote instance the ENT linked, when known; otherwise the parent types it.
    var initialURL: String = ""
    var kind: PronoteAccountKind = .parent
    var onDismissAll: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var urlText: String
    @State private var instance: URL?
    @State private var step: Step = .enterURL
    @State private var errorMessage: String?
    @State private var isFinishing = false

    private var family: Family? { families.first }

    init(initialURL: String = "", kind: PronoteAccountKind = .parent, onDismissAll: (() -> Void)? = nil) {
        self.initialURL = initialURL
        self.kind = kind
        self.onDismissAll = onDismissAll
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        Group {
            switch step {
            case .enterURL:
                urlForm
            case .web:
                if let instance,
                   let entry = PronoteMobileLogin.casEntryURL(instance: instance, kind: kind) {
                    ZStack(alignment: .bottom) {
                        PronoteTokenWebView(
                            pageURL: PronoteMobileLogin.infoMobileAppURL(instance: instance) ?? entry,
                            entryURL: entry,
                            instance: instance,
                            deviceUUID: PronoteAccountStore.deviceUUID(),
                            onToken: { payload in Task { await finish(with: payload) } },
                            onError: { message in errorMessage = message }
                        )
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.danger)
                                .padding(NotoTheme.Spacing.md)
                                .frame(maxWidth: .infinity)
                                .background(.regularMaterial)
                        }
                    }
                }
            case .loading:
                VStack(spacing: NotoTheme.Spacing.md) {
                    ProgressView()
                    Text("Ouverture de la session Pronote…")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let name, let note):
                successView(childName: name, partialSyncNote: note)
            }
        }
        .navigationTitle("Pronote via l'ENT")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Skip the form when the ENT already told us where Pronote lives.
            if case .enterURL = step, let url = PronoteMobileLogin.instanceURL(from: initialURL) {
                instance = url
                step = .web
            }
        }
    }

    // MARK: - URL form

    private var urlForm: some View {
        Form {
            Section {
                TextField("https://0750000X.index-education.net/pronote", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Adresse Pronote de l'établissement")
            } footer: {
                Text("Celle qui s'ouvre quand vous cliquez sur Pronote dans l'ENT (MonLycée, Paris Classe Numérique…). Vous vous identifierez ensuite sur la page de l'ENT, comme d'habitude ; nōto ne voit pas votre mot de passe.")
                    .font(NotoTheme.Typography.caption)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(NotoTheme.Colors.danger)
                }
            }

            Section {
                Button {
                    guard let url = PronoteMobileLogin.instanceURL(from: urlText) else {
                        errorMessage = "Adresse invalide. Copiez l'adresse complète de Pronote depuis l'ENT."
                        return
                    }
                    errorMessage = nil
                    instance = url
                    step = .web
                } label: {
                    HStack {
                        Spacer()
                        Text("Continuer")
                            .font(NotoTheme.Typography.headline)
                        Spacer()
                    }
                }
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Finish

    @MainActor
    private func finish(with payload: PronoteMobileLogin.TokenPayload) async {
        guard !isFinishing, let instance else { return }
        isFinishing = true
        step = .loading
        errorMessage = nil

        let deviceUUID = PronoteAccountStore.deviceUUID()
        let initial = payload.refreshToken(instance: instance, kind: kind)

        do {
            let bridge = try PawnoteBridge()
            let refreshToken = try await bridge.loginWithToken(initial, deviceUUID: deviceUUID)

            do {
                try PronoteAccountStore.save(refreshToken)
            } catch {
                logger.error("Keychain save failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Connexion réussie mais impossible de sauvegarder vos identifiants. Réessayez."
                step = .web
                isFinishing = false
                return
            }

            guard let family else {
                errorMessage = "Aucun profil famille trouvé. Relancez l'application."
                step = .web
                isFinishing = false
                return
            }

            let resolved = try PronoteChildImporter.importChildren(
                from: bridge, token: refreshToken, family: family, modelContext: modelContext
            )
            let hadPartialFailure = await PronoteChildImporter.initialSync(
                children: resolved, bridge: bridge, modelContext: modelContext
            )
            PronoteService.shared.setBridge(bridge, for: refreshToken.username)

            let addedName = resolved.last?.firstName ?? refreshToken.username
            let note: String? = hadPartialFailure
                ? "Certaines données seront disponibles après la prochaine synchronisation."
                : nil
            step = .success(childName: addedName, partialSyncNote: note)
        } catch {
            if case PronoteError.doubleAuthRequired(let info) = error {
                if let rescued = info?.rescuedToken { try? PronoteAccountStore.save(rescued) }
                errorMessage = error.localizedDescription
            } else if case PronoteError.networkError = error {
                errorMessage = "Impossible de joindre le serveur Pronote. Vérifiez votre connexion."
            } else {
                logger.error("Pronote web login failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Pronote a refusé l'ouverture de la session. Réessayez, ou utilisez le QR code."
            }
            step = .web
        }
        isFinishing = false
    }

    private func successView(childName: String, partialSyncNote: String?) -> some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(NotoTheme.Colors.success)
            Text("\(childName) est connecté·e")
                .font(NotoTheme.Typography.title)
            if let partialSyncNote {
                Text(partialSyncNote)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NotoTheme.Spacing.xl)
            }
            Spacer()
            Button {
                if let onDismissAll { onDismissAll() } else {
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                    dismiss()
                }
            } label: {
                Text("Terminer")
                    .font(NotoTheme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NotoTheme.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(NotoTheme.Colors.pronote)
            .padding(.horizontal, NotoTheme.Spacing.xl)
            .padding(.bottom, NotoTheme.Spacing.xl)
        }
    }

    private enum Step {
        case enterURL
        case web
        case loading
        case success(childName: String, partialSyncNote: String?)
    }
}

// MARK: - Web view

/// WKWebView that opens the instance's `infoMobileApp.json`, sets the
/// « application » cookies there (`PronoteMobileLogin.appModeCookieScript`),
/// then loads Pronote's plain mobile page and lets the CAS redirects happen
/// (the parent signs in on the ENT page). Back on the mobile page, Pronote
/// renders the token document; meanwhile nōto also asks the page for it.
/// Never `bydlg`: it turns Pronote's CAS delegation off.
private struct PronoteTokenWebView: UIViewRepresentable {
    let pageURL: URL
    let entryURL: URL
    let instance: URL
    let deviceUUID: String
    let onToken: (PronoteMobileLogin.TokenPayload) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Shared store: an ENT session opened earlier in the app (MonLycée
        // web login) lets Pronote's CAS redirect pass without a second sign-in.
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(
            source: PronoteMobileLogin.hookScript(deviceUUID: deviceUUID),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: pageURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(instance: instance, entryURL: entryURL, deviceUUID: deviceUUID, onToken: onToken, onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let instance: URL
        let entryURL: URL
        let deviceUUID: String
        let onToken: (PronoteMobileLogin.TokenPayload) -> Void
        let onError: (String) -> Void
        private var delivered = false
        private var cookiesSet = false
        /// Bumped on each mobile-page load so a stale poll loop stops.
        private var generation = 0

        init(
            instance: URL,
            entryURL: URL,
            deviceUUID: String,
            onToken: @escaping (PronoteMobileLogin.TokenPayload) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.instance = instance
            self.entryURL = entryURL
            self.deviceUUID = deviceUUID
            self.onToken = onToken
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.debug("didFinish \(PronoteMobileLogin.logLabel(webView.url), privacy: .public)")
            guard !delivered, let url = webView.url else { return }
            if !cookiesSet, PronoteMobileLogin.isInfoMobileApp(url, of: instance) {
                cookiesSet = true
                let script = PronoteMobileLogin.appModeCookieScript(deviceUUID: deviceUUID, next: entryURL)
                webView.evaluateJavaScript(script) { value, _ in
                    logger.debug("app cookies → \(value as? String ?? "nil", privacy: .public)")
                }
                return
            }
            guard PronoteMobileLogin.isMobilePage(url, of: instance) else { return }
            generation += 1
            poll(webView, attempt: 0, generation: generation)
        }

        /// Reads the body for the token for 90 s; meanwhile asks the page
        /// for it every 3 s (at most 6 times).
        private func poll(_ webView: WKWebView, attempt: Int, generation: Int) {
            guard !delivered, generation == self.generation, attempt < 180 else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self, weak webView] result, _ in
                guard let self, !self.delivered, let webView else { return }
                if let text = result as? String, let payload = PronoteMobileLogin.parseTokenPayload(bodyText: text) {
                    self.delivered = true
                    self.onToken(payload)
                    return
                }
                if attempt >= 4, attempt % 6 == 4, attempt < 40 {
                    webView.evaluateJavaScript(PronoteMobileLogin.triggerScript(deviceUUID: self.deviceUUID)) { value, _ in
                        logger.debug("trigger → \(value as? String ?? "nil", privacy: .public)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.poll(webView, attempt: attempt + 1, generation: generation)
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            // -999 = cancelled by a redirect, the normal CAS dance.
            guard nsError.code != NSURLErrorCancelled else { return }
            if !cookiesSet, let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
               PronoteMobileLogin.isInfoMobileApp(failing, of: instance) {
                // No infoMobileApp.json: go on without the cookies.
                cookiesSet = true
                webView.load(URLRequest(url: entryURL))
                return
            }
            onError("Impossible d'ouvrir cette page : \(error.localizedDescription)")
        }
    }
}
