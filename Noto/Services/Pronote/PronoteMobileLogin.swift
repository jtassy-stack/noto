import Foundation

/// The « accès depuis une application » handshake of Pronote's own mobile
/// page, the route the official app and Papillon use when the parent logs
/// in through an ENT: nōto opens the establishment's Pronote URL in a web
/// view, Pronote redirects to the ENT's CAS, the parent signs in on the real
/// ENT page, and Pronote comes back to its mobile page. Opened with the
/// `bydlg` application identifier and `login=true`, that page calls
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
    static func instanceURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
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

    /// The page to load: `<instance>/mobile.<space>.html?fd=1&bydlg=…&login=true`.
    static func loginPageURL(instance: URL, kind: PronoteAccountKind) -> URL? {
        var components = URLComponents(url: instance, resolvingAgainstBaseURL: false)
        components?.path = instance.path + "/mobile.\(kind.path).html"
        components?.queryItems = [
            URLQueryItem(name: "fd", value: "1"),
            URLQueryItem(name: "bydlg", value: applicationIdentifier),
            URLQueryItem(name: "login", value: "true"),
        ]
        return components?.url
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
        window.hookAccesDepuisAppli = function () {
            this.passerEnModeValidationAppliMobile('', '\(escaped)');
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
