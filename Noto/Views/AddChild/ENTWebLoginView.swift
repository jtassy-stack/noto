import SwiftUI
import WebKit

/// Web-based login for ENT providers that use Keycloak/OIDC (e.g. MonLycée).
/// Wraps a UIViewController containing WKWebView for stable delegate lifecycle.
struct ENTWebLoginView: UIViewControllerRepresentable {
    let loginURL: URL
    let providerDomain: String  // e.g. "monlycee.net"
    let onSuccess: ([String: Any]) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ENTWebLoginController {
        ENTWebLoginController(
            loginURL: loginURL,
            providerDomain: providerDomain,
            onSuccess: onSuccess,
            onError: onError
        )
    }

    func updateUIViewController(_ uiViewController: ENTWebLoginController, context: Context) {}
}

class ENTWebLoginController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let loginURL: URL
    private let providerDomain: String
    private let onSuccess: ([String: Any]) -> Void
    private let onError: (String) -> Void
    private var webView: WKWebView!
    private var hasCompleted = false
    private var urlObservation: NSKeyValueObservation?

    init(loginURL: URL, providerDomain: String, onSuccess: @escaping ([String: Any]) -> Void, onError: @escaping (String) -> Void) {
        self.loginURL = loginURL
        self.providerDomain = providerDomain
        self.onSuccess = onSuccess
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "notoCallback")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        urlObservation = webView.observe(\.url, options: .new) { [weak self] webView, _ in
            guard let self, !self.hasCompleted else { return }
            let url = webView.url?.absoluteString ?? ""
            #if DEBUG
            NSLog("[noto] WebView URL: \(url)")
            #endif
            self.checkIfLoggedIn(url: url)
        }

        webView.load(URLRequest(url: loginURL))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Break retain cycle: WKUserContentController → self
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notoCallback")
    }

    deinit {
        urlObservation?.invalidate()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "notoCallback", !hasCompleted else { return }

        if let body = message.body as? [String: Any] {
            hasCompleted = true
            transferCookiesAndComplete(json: body)
        } else if let errorStr = message.body as? String {
            hasCompleted = true
            DispatchQueue.main.async { self.onError(errorStr) }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkIfLoggedIn(url: webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        onError(error.localizedDescription)
    }

    // MARK: - Login detection

    private func checkIfLoggedIn(url: String) {
        guard !hasCompleted else { return }

        let isOnENT = url.contains(providerDomain)
        let isOnAuth = url.contains("/auth/") || url.contains("openid-connect") ||
                       url.contains("/realms/") || url.contains("cas/login") ||
                       url.contains("/oauth2/callback")

        guard isOnENT && !isOnAuth else { return }

        hasCompleted = true

        // Build API URL safely — no string interpolation into JS
        let apiBase = "https://\(providerDomain.hasPrefix("psn.") ? providerDomain : "psn.\(providerDomain)")"

        webView.callAsyncJavaScript(
            """
            let response = await fetch(apiURL, { credentials: 'include', headers: { 'Accept': 'application/json' } });
            let text = await response.text();
            try { return JSON.parse(text); }
            catch(e) { return { error: text.substring(0, 200) }; }
            """,
            arguments: ["apiURL": "\(apiBase)/userbook/api/person"],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                if let dict = value as? [String: Any] {
                    self.transferCookiesAndComplete(json: dict)
                } else {
                    DispatchQueue.main.async { self.onError("Réponse inattendue du serveur") }
                }
            case .failure(let error):
                #if DEBUG
                NSLog("[noto] callAsyncJavaScript failed: \(error)")
                #endif
                DispatchQueue.main.async { self.onError("Erreur de récupération des données : \(error.localizedDescription)") }
            }
        }
    }

    private func transferCookiesAndComplete(json: [String: Any]) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            ENTClient.importCookies(cookies)
            DispatchQueue.main.async { self.onSuccess(json) }
        }
    }
}
