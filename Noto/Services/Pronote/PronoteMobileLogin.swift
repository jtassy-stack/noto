import Foundation

/// The « accès depuis une application » handshake of Pronote's own mobile
/// page, the route the official app and Papillon use when the parent logs
/// in through an ENT: nōto opens the establishment's Pronote URL in a web
/// view, Pronote redirects to the ENT's CAS, the parent signs in on the real
/// ENT page, and Pronote comes back to its mobile page. Opened with the
/// `bydlg` application identifier, that page calls
/// `hookAccesDepuisAppli` instead of rendering; the hook below answers with
/// `passerEnModeValidationAppliMobile`, and the page body becomes a JSON
/// document holding the account login and a single-use mobile token
/// (`mdp`). From there the session opens exactly like after a QR scan
/// (`loginToken`) — no hand-patched pawnote, no password seen by nōto.
///
/// Pure, so the URL building and the payload parsing are unit-tested;
/// the web view itself is `PronoteWebLoginView`.
enum PronoteMobileLogin {

    /// Application identifier Pronote expects on the `bydlg` parameter
    /// (the one used by the reference open-source clients).
    static let applicationIdentifier = "A6ABB224-12DD-4E31-AD3E-8A39A1C2C335"

    /// The Pronote instance root (`https://host/pronote`) from whatever the
    /// parent typed or the ENT linked: trailing slash, `mobile.parent.html`,
    /// `parent.html`, query and fragment are dropped. nil = not an https URL.
    /// An ENT may link Pronote through its own connector or CAS
    /// (`…/cas/login?service=https://….index-education.net/pronote/`): the
    /// Pronote URL carried in such a query is used instead of the ENT host.
    static func instanceURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        let carriers = ["service", "url", "redirect", "redirect_uri", "target", "targeturl"]
        if let nested = components.queryItems?.first(where: {
            carriers.contains($0.name.lowercased())
                && ($0.value?.lowercased().contains("pronote") ?? false)
                && ($0.value?.lowercased().hasPrefix("http") ?? false)
        })?.value, nested != text {
            return instanceURL(from: nested)
        }
        components.query = nil
        components.fragment = nil
        components.scheme = "https"
        var path = components.path
        if let last = path.split(separator: "/").last, last.lowercased().hasSuffix(".html") {
            path = String(path.dropLast(last.count))
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    /// The page to load: `<instance>/mobile.<space>.html?fd=1[&bydlg=…][&login=true]`.
    ///
    /// - `applicationMode` adds `bydlg` (« accès depuis une application »).
    ///   Measured on a real MonLycée instance (2026-10-25): with the app's
    ///   `bydlg`, Pronote does NOT delegate to the CAS and serves its own
    ///   form; without it, it redirects to the ENT's CAS. The ENT flows
    ///   therefore enter through `casEntryURL` first.
    /// - `directLogin` adds `login=true`, Pronote's own identification form.
    static func loginPageURL(
        instance: URL,
        kind: PronoteAccountKind,
        applicationMode: Bool = true,
        directLogin: Bool = false
    ) -> URL? {
        var components = URLComponents(url: instance, resolvingAgainstBaseURL: false)
        components?.path = instance.path + "/mobile.\(kind.path).html"
        var items = [URLQueryItem(name: "fd", value: "1")]
        if applicationMode { items.append(URLQueryItem(name: "bydlg", value: applicationIdentifier)) }
        if directLogin { items.append(URLQueryItem(name: "login", value: "true")) }
        components?.queryItems = items
        return components?.url
    }

    /// Entry of the ENT flows: the plain mobile page, which Pronote sends
    /// through the ENT's CAS (silent when the ENT session is open). Once
    /// back on it, `triggerScript` asks the page for the mobile token.
    static func casEntryURL(instance: URL, kind: PronoteAccountKind) -> URL? {
        loginPageURL(instance: instance, kind: kind, applicationMode: false)
    }

    /// Identifier of the public `infoMobileApp.json` document (the one
    /// pawnote and the official app read).
    static let infoMobileAppIdentifier = "0D264427-EEFC-4810-A9E9-346942A862A4"

    /// `<instance>/infoMobileApp.json?id=…`: public, no credentials. It
    /// describes the instance and, when it delegates to an ENT, carries a
    /// short-lived `CAS.jetonCAS`.
    static func infoMobileAppURL(instance: URL) -> URL? {
        var components = URLComponents(url: instance, resolvingAgainstBaseURL: false)
        components?.path = instance.path + "/infoMobileApp.json"
        components?.queryItems = [URLQueryItem(name: "id", value: infoMobileAppIdentifier)]
        return components?.url
    }

    /// True when `url` is the `infoMobileApp.json` document of `instance`.
    static func isInfoMobileApp(_ url: URL, of instance: URL) -> Bool {
        url.host?.lowercased() == instance.host?.lowercased()
            && url.lastPathComponent.lowercased() == "infomobileapp.json"
    }

    /// Run on the `infoMobileApp.json` page (same origin as Pronote): sets
    /// the cookies Pronote reads to know the visit comes from an application
    /// (`validationAppliMobile` = the instance's `jetonCAS`,
    /// `uuidAppliMobile` = this install's device id, `ielang` = French),
    /// valid 5 minutes, then goes to `next` (the plain mobile page, which
    /// still goes through the ENT's CAS). Back from the CAS, Pronote calls
    /// `hookAccesDepuisAppli` and renders the token document. This is the
    /// method of Papillon's ENT login; `bydlg` is not used, since it turns
    /// the CAS delegation off. Returns `cas` or `no-cas` for the logs (the
    /// token itself is never returned).
    static func appModeCookieScript(deviceUUID: String, next: URL) -> String {
        """
        (function () {
            var status = 'no-cas';
            try {
                var info = JSON.parse(document.body ? document.body.innerText : '{}');
                var jeton = info && info.CAS && info.CAS.jetonCAS;
                var expires = new Date(Date.now() + 5 * 60 * 1000).toUTCString();
                var tail = '; expires=' + expires + '; path=/';
                if (jeton) {
                    document.cookie = 'validationAppliMobile=' + jeton + tail;
                    status = 'cas';
                }
                document.cookie = 'uuidAppliMobile=' + '\(jsEscaped(deviceUUID))' + tail;
                document.cookie = 'ielang=1036' + tail;
            } catch (e) { status = 'error'; }
            window.location.assign('\(jsEscaped(next.absoluteString))');
            return status;
        })();
        """
    }

    private static func jsEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Asks an authenticated mobile page for the « application » token
    /// (the call `hookAccesDepuisAppli` makes in application mode). The
    /// method `passerEnModeValidationAppliMobile` is looked up on
    /// `GInterface`, `GApplication` and the objects `GApplication` holds
    /// (and their prototypes), then called on its owner. Returns a short
    /// diagnostic for the logs, code names only, never page data:
    /// `called <path>` or `no-method`, plus how many times Pronote called
    /// our hook (and the error it raised), the `GApplication` member names
    /// that look related, and the cookie names (not values).
    static func triggerScript(deviceUUID: String) -> String {
        """
        (function () {
            var out = [];
            try {
                var h = window.__notoHook || { calls: 0, error: '' };
                out.push('hook=' + h.calls + (h.error ? '(' + h.error + ')' : ''));
                var name = 'passerEnModeValidationAppliMobile';
                var owners = [];
                if (window.GInterface) { owners.push(['GInterface', window.GInterface]); }
                var app = window.GApplication;
                if (app) {
                    owners.push(['GApplication', app]);
                    for (var k in app) {
                        try {
                            var v = app[k];
                            if (v && (typeof v === 'object' || typeof v === 'function')) {
                                owners.push(['GApplication.' + k, v]);
                            }
                        } catch (e) {}
                    }
                    var names = [];
                    for (var p = app; p && names.length < 15; p = Object.getPrototypeOf(p)) {
                        Object.getOwnPropertyNames(p).forEach(function (n) {
                            if (/Appli|Mobile|Interface|Connexion|Ident/.test(n) && names.indexOf(n) < 0) { names.push(n); }
                        });
                        if (p === Object.prototype) { break; }
                    }
                    out.push('app=[' + names.slice(0, 15).join(',') + ']');
                }
                var found = '';
                for (var i = 0; i < owners.length && !found; i++) {
                    var o = owners[i][1];
                    if (typeof o[name] === 'function') {
                        try { o[name]('', '\(jsEscaped(deviceUUID))'); found = owners[i][0]; }
                        catch (e) { found = owners[i][0] + '!' + (e && e.name); }
                    }
                }
                out.unshift(found ? 'called ' + found : 'no-method');
                out.push('cookies=[' + document.cookie.split(';').map(function (c) {
                    return c.split('=')[0].trim();
                }).join(',') + ']');
            } catch (e) { out.unshift('error ' + (e && e.name)); }
            return out.join(' ');
        })();
        """
    }

    /// `host/path` of a URL for the logs: never the query or fragment,
    /// which carry CAS tickets and session identifiers.
    static func logLabel(_ url: URL?) -> String {
        guard let url else { return "nil" }
        return (url.host ?? "?") + url.path
    }

    /// True when `url` is the mobile page of `instance` (any space), i.e.
    /// the place where the token JSON can appear once the CAS round trip
    /// is over.
    static func isMobilePage(_ url: URL, of instance: URL) -> Bool {
        guard url.host?.lowercased() == instance.host?.lowercased() else { return false }
        let last = url.lastPathComponent.lowercased()
        return last.hasPrefix("mobile.") && last.hasSuffix(".html")
    }

    /// Script injected at document start on every page: defines the hook
    /// Pronote calls on a `bydlg` login. `deviceUUID` is the same identifier
    /// nōto presents on every token login for this install.
    static func hookScript(deviceUUID: String) -> String {
        let escaped = deviceUUID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        window.__notoHook = { calls: 0, error: '' };
        window.hookAccesDepuisAppli = function () {
            window.__notoHook.calls += 1;
            try {
                this.passerEnModeValidationAppliMobile('', '\(escaped)');
            } catch (e) {
                window.__notoHook.error = (e && e.name) || 'error';
                throw e;
            }
        };
        true;
        """
    }

    /// Reads the token document Pronote renders in the page body.
    /// Tolerates surrounding whitespace or text around the JSON object.
    /// nil = not (yet) the token page.
    static func parseTokenPayload(bodyText: String) -> TokenPayload? {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = trimmed[start...end]
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        guard let login = object["login"] as? String, !login.isEmpty,
              let token = object["mdp"] as? String, !token.isEmpty else { return nil }
        return TokenPayload(login: login, token: token)
    }

    struct TokenPayload: Equatable, Sendable {
        let login: String
        /// Single-use mobile token (Pronote names it `mdp` in this document).
        let token: String

        /// The stored shape every reconnect replays. `navigatorIdentifier`
        /// is filled by the first `loginToken` round trip.
        func refreshToken(instance: URL, kind: PronoteAccountKind) -> PronoteRefreshToken {
            PronoteRefreshToken(url: instance.absoluteString, token: token, username: login, kind: kind)
        }
    }
}
