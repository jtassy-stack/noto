import SwiftUI
import WebKit

/// Web-based login for ENT providers that use Keycloak/OIDC (e.g. MonLycée).
/// Shows a WKWebView with a floating "Continuer" button once the user is logged in.
struct ENTWebLoginView: View {
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

        // Multi-step flow:
        // 1. Fetch /user/profile, /user/services, /logbook, /news/messages
        // 2. If Pronote found in services → navigate to Pronote SSO
        // 3. Extract Pronote session from the loaded page
        // Step 1: Fetch profile, services, logbook from the ENT
        webView.callAsyncJavaScript(
            """
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

            // Find Pronote service
            let pronoteService = null;
            if (Array.isArray(services)) {
                pronoteService = services.find(s => s.title === 'pronote' || (s.link || '').includes('pronote'));
            }

            // Zimbra mail: get CSRF token from cookie, then fetch headers
            let zimbraMail = null;
            let csrfToken = (document.cookie.match(/CSRF_TOKEN=([^;]+)/) || [])[1] || '';
            if (csrfToken) {
                try {
                    let mailBase = 'https://apis-mail.monlycee.net/webmail';
                    // First create a token if needed
                    await fetch(mailBase + '/xml/createToken.json', {
                        method: 'POST', credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-CSRF-TOKEN': csrfToken }
                    });
                    // Fetch mail headers
                    let mailR = await fetch(mailBase + '/xml/getMailHeaderList.json', {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-CSRF-TOKEN': csrfToken }
                    });
                    if (mailR.ok) {
                        let ct = mailR.headers.get('content-type') || '';
                        if (ct.includes('json')) zimbraMail = await mailR.json();
                    }
                } catch(e) {}
            }

            // Extract greeting
            let greeting = '';
            for (let el of document.querySelectorAll('*')) {
                let t = el.textContent || '';
                if (t.includes('Bonjour') && el.children.length < 5 && t.length < 50) {
                    greeting = t.trim(); break;
                }
            }

            return { profile, services, logbook, news, pronoteService, greeting, zimbraMail, csrfToken };
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { [self] result in
            switch result {
            case .success(let value):
                guard let raw = value as? [String: Any] else {
                    DispatchQueue.main.async { self.onError("Réponse inattendue") }
                    return
                }

                // Transfer cookies
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    ENTClient.importCookies(cookies)

                    // Check if Pronote was found
                    if let pronoteService = raw["pronoteService"] as? [String: Any],
                       let pronoteLink = pronoteService["link"] as? String {
                        // Step 2: Navigate to Pronote via SSO
                        DispatchQueue.main.async {
                            self.statusMessage = "Connexion Pronote via SSO…"
                            self.navigateToPronoteSSO(pronoteURL: pronoteLink, entData: raw)
                        }
                    } else {
                        // No Pronote — return ENT data only
                        DispatchQueue.main.async {
                            self.onSuccess(raw)
                        }
                    }
                }

            case .failure(let error):
                DispatchQueue.main.async { self.onError("Erreur : \(error.localizedDescription)") }
            }
        }
    }

    /// Step 2: Navigate the WKWebView to Pronote — CAS SSO will auto-authenticate
    private func navigateToPronoteSSO(pronoteURL: String, entData: [String: Any]) {
        guard let webView = webViewHolder.webView else {
            onError("WebView non disponible")
            return
        }

        // Pronote's mobile parent page — this is where we can extract session data
        let mobileURL = pronoteURL.hasSuffix("/")
            ? "\(pronoteURL)mobile.parent.html"
            : "\(pronoteURL)/mobile.parent.html"

        #if DEBUG
        NSLog("[noto] Navigating to Pronote SSO: \(mobileURL)")
        #endif

        // Load Pronote — the MonLycée CAS session will auto-authenticate
        webView.load(URLRequest(url: URL(string: mobileURL)!))

        // Wait for Pronote page to load, then extract session
        // We use a polling approach since we can't easily add another didFinish handler
        var attempts = 0
        func checkPronoteLoaded() {
            attempts += 1
            guard attempts < 20 else { // 10 seconds max
                // Timeout — return ENT data only, Pronote SSO failed
                DispatchQueue.main.async {
                    self.statusMessage = "Pronote SSO timeout — données ENT uniquement"
                    var result = entData
                    result["_pronoteSSO"] = "timeout"
                    self.onSuccess(result)
                }
                return
            }

            webView.evaluateJavaScript("document.documentElement.outerHTML.substring(0, 500)") { [self] htmlResult, _ in
                let html = htmlResult as? String ?? ""
                let currentURL = webView.url?.absoluteString ?? ""

                #if DEBUG
                if attempts % 5 == 0 {
                    NSLog("[noto] Pronote SSO check #\(attempts): url=\(currentURL) html=\(String(html.prefix(100)))")
                }
                #endif

                // Check if we landed on a Pronote page with Start() data
                if html.contains("Start (") || html.contains("Start(") || currentURL.contains("parent.html") {
                    // Extract the full HTML to parse Start() data
                    webView.evaluateJavaScript("document.documentElement.outerHTML") { fullHTML, _ in
                        guard let fullHTML = fullHTML as? String else {
                            var result = entData
                            result["_pronoteSSO"] = "no_html"
                            DispatchQueue.main.async { self.onSuccess(result) }
                            return
                        }

                        var result = entData
                        result["_pronoteSSO"] = "success"
                        result["_pronoteHTML"] = String(fullHTML.prefix(10000))
                        result["_pronoteURL"] = pronoteURL

                        DispatchQueue.main.async {
                            self.statusMessage = "Pronote connecté !"
                            self.onSuccess(result)
                        }
                    }
                } else if html.contains("<!DOCTYPE") && !currentURL.contains("auth.monlycee") {
                    // Still loading or redirecting — wait more
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        checkPronoteLoaded()
                    }
                } else {
                    // Still on auth redirect — wait more
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        checkPronoteLoaded()
                    }
                }
            }
        }

        // Start checking after 1 second delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checkPronoteLoaded()
        }
    }
}

// MARK: - WKWebView wrapper

private class WebViewHolder: ObservableObject {
    var webView: WKWebView?
}

private struct ENTWebViewWrapper: UIViewRepresentable {
    let loginURL: URL
    let providerDomain: String
    let onWebViewReady: (WKWebView) -> Void
    let onLoginDetected: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        onWebViewReady(wv)
        wv.load(URLRequest(url: loginURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(providerDomain: providerDomain, onLoginDetected: onLoginDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let providerDomain: String
        let onLoginDetected: () -> Void
        private var detected = false

        init(providerDomain: String, onLoginDetected: @escaping () -> Void) {
            self.providerDomain = providerDomain
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !detected else { return }
            let url = webView.url?.absoluteString ?? ""
            #if DEBUG
            NSLog("[noto] WebView didFinish: \(url)")
            #endif

            // Detect: on the ENT domain, not on Keycloak, not the initial login redirect
            let isOnKeycloak = url.contains("auth.monlycee.net") || url.contains("/realms/")
            let isOnENT = url.contains(providerDomain)
            if isOnENT && !isOnKeycloak {
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
