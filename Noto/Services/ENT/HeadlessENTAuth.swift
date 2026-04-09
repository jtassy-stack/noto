import Foundation
import WebKit

/// Authenticates against an Edifice/ENTCore ENT using a hidden WKWebView.
/// The login page is a JS SPA — URLSession cannot establish a session.
/// This class auto-fills and submits the form invisibly, then returns the session cookies.
@MainActor
final class HeadlessENTAuth: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[HTTPCookie], Error>?
    private let loginURL: URL
    private let email: String
    private let password: String
    private var state: AuthState = .loading

    private enum AuthState {
        case loading       // Initial page load
        case submitted     // Form submitted, waiting for redirect
        case done          // Finished (success or failure)
    }

    private init(loginURL: URL, email: String, password: String) {
        self.loginURL = loginURL
        self.email = email
        self.password = password
    }

    /// Authenticate and return session cookies. Throws `ENTError.badCredentials` or other errors.
    static func login(loginURL: URL, email: String, password: String) async throws -> [HTTPCookie] {
        let auth = HeadlessENTAuth(loginURL: loginURL, email: email, password: password)
        return try await auth.run()
    }

    private func run() async throws -> [HTTPCookie] {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.setupWebView()
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Off-screen frame — needs non-zero size for JS to execute
        let wv = WKWebView(frame: CGRect(x: -2000, y: -2000, width: 375, height: 812), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        // Must be in a window for WKWebView JS execution to work reliably
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let window = scene.windows.first {
            window.addSubview(wv)
        }

        wv.load(URLRequest(url: loginURL))

        // Safety timeout — 15 seconds max
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.state != .done else { return }
            self.fail(ENTError.invalidResponse("Délai de connexion dépassé"))
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url?.absoluteString ?? ""
            NSLog("[noto] HeadlessENTAuth didFinish: %@", url)

            switch self.state {
            case .loading:
                if url.contains("/auth/login") {
                    // Login page rendered — wait for React to mount the form, then fill it
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.fillAndSubmitForm(webView)
                } else {
                    // Immediately landed somewhere else — already authenticated?
                    self.extractCookiesAndSucceed(webView)
                }
            case .submitted:
                if url.contains("/auth/login") {
                    // Back on login page after submit → wrong credentials
                    self.fail(ENTError.badCredentials)
                } else {
                    // Left the login page → success
                    self.extractCookiesAndSucceed(webView)
                }
            case .done:
                break
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.fail(ENTError.invalidResponse("Navigation error: \(error.localizedDescription)"))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // -999 (NSURLErrorCancelled) is fired on redirects — not a real failure
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.fail(ENTError.invalidResponse("Load error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Form interaction

    private func fillAndSubmitForm(_ webView: WKWebView) {
        // Pass credentials via JSON to avoid any string-interpolation injection issues.
        // The try/catch wrapper ensures a JS exception never surfaces as a WKError.
        guard let payload = try? JSONSerialization.data(withJSONObject: ["e": email, "p": password]),
              let payloadStr = String(data: payload, encoding: .utf8) else {
            fail(ENTError.invalidResponse("Échec encodage credentials"))
            return
        }

        let js = """
        (function() {
            try {
                var creds = \(payloadStr);
                var emailEl = document.querySelector(
                    'input[type="email"], input[name="email"], input[id="email"], input[name="login"], input[name="username"]'
                );
                var pwdEl = document.querySelector('input[type="password"]');
                if (!emailEl || !pwdEl) return 'no_fields';
                function fill(el, val) {
                    try {
                        var desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                        if (desc && desc.set) { desc.set.call(el, val); }
                        else { el.value = val; }
                    } catch(e) { el.value = val; }
                    el.dispatchEvent(new Event('input',  { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    el.dispatchEvent(new Event('blur',   { bubbles: true }));
                }
                fill(emailEl, creds.e);
                fill(pwdEl,   creds.p);
                var form = emailEl.closest('form') || document.querySelector('form');
                if (form) { form.requestSubmit ? form.requestSubmit() : form.submit(); return 'form_submit'; }
                var btn = document.querySelector(
                    'button[type="submit"], input[type="submit"], button.login-btn, button.submit, button'
                );
                if (btn) { btn.click(); return 'btn_click'; }
                return 'no_submit';
            } catch(e) {
                return 'exception:' + e.message;
            }
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    NSLog("[noto][error] HeadlessENTAuth JS eval failed: %@", error.localizedDescription)
                    self.fail(ENTError.invalidResponse("Échec injection formulaire: \(error.localizedDescription)"))
                    return
                }
                let outcome = result as? String ?? ""
                NSLog("[noto] HeadlessENTAuth JS outcome: %@", outcome)
                switch outcome {
                case "no_fields":
                    // Wait a bit more and retry once — SPA may not have mounted yet
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .loading else { return }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard self.state == .loading else { return }
                        NSLog("[noto] HeadlessENTAuth retrying form injection…")
                        self.fillAndSubmitForm(webView)
                    }
                case "no_submit":
                    self.fail(ENTError.invalidResponse("Bouton de connexion introuvable"))
                default:
                    if outcome.hasPrefix("exception:") {
                        self.fail(ENTError.invalidResponse("Erreur JS: \(outcome)"))
                    } else {
                        self.state = .submitted
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractCookiesAndSucceed(_ webView: WKWebView) {
        state = .done
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                self?.cleanupWebView()
                self?.continuation?.resume(returning: cookies)
                self?.continuation = nil
            }
        }
    }

    private func fail(_ error: Error) {
        guard state != .done else { return }
        state = .done
        cleanupWebView()
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func cleanupWebView() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

}
