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

            if isLoggedIn && !isFetching {
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

            if isFetching {
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

    /// Step 2: open the establishment's Pronote mobile page in the same
    /// web view. The ENT session the parent just opened lets Pronote's CAS
    /// redirect pass silently, and the `bydlg` + `login=true` page answers
    /// with the account login and a single-use mobile token (see
    /// `PronoteMobileLogin`). nōto then opens the session with `loginToken`,
    /// exactly like after a QR scan — no cookie transfer, no patched pawnote.
    private func capturePronoteToken(instance: URL, entData: [String: Any]) {
        guard let webView = webViewHolder.webView,
              let pageURL = PronoteMobileLogin.loginPageURL(instance: instance, kind: .parent) else {
            onError("WebView non disponible")
            return
        }

        webView.load(URLRequest(url: pageURL))

        var attempts = 0
        func poll() {
            attempts += 1
            guard attempts <= 40 else { // 20 s: the CAS round trip can be slow
                DispatchQueue.main.async {
                    self.statusMessage = "Pronote n'a pas répondu — données ENT uniquement"
                    var result = entData
                    result["_pronoteSSO"] = "timeout"
                    self.onSuccess(result)
                }
                return
            }

            guard let current = webView.url, PronoteMobileLogin.isMobilePage(current, of: instance) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                return
            }

            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                if let text = value as? String,
                   let payload = PronoteMobileLogin.parseTokenPayload(bodyText: text) {
                    var result = entData
                    result["_pronoteSSO"] = "success"
                    result["_pronoteToken"] = [
                        "login": payload.login,
                        "mdp": payload.token,
                        "url": instance.absoluteString,
                    ]
                    DispatchQueue.main.async {
                        self.statusMessage = "Pronote connecté !"
                        self.onSuccess(result)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                }
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !detected else { return }
            let url = webView.url?.absoluteString ?? ""
            #if DEBUG
            NSLog("[noto] WebView didFinish: \(url)")
            #endif

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
