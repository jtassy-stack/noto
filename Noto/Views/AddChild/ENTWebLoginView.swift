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
                    Text("Récupération des données…")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
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

        // MonLycée's psn.monlycee.net is behind an OAuth2 proxy that serves the SPA for all paths.
        // Try multiple approaches to find user/children data:
        // 1. Try /userbook/api/person (standard ENTCore)
        // 2. Try extracting user info from the SPA's JS context (window.__session, etc.)
        // 3. Scrape the greeting text ("Bonjour Julien!")
        webView.callAsyncJavaScript(
            """
            // Try ENTCore API endpoints
            async function tryFetch(url) {
                try {
                    let r = await fetch(url, { credentials: 'include', headers: { 'Accept': 'application/json' } });
                    let text = await r.text();
                    if (r.ok && !text.startsWith('<!DOCTYPE')) return { url: url, status: r.status, body: text.substring(0, 3000) };
                } catch(e) {}
                return null;
            }

            let base = location.origin;
            let endpoints = [
                base + '/userbook/api/person',
                base + '/directory/user/find',
                base + '/auth/oauth2/userinfo',
                base + '/conversation/count/INBOX'
            ];

            let results = {};
            for (let ep of endpoints) {
                let r = await tryFetch(ep);
                if (r) results[ep] = r;
            }

            // Also try to extract user data from the page's JS context
            let sessionData = null;
            try { sessionData = JSON.stringify(window.__session || window.__USER__ || window.user || null); } catch(e) {}

            // Extract greeting text
            let greeting = '';
            let greetEl = document.querySelector('.greeting, [class*=greeting], [class*=user-name], h1, h2');
            if (greetEl) greeting = greetEl.textContent.trim();
            // Try broader search
            if (!greeting) {
                let all = document.querySelectorAll('*');
                for (let el of all) {
                    if (el.textContent.includes('Bonjour') && el.children.length < 3) {
                        greeting = el.textContent.trim();
                        break;
                    }
                }
            }

            return { endpoints: results, session: sessionData, greeting: greeting, url: location.href };
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

                #if DEBUG
                NSLog("[noto] MonLycée probe: \(raw)")
                #endif

                // Check if any endpoint returned JSON
                if let endpoints = raw["endpoints"] as? [String: Any] {
                    for (_, epResult) in endpoints {
                        guard let ep = epResult as? [String: Any],
                              let body = ep["body"] as? String,
                              let data = body.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) else { continue }

                        // Found JSON! Transfer cookies and return
                        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                            ENTClient.importCookies(cookies)
                            DispatchQueue.main.async {
                                if let dict = json as? [String: Any] {
                                    self.onSuccess(dict)
                                } else if let array = json as? [[String: Any]] {
                                    self.onSuccess(["result": array])
                                }
                            }
                        }
                        return
                    }
                }

                // No API worked — try to create child from greeting text
                let greeting = raw["greeting"] as? String ?? ""
                let currentURL = raw["url"] as? String ?? ""
                let sessionData = raw["session"] as? String

                if !greeting.isEmpty {
                    // "Bonjour Julien !" → extract name
                    let name = greeting
                        .replacingOccurrences(of: "Bonjour ", with: "")
                        .replacingOccurrences(of: " !", with: "")
                        .replacingOccurrences(of: "!", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        ENTClient.importCookies(cookies)
                        // Return with the parent name — we'll create child manually
                        DispatchQueue.main.async {
                            self.onSuccess(["_parentName": name, "_greeting": greeting, "_url": currentURL, "_session": sessionData ?? ""])
                        }
                    }
                } else {
                    let endpointInfo = (raw["endpoints"] as? [String: Any])?.keys.joined(separator: ", ") ?? "none"
                    DispatchQueue.main.async {
                        self.onError("Aucune API n'a répondu en JSON. URL: \(currentURL)\nEndpoints testés: \(endpointInfo)\nSession: \(sessionData ?? "null")")
                    }
                }

            case .failure(let error):
                DispatchQueue.main.async { self.onError("Erreur JS : \(error.localizedDescription)") }
            }
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
                DispatchQueue.main.async { self.onLoginDetected() }
            }
        }
    }
}
