import SwiftUI
import WebKit

/// Web-based login for ENT providers that use Keycloak/OIDC (e.g. MonLycée).
/// Wraps a UIViewController containing WKWebView for stable delegate lifecycle.
struct ENTWebLoginView: UIViewControllerRepresentable {
    let loginURL: URL
    let onSuccess: ([String: Any]) -> Void  // passes the fetched JSON
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ENTWebLoginController {
        let vc = ENTWebLoginController()
        vc.loginURL = loginURL
        vc.onSuccess = onSuccess
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: ENTWebLoginController, context: Context) {}
}

class ENTWebLoginController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    var loginURL: URL!
    var onSuccess: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    private var webView: WKWebView!
    private var hasCompleted = false
    private var urlObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Add message handler to receive fetch results from JS
        config.userContentController.add(self, name: "notoCallback")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        // KVO on URL for login detection
        urlObservation = webView.observe(\.url, options: .new) { [weak self] webView, _ in
            guard let self, !self.hasCompleted else { return }
            let url = webView.url?.absoluteString ?? ""
            NSLog("[noto] WebView URL: \(url)")
            self.checkIfLoggedIn(url: url)
        }

        NSLog("[noto] ENTWebLogin loading: \(loginURL.absoluteString)")
        webView.load(URLRequest(url: loginURL))
    }

    deinit {
        urlObservation?.invalidate()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "notoCallback" else { return }

        if let body = message.body as? [String: Any] {
            NSLog("[noto] JS callback received with keys: \(body.keys.sorted())")
            // Copy cookies then call success
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                NSLog("[noto] Copied \(cookies.count) cookies")
                DispatchQueue.main.async {
                    self.onSuccess?(body)
                }
            }
        } else if let errorStr = message.body as? String {
            NSLog("[noto] JS callback error: \(errorStr)")
            DispatchQueue.main.async {
                self.onError?(errorStr)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        NSLog("[noto] didFinish: \(url)")
        checkIfLoggedIn(url: url)
    }

    // MARK: - Login detection

    private func checkIfLoggedIn(url: String) {
        guard !hasCompleted else { return }

        let isOnENT = url.contains("monlycee.net") || url.contains("parisclassenumerique.fr")
        let isOnAuth = url.contains("/auth/") || url.contains("openid-connect") || url.contains("/realms/") || url.contains("cas/login") || url.contains("/oauth2/callback")

        if isOnENT && !isOnAuth {
            hasCompleted = true
            NSLog("[noto] Login success at: \(url)")

            // Determine the API base from the current URL
            let apiBase: String
            if url.contains("psn.monlycee.net") {
                apiBase = "https://psn.monlycee.net"
            } else if url.contains("ent.parisclassenumerique.fr") {
                apiBase = "https://ent.parisclassenumerique.fr"
            } else {
                apiBase = url.components(separatedBy: "/").prefix(3).joined(separator: "/")
            }

            // Fetch children data via JS fetch — use XMLHttpRequest for synchronous-ish callback
            let js = """
            (function() {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', '\(apiBase)/userbook/api/person', true);
                xhr.setRequestHeader('Accept', 'application/json');
                xhr.withCredentials = true;
                xhr.onload = function() {
                    try {
                        var data = JSON.parse(xhr.responseText);
                        window.webkit.messageHandlers.notoCallback.postMessage(data);
                    } catch(e) {
                        window.webkit.messageHandlers.notoCallback.postMessage('PARSE_ERROR: ' + xhr.responseText.substring(0, 200));
                    }
                };
                xhr.onerror = function() {
                    window.webkit.messageHandlers.notoCallback.postMessage('XHR_ERROR: ' + xhr.status);
                };
                xhr.send();
            })();
            """

            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("[noto] JS eval error: \(error)")
                }
            }
        }
    }
}
