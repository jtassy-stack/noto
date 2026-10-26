import SwiftUI
import WebKit

/// Web-based login for ENT providers (PCN/Edifice CAS and MonLycée/Keycloak).
/// Shows a WKWebView with a floating "Continuer" button once the user is logged in.
struct ENTWebLoginView: View {
    let provider: ENTProvider
    let loginURL: URL
    let providerDomain: String
    let onSuccess: ([String: Any]) -> Void
    let onError: (String) -> Void

    @State private var isLoggedIn = false
    @State private var isFetching = false
    @State private var statusMessage = ""
    /// The Pronote step is waiting on a page the parent may have to act on
    /// (a profile choice, a consent screen): the web view is shown again,
    /// with a hint instead of the spinner.
    @State private var showsPronotePage = false
    @StateObject private var webViewHolder = WebViewHolder()

    var body: some View {
        ZStack(alignment: .bottom) {
            ENTWebViewWrapper(
                provider: provider,
                loginURL: loginURL,
                providerDomain: providerDomain,
                onWebViewReady: { webViewHolder.webView = $0 },
                onLoginDetected: { isLoggedIn = true }
            )

            if showsPronotePage {
                Text("Pronote s'ouvre… Si une page vous demande de choisir un profil ou de confirmer, faites-le ici.")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            } else if isLoggedIn && !isFetching {
                Button {
                    fetchChildren()
                } label: {
                    Text("Continuer")
                        .font(NotoTheme.Typography.headline)
                        .foregroundStyle(NotoTheme.Colors.shadow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.md)
                        .background(NotoTheme.Colors.brand)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                }
                .padding(NotoTheme.Spacing.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isFetching && !showsPronotePage {
                VStack(spacing: NotoTheme.Spacing.md) {
                    ProgressView()
                    Text(statusMessage.isEmpty ? "Récupération des données…" : statusMessage)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotoTheme.Colors.shadow.opacity(0.8))
            }
        }
        .animation(.easeInOut, value: isLoggedIn)
    }

    private func fetchChildren() {
        guard let webView = webViewHolder.webView else {
            onError("WebView non disponible")
            return
        }
        isFetching = true
        statusMessage = "Récupération du profil…"

        let js: String
        if provider == .pcn {
            // PCN/Edifice: fetch children from /userbook/api/person
            js = """
            async function tryJSON(url) {
                try {
                    let r = await fetch(url, { credentials: 'include', headers: { 'Accept': 'application/json' } });
                    let ct = r.headers.get('content-type') || '';
                    if (!ct.includes('json')) return null;
                    return await r.json();
                } catch(e) { return null; }
            }
            let base = location.origin;
            let person = await tryJSON(base + '/userbook/api/person');
            return { person };
            """
        } else {
            // MonLycée: fetch profile, logbook, news, Pronote service
            js = """
            async function tryJSON(url) {
                try {
                    let r = await fetch(url, { credentials: 'include', headers: { 'Accept': 'application/json' } });
                    let ct = r.headers.get('content-type') || '';
                    if (!ct.includes('json')) return null;
                    return await r.json();
                } catch(e) { return null; }
            }

            let base = location.origin;
            let profile = await tryJSON(base + '/user/profile');
            let services = await tryJSON(base + '/user/services?matchingFilterProfile=web');
            let logbook = await tryJSON(base + '/logbook');
            let news = await tryJSON(base + '/news/messages');

            let pronoteService = null;
            if (Array.isArray(services)) {
                pronoteService = services.find(s => s.title === 'pronote' || (s.link || '').includes('pronote'));
            }

            let csrfToken = (document.cookie.match(/CSRF_TOKEN=([^;]+)/) || [])[1] || '';
            const zimbraMail = null;

            let greeting = '';
            for (let el of document.querySelectorAll('*')) {
                let t = el.textContent || '';
                if (t.includes('Bonjour') && el.children.length < 5 && t.length < 50) {
                    greeting = t.trim(); break;
                }
            }

            return { profile, services, logbook, news, pronoteService, greeting, zimbraMail, csrfToken };
            """
        }

        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [self] result in
            switch result {
            case .success(let value):
                guard let raw = value as? [String: Any] else {
                    DispatchQueue.main.async { self.onError("Réponse inattendue") }
                    return
                }

                // Transfer cookies then proceed to Pronote SSO (or complete)
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    ENTClient.importCookies(cookies)
                    DispatchQueue.main.async {
                        if let pronoteService = raw["pronoteService"] as? [String: Any],
                           let pronoteLink = pronoteService["link"] as? String,
                           let instance = PronoteMobileLogin.instanceURL(from: pronoteLink) {
                            #if DEBUG
                            NSLog("[noto] Pronote via ENT: link=\(PronoteMobileLogin.logLabel(URL(string: pronoteLink))) instance=\(PronoteMobileLogin.logLabel(instance))")
                            #endif
                            self.statusMessage = "Ouverture de Pronote…"
                            self.capturePronoteToken(instance: instance, entData: raw)
                        } else {
                            self.onSuccess(raw)
                        }
                    }
                }

            case .failure(let error):
                DispatchQueue.main.async { self.onError("Erreur : \(error.localizedDescription)") }
            }
        }
    }

    /// Step 2: open Pronote in the same web view, the way Papillon does.
    /// First the instance's public `infoMobileApp.json`, where nōto sets the
    /// cookies that tell Pronote the visit comes from an application
    /// (`PronoteMobileLogin.appModeCookieScript`), then the plain mobile
    /// page. Pronote sends it through the ENT's CAS, which the session just
    /// opened lets through silently, and on the way back calls
    /// `hookAccesDepuisAppli`: the page body becomes the token document
    /// (account login + single-use mobile token), and the session opens
    /// with `loginToken`, exactly like after a QR scan.
    ///
    /// Never `bydlg`: measured on a real MonLycée instance (2026-10-25/26),
    /// that switch turns the CAS delegation off and Pronote shows its own
    /// login form, even with a CAS session open.
    private func capturePronoteToken(instance: URL, entData: [String: Any]) {
        let deviceUUID = PronoteAccountStore.deviceUUID()
        guard let webView = webViewHolder.webView,
              let entryURL = PronoteMobileLogin.casEntryURL(instance: instance, kind: .parent) else {
            onError("WebView non disponible")
            return
        }
        let infoURL = PronoteMobileLogin.infoMobileAppURL(instance: instance)

        webView.load(URLRequest(url: infoURL ?? entryURL))

        let interval = 0.5
        let maxAttempts = 300 // 150 s: CAS round trips and Pronote can be slow
        let revealAfter = 16  // 8 s without a token: let the parent see the page
        var attempts = 0
        var pollsOnMobile = 0
        var triggers = 0
        var cookiesSet = infoURL == nil
        #if DEBUG
        var lastLogged = ""
        #endif

        func finishWithoutToken() {
            #if DEBUG
            NSLog("[noto] Pronote via ENT: timeout, last page=\(PronoteMobileLogin.logLabel(webView.url)) triggers=\(triggers) cookies=\(cookiesSet)")
            #endif
            showsPronotePage = false
            statusMessage = "Pronote n'a pas répondu — données ENT uniquement"
            var result = entData
            result["_pronoteSSO"] = "timeout"
            onSuccess(result)
        }

        func deliver(_ payload: PronoteMobileLogin.TokenPayload) {
            #if DEBUG
            NSLog("[noto] Pronote via ENT: token received after \(attempts) polls (triggers=\(triggers))")
            #endif
            var result = entData
            result["_pronoteSSO"] = "success"
            result["_pronoteToken"] = [
                "login": payload.login,
                "mdp": payload.token,
                "url": instance.absoluteString,
            ]
            showsPronotePage = false
            statusMessage = "Pronote connecté !"
            onSuccess(result)
        }

        func again() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { poll() }
        }

        /// On the loaded mobile page without a token yet: ask the page for
        /// it every 3 s until the wait ends. Only once the page has finished
        /// loading: the CAS round trip goes through the same URL first.
        func nudge() {
            guard !webView.isLoading, pollsOnMobile >= 2, pollsOnMobile % 6 == 2 else { return }
            triggers += 1
            let n = triggers
            webView.evaluateJavaScript(PronoteMobileLogin.triggerScript(deviceUUID: deviceUUID)) { value, _ in
                #if DEBUG
                NSLog("[noto] Pronote via ENT: trigger \(n) → \(value as? String ?? "nil")")
                #endif
            }
        }

        func poll() {
            attempts += 1
            guard attempts <= maxAttempts else { finishWithoutToken(); return }

            #if DEBUG
            let label = PronoteMobileLogin.logLabel(webView.url)
            if label != lastLogged || attempts % 20 == 0 {
                NSLog("[noto] Pronote via ENT: poll \(attempts) on \(label)")
                lastLogged = label
            }
            #endif

            if !cookiesSet, let current = webView.url, PronoteMobileLogin.isInfoMobileApp(current, of: instance), !webView.isLoading {
                cookiesSet = true
                webView.evaluateJavaScript(PronoteMobileLogin.appModeCookieScript(deviceUUID: deviceUUID, next: entryURL)) { value, _ in
                    #if DEBUG
                    NSLog("[noto] Pronote via ENT: app cookies → \(value as? String ?? "nil")")
                    #endif
                }
                again()
                return
            }
            if !cookiesSet, attempts >= 20 {
                // infoMobileApp.json never showed up: go on without the cookies.
                cookiesSet = true
                #if DEBUG
                NSLog("[noto] Pronote via ENT: no infoMobileApp page, plain entry")
                #endif
                webView.load(URLRequest(url: entryURL))
            }

            guard let current = webView.url, PronoteMobileLogin.isMobilePage(current, of: instance) else {
                pollsOnMobile = 0
                if attempts >= revealAfter { showsPronotePage = true }
                again()
                return
            }

            if !webView.isLoading { pollsOnMobile += 1 }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                let text = value as? String ?? ""
                if let payload = PronoteMobileLogin.parseTokenPayload(bodyText: text) {
                    deliver(payload)
                    return
                }
                #if DEBUG
                if attempts % 20 == 0 {
                    // Length only: the body may hold the parent's name.
                    NSLog("[noto] Pronote via ENT: mobile page without token (\(text.count) chars)")
                }
                #endif
                if attempts >= revealAfter { showsPronotePage = true }
                nudge()
                again()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
    }
}

// MARK: - WKWebView wrapper

private class WebViewHolder: ObservableObject {
    var webView: WKWebView?
}

private struct ENTWebViewWrapper: UIViewRepresentable {
    let provider: ENTProvider
    let loginURL: URL
    let providerDomain: String
    let onWebViewReady: (WKWebView) -> Void
    let onLoginDetected: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Pronote's mobile page calls this hook on a `bydlg` login; on the
        // ENT's own pages the function is simply never called.
        config.userContentController.addUserScript(WKUserScript(
            source: PronoteMobileLogin.hookScript(deviceUUID: PronoteAccountStore.deviceUUID()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        onWebViewReady(wv)
        wv.load(URLRequest(url: loginURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, providerDomain: providerDomain, onLoginDetected: onLoginDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let provider: ENTProvider
        let providerDomain: String
        let onLoginDetected: () -> Void
        private var detected = false

        init(provider: ENTProvider, providerDomain: String, onLoginDetected: @escaping () -> Void) {
            self.provider = provider
            self.providerDomain = providerDomain
            self.onLoginDetected = onLoginDetected
        }

        // Navigation trace (host + path only, never the query: CAS tickets).
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            #if DEBUG
            NSLog("[noto] WebView start: \(PronoteMobileLogin.logLabel(webView.url))")
            #endif
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            #if DEBUG
            NSLog("[noto] WebView redirect: \(PronoteMobileLogin.logLabel(webView.url))")
            #endif
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            #if DEBUG
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                NSLog("[noto] WebView HTTP \(http.statusCode): \(PronoteMobileLogin.logLabel(http.url))")
            }
            #endif
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            NSLog("[noto] WebView fail: \(PronoteMobileLogin.logLabel(webView.url)) code=\((error as NSError).code)")
            #endif
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            let nsError = error as NSError
            let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            NSLog("[noto] WebView fail (provisional): \(PronoteMobileLogin.logLabel(failing ?? webView.url)) code=\(nsError.code)")
            #endif
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            NSLog("[noto] WebView didFinish: \(PronoteMobileLogin.logLabel(webView.url))")
            #endif
            guard !detected else { return }
            let url = webView.url?.absoluteString ?? ""

            let isOnENT = url.contains(providerDomain)
            // PCN: logged in when on ENT domain but NOT on the login page
            // MonLycée: logged in when on ENT domain but NOT on Keycloak
            let isOnKeycloak = url.contains("auth.monlycee.net") || url.contains("/realms/")
            let isOnLoginPage = url.contains("/auth/login")
            let loggedIn = provider == .pcn
                ? (isOnENT && !isOnLoginPage)
                : (isOnENT && !isOnKeycloak)
            if loggedIn {
                detected = true

                // Inject XHR/fetch interceptor to discover what API calls the SPA makes
                webView.evaluateJavaScript("""
                (function() {
                    if (window.__notoIntercepted) return;
                    window.__notoIntercepted = true;
                    window.__notoXHRLog = [];
                    var origOpen = XMLHttpRequest.prototype.open;
                    XMLHttpRequest.prototype.open = function(method, url) {
                        window.__notoXHRLog.push(method + ' ' + url);
                        return origOpen.apply(this, arguments);
                    };
                    var origFetch = window.fetch;
                    window.fetch = function(url, opts) {
                        var u = typeof url === 'string' ? url : (url.url || '');
                        window.__notoXHRLog.push(((opts||{}).method||'GET') + ' ' + u);
                        return origFetch.apply(this, arguments);
                    };
                })();
                """) { _, _ in }

                DispatchQueue.main.async { self.onLoginDetected() }
            }
        }
    }
}
