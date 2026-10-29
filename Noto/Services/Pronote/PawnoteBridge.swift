import Foundation
import JavaScriptCore

/// Bridge between Swift and pawnote (JavaScript) via JavaScriptCore.
/// Pawnote handles the complex Pronote encrypted protocol.
/// All data stays on-device — JS runs locally, no external servers.
@MainActor
final class PawnoteBridge {
    private let context: JSContext
    private var session: JSValue?

    init() throws {
        guard let context = JSContext() else {
            throw PronoteError.encryptionFailed("Cannot create JSContext")
        }
        self.context = context

        // Set up console.log/warn/error for debugging
        let log: @convention(block) (String) -> Void = { msg in NSLog("[pawnote] %@", msg) }
        let warn: @convention(block) (String) -> Void = { msg in NSLog("[pawnote WARN] %@", msg) }
        let error: @convention(block) (String) -> Void = { msg in NSLog("[pawnote ERROR] %@", msg) }

        let console = JSValue(newObjectIn: context)!
        console.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        console.setObject(unsafeBitCast(warn, to: AnyObject.self), forKeyedSubscript: "warn" as NSString)
        console.setObject(unsafeBitCast(error, to: AnyObject.self), forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // Polyfill browser globals missing in JavaScriptCore
        context.evaluateScript("""
            if (typeof globalThis === 'undefined') var globalThis = this;
            if (typeof self === 'undefined') var self = globalThis;
            if (typeof window === 'undefined') var window = globalThis;
            if (typeof navigator === 'undefined') var navigator = { userAgent: 'noto-ios' };
            if (typeof setTimeout === 'undefined') {
                var setTimeout = function(fn, ms) { fn(); return 0; };
                var clearTimeout = function() {};
                var setInterval = function(fn, ms) { return 0; };
                var clearInterval = function() {};
            }
            if (typeof TextEncoder === 'undefined') {
                class TextEncoder {
                    encode(str) {
                        const arr = [];
                        for (let i = 0; i < str.length; i++) {
                            let c = str.charCodeAt(i);
                            if (c < 0x80) arr.push(c);
                            else if (c < 0x800) { arr.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
                            else { arr.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
                        }
                        return new Uint8Array(arr);
                    }
                }
                globalThis.TextEncoder = TextEncoder;
            }
            if (typeof TextDecoder === 'undefined') {
                class TextDecoder {
                    decode(arr) {
                        if (!arr) return '';
                        const bytes = arr instanceof Uint8Array ? arr : new Uint8Array(arr);
                        let str = '';
                        for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
                        return str;
                    }
                }
                globalThis.TextDecoder = TextDecoder;
            }
        """)

        context.evaluateScript(Self.urlPolyfillJS)

        // Provide a fetch polyfill (pawnote needs HTTP)
        setupFetch(context)

        // Load the bundled pawnote
        guard let bundleURL = Bundle.main.url(forResource: "pawnote-bundle", withExtension: "js"),
              let bundleSource = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            throw PronoteError.encryptionFailed("Cannot load pawnote bundle")
        }

        context.evaluateScript(bundleSource)

        if let exception = context.exception {
            throw PronoteError.encryptionFailed("JS load error: \(exception)")
        }
    }

    // MARK: - Auth

    func loginWithQRCode(deviceUUID: String, pin: String, qrData: [String: String]) async throws -> PronoteRefreshToken {
        // Create session and store as global
        context.evaluateScript("globalThis._pawnoteSession = PawnoteBridge.createSession()")
        session = context.objectForKeyedSubscript("_pawnoteSession")

        // Call loginQrCode
        NSLog("[noto] loginWithQRCode qrData: url=%@", qrData["url"] ?? "nil")
        let qrJSON = try JSONSerialization.data(withJSONObject: qrData)
        guard let qrJSONString = String(data: qrJSON, encoding: .utf8) else {
            throw PronoteError.invalidResponse("Failed to encode QR data")
        }

        let result = try await callAsync("""
            PawnoteBridge.loginQrCode(
                \(sessionRef),
                "\(deviceUUID.jsEscaped)",
                "\(pin.jsEscaped)",
                \(qrJSONString)
            )
        """)

        guard let dict = result.toDictionary() as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid login response")
        }

        return Self.refreshToken(from: dict)
    }

    /// Login via ENT/CAS SSO. Requires CAS cookies to already be in HTTPCookieStorage.shared.
    /// Call `PawnoteBridge.transferCookies(_:for:)` before this method.
    func loginENT(url: String, deviceUUID: String) async throws -> PronoteRefreshToken {
        context.evaluateScript("globalThis._pawnoteSession = PawnoteBridge.createSession()")
        session = context.objectForKeyedSubscript("_pawnoteSession")

        let result = try await callAsync("""
            PawnoteBridge.loginENT(
                \(sessionRef),
                "\(url.jsEscaped)",
                "\(deviceUUID.jsEscaped)"
            )
        """)

        guard let dict = result.toDictionary() as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid ENT login response")
        }

        return Self.refreshToken(from: dict)
    }

    /// Transfer cookies from WKWebView to HTTPCookieStorage so pawnote's fetch polyfill can use them.
    @MainActor
    static func transferCookies(_ cookies: [HTTPCookie], for url: URL) {
        let storage = HTTPCookieStorage.shared
        var transferred = 0
        for cookie in cookies {
            // Only transfer cookies relevant to the Pronote domain
            if let host = url.host, cookie.domain.contains(host) || host.contains(cookie.domain.replacingOccurrences(of: ".", with: "", options: .anchored)) {
                storage.setCookie(cookie)
                transferred += 1
            }
        }
        // Also transfer CAS cookies (needed for SSO redirect)
        for cookie in cookies {
            if cookie.domain.contains("monlycee") || cookie.domain.contains("index-education") || cookie.domain.contains("pronote") {
                storage.setCookie(cookie)
                transferred += 1
            }
        }
        if transferred == 0 {
            NSLog("[noto][warning] transferCookies: 0/%d cookies matched for %@. ENT login may fail.", cookies.count, url.host ?? "?")
        } else {
            NSLog("[noto] transferCookies: %d/%d cookies transferred for %@", transferred, cookies.count, url.host ?? "?")
        }
    }

    /// Reopens a session from a stored token. Replays the account kind and
    /// the navigator identifier of the previous login (see
    /// `PronoteRefreshToken`); a missing navigator id (token stored by an
    /// earlier build) is passed as null and pawnote asks for a new one.
    func loginWithToken(_ stored: PronoteRefreshToken, deviceUUID: String) async throws -> PronoteRefreshToken {
        context.evaluateScript("globalThis._pawnoteSession = PawnoteBridge.createSession()")
        session = context.objectForKeyedSubscript("_pawnoteSession")

        let navigator = stored.navigatorIdentifier.map { "\"\($0.jsEscaped)\"" } ?? "null"
        let result = try await callAsync("""
            PawnoteBridge.loginToken(
                \(sessionRef),
                "\(stored.url.jsEscaped)",
                "\(stored.username.jsEscaped)",
                "\(stored.token.jsEscaped)",
                "\(deviceUUID.jsEscaped)",
                \(stored.kind.rawValue),
                \(navigator)
            )
        """)

        guard let dict = result.toDictionary() as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid login response")
        }

        return Self.refreshToken(from: dict)
    }

    /// Maps a pawnote login result. `kind` is pawnote's numeric AccountKind
    /// (6 élève / 7 parent / 8 professeur); an unknown value falls back to
    /// parent, the historical assumption.
    static func refreshToken(from dict: [String: Any]) -> PronoteRefreshToken {
        let kindRaw = (dict["kind"] as? Int) ?? Int((dict["kind"] as? Double) ?? 0)
        let navigator = (dict["navigatorIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PronoteRefreshToken(
            url: dict["url"] as? String ?? "",
            token: dict["token"] as? String ?? "",
            username: dict["username"] as? String ?? "",
            kind: PronoteAccountKind(rawValue: kindRaw) ?? .parent,
            navigatorIdentifier: navigator
        )
    }

    /// Turns the message of a JS exception into the typed error the UI
    /// knows how to explain. Everything else stays `invalidResponse`.
    static func error(fromJSMessage message: String) -> PronoteError {
        if message.hasPrefix("DOUBLE_AUTH_REQUIRED") { return .doubleAuthRequired }
        let lower = message.lowercased()
        if lower.contains("suspended") || lower.contains("suspendu") { return .suspendedIP }
        if lower.contains("rate limit") || lower.contains("too many") { return .rateLimited }
        return .invalidResponse("JS error: \(message)")
    }

    // MARK: - Children

    func getChildren() -> [PronoteChildResource] {
        guard let result = context.evaluateScript("PawnoteBridge.getChildren(\(sessionRef))"),
              let list = result.toArray() as? [[String: Any]] else { return [] }

        return list.map {
            PronoteChildResource(
                id: $0["id"] as? String ?? "",
                name: $0["name"] as? String ?? "",
                className: $0["className"] as? String ?? "",
                establishment: ""
            )
        }
    }

    func setActiveChild(index: Int) {
        context.evaluateScript("PawnoteBridge.setActiveChild(\(sessionRef), \(index))")
    }

    // MARK: - Data Fetch

    func fetchGrades() async throws -> [PronoteGrade] {
        let result = try await callAsync("PawnoteBridge.fetchGrades(\(sessionRef))")
        guard let list = result.toArray() as? [[String: Any]] else { return [] }

        return list.compactMap { g in
            guard let id = g["id"] as? String else { return nil }
            return PronoteGrade(
                id: id,
                subjectName: g["subject"] as? String ?? "?",
                value: g["value"] as? Double,
                kind: PronoteGradeKind(rawValue: g["kind"] as? Int ?? 0) ?? .grade,
                outOf: g["outOf"] as? Double ?? 20,
                coefficient: g["coefficient"] as? Double ?? 1,
                date: parseISO(g["date"] as? String) ?? .now,
                chapter: nil,
                comment: g["comment"] as? String,
                classAverage: g["classAverage"] as? Double,
                classMin: g["classMin"] as? Double,
                classMax: g["classMax"] as? Double
            )
        }
    }

    func fetchTimetable(from: Date, to: Date) async throws -> [PronoteLesson] {
        let startISO = ISO8601DateFormatter().string(from: from)
        let endISO = ISO8601DateFormatter().string(from: to)

        let result = try await callAsync("PawnoteBridge.fetchTimetable(\(sessionRef), '\(startISO)', '\(endISO)')")
        guard let list = result.toArray() as? [[String: Any]] else { return [] }

        return list.compactMap { l in
            guard let id = l["id"] as? String else { return nil }
            return PronoteLesson(
                id: id,
                subject: l["subject"] as? String,
                startDate: parseISO(l["startDate"] as? String) ?? .now,
                endDate: parseISO(l["endDate"] as? String) ?? .now,
                cancelled: l["cancelled"] as? Bool ?? false,
                status: l["status"] as? String,
                teacherNames: l["teacherNames"] as? [String] ?? [],
                classrooms: l["classrooms"] as? [String] ?? [],
                isTest: l["isTest"] as? Bool ?? false,
                lessonResourceID: l["lessonResourceID"] as? String
            )
        }
    }

    func fetchHomework(from: Date, to: Date) async throws -> [PronoteAssignment] {
        let startISO = ISO8601DateFormatter().string(from: from)
        let endISO = ISO8601DateFormatter().string(from: to)

        let result = try await callAsync("PawnoteBridge.fetchHomework(\(sessionRef), '\(startISO)', '\(endISO)')")
        guard let list = result.toArray() as? [[String: Any]] else { return [] }

        return list.compactMap { h in
            guard let id = h["id"] as? String else { return nil }
            return PronoteAssignment(
                id: id,
                subjectName: h["subject"] as? String ?? "?",
                description: h["description"] as? String ?? "",
                deadline: parseISO(h["deadline"] as? String) ?? .now,
                done: h["done"] as? Bool ?? false,
                difficulty: PronoteAssignmentDifficulty(rawValue: h["difficulty"] as? Int ?? 0) ?? .none,
                themes: h["themes"] as? [String] ?? [],
                resourceID: h["resourceID"] as? String
            )
        }
    }

    /// Cahier de textes lesson contents (Pronote `PageCahierDeTexte`, onglet
    /// 89) between two dates. Read-only request to the session's own Pronote
    /// instance; no other host. Returns `[]` when the tab is not available.
    func fetchLessonContents(from: Date, to: Date) async throws -> [PronoteLessonContentEntry] {
        let startISO = ISO8601DateFormatter().string(from: from)
        let endISO = ISO8601DateFormatter().string(from: to)

        let result = try await callAsync(
            "PawnoteBridge.fetchLessonContents(\(sessionRef), '\(startISO)', '\(endISO)')")
        guard let object = result.toObject(), JSONSerialization.isValidJSONObject(object) else { return [] }
        let data = try JSONSerialization.data(withJSONObject: object)
        let payload = try JSONDecoder().decode(PronoteLessonContentsPayload.self, from: data)
        #if DEBUG
        // TEMPORARY (3.8 shape check, remove once verified on a real parent
        // account): key names only, never values — lesson text must not be logged.
        NSLog("[noto][debug] Pronote cahier de textes keys: root=%@ entry=%@ content=%@",
              (payload.rawKeys ?? []).joined(separator: ","),
              (payload.rawEntryKeys ?? []).joined(separator: ","),
              (payload.rawContentKeys ?? []).joined(separator: ","))
        #endif
        return payload.entries ?? []
    }

    func fetchDiscussions() async throws -> [PronoteDiscussion] {
        let result = try await callAsync("PawnoteBridge.fetchDiscussions(\(sessionRef))")
        guard let list = result.toArray() as? [[String: Any]] else { return [] }

        return list.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return PronoteDiscussion(
                participantsMessageID: id,
                subject: d["subject"] as? String ?? "",
                creator: d["creator"] as? String,
                date: parseISO(d["date"] as? String) ?? .now,
                unreadCount: d["unreadCount"] as? Int ?? 0
            )
        }
    }

    // MARK: - Private

    private var sessionRef: String { "_pawnoteSession" }

    /// Call an async JS function that returns a JSON-serializable value.
    /// Converts result to JSON string in JS, passes String (Sendable) back to Swift.
    private func callAsync(_ script: String) async throws -> JSValue {
        // Strategy: run the async JS, serialize result to JSON in JS,
        // store in a global, then read it synchronously.
        let resultKey = "_asyncResult_\(Int.random(in: 0..<999999))"
        let errorKey = "_asyncError_\(Int.random(in: 0..<999999))"

        context.evaluateScript("""
            (async () => {
                try {
                    const result = await \(script);
                    globalThis.\(resultKey) = JSON.stringify(result);
                    globalThis.\(errorKey) = null;
                } catch (e) {
                    globalThis.\(resultKey) = null;
                    globalThis.\(errorKey) = e.message || String(e);
                }
            })()
        """)

        // Poll for completion (JS promises resolve on the same thread in JSContext)
        // Give it up to 30 seconds
        for _ in 0..<300 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            if let errorVal = context.objectForKeyedSubscript(errorKey),
               !errorVal.isNull, !errorVal.isUndefined,
               let errorStr = errorVal.toString(), !errorStr.isEmpty {
                context.evaluateScript("delete globalThis.\(resultKey); delete globalThis.\(errorKey)")
                throw Self.error(fromJSMessage: errorStr)
            }

            if let resultVal = context.objectForKeyedSubscript(resultKey),
               !resultVal.isNull, !resultVal.isUndefined {
                // Parse JSON string back to JSValue
                let parsed = context.evaluateScript("JSON.parse(globalThis.\(resultKey))")
                context.evaluateScript("delete globalThis.\(resultKey); delete globalThis.\(errorKey)")
                return parsed ?? JSValue(undefinedIn: context)
            }
        }

        context.evaluateScript("delete globalThis.\(resultKey); delete globalThis.\(errorKey)")
        throw PronoteError.invalidResponse("JS async timeout")
    }

    // MARK: - Fetch Polyfill

    /// URLSearchParams + URL polyfills for JavaScriptCore, which has neither.
    /// `href` is computed from `searchParams`: pawnote sets Pronote's query
    /// parameters through `searchParams.set`. Exposed for tests.
    nonisolated static let urlPolyfillJS = """
            if (typeof URLSearchParams === 'undefined') {
                class URLSearchParams {
                    constructor(init) {
                        this._params = {};
                        if (typeof init === 'string') {
                            init.replace(/^\\?/, '').split('&').forEach(p => {
                                const [k, v] = p.split('=');
                                if (k) this._params[decodeURIComponent(k)] = decodeURIComponent(v || '');
                            });
                        }
                    }
                    set(k, v) { this._params[k] = String(v); }
                    append(k, v) { this._params[k] = String(v); }
                    get(k) { return this._params[k] ?? null; }
                    has(k) { return Object.prototype.hasOwnProperty.call(this._params, k); }
                    delete(k) { delete this._params[k]; }
                    entries() { return Object.entries(this._params)[Symbol.iterator](); }
                    toString() { return Object.entries(this._params).map(([k,v]) => k+'='+encodeURIComponent(v)).join('&'); }
                }
                globalThis.URLSearchParams = URLSearchParams;
            }
            if (typeof URL === 'undefined') {
                class URL {
                    constructor(url, base) {
                        if (base) url = base.replace(/\\/$/, '') + '/' + url.replace(/^\\//, '');
                        const match = url.match(/^(https?:\\/\\/[^/?#]+)(\\/[^?#]*)?([^#]*)?/);
                        this.protocol = url.startsWith('https') ? 'https:' : 'http:';
                        this.host = match ? match[1].replace(/^https?:\\/\\//, '') : '';
                        this.hostname = this.host.split(':')[0];
                        this.pathname = match && match[2] ? match[2] : '/';
                        const hashIndex = url.indexOf('#');
                        this.hash = hashIndex === -1 ? '' : url.slice(hashIndex);
                        this.origin = this.protocol + '//' + this.host;
                        this.searchParams = new URLSearchParams(match && match[3] ? match[3] : '');
                    }
                    // Computed from searchParams so that searchParams.set(...) reaches
                    // the request: pawnote builds Pronote URLs that way (fd=1, bydlg,
                    // login). A href frozen at construction dropped them, and Pronote
                    // answered « Votre navigateur est incompatible » instead of the
                    // page holding Start() (seen on 2026.2.7 after the MonLycée CAS).
                    get search() {
                        const q = this.searchParams.toString();
                        return q ? '?' + q : '';
                    }
                    get href() { return this.origin + this.pathname + this.search + this.hash; }
                    toString() { return this.href; }
                    toJSON() { return this.href; }
                }
                globalThis.URL = URL;
            }
        """

    private func setupFetch(_ context: JSContext) {
        // Provide a native fetch implementation for pawnote
        let fetchImpl: @convention(block) (JSValue) -> JSValue = { options in
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                guard let resolve, let reject else { return }

                let urlString = options.objectForKeyedSubscript("url")?.toString() ?? ""
                let method = options.objectForKeyedSubscript("method")?.toString() ?? "GET"

                guard let url = URL(string: urlString) else {
                    reject.call(withArguments: ["Invalid URL: \(urlString)"])
                    return
                }

                NSLog("[noto] pawnote fetch: %@ %@", method, urlString)
                var request = URLRequest(url: url)
                request.httpMethod = method
                // Let HTTPCookieStorage.shared handle cookies automatically (required for CAS redirects)
                request.httpShouldHandleCookies = true

                // Set headers (but never override Cookie — let URLSession handle it)
                if let headers = options.objectForKeyedSubscript("headers")?.toDictionary() as? [String: String] {
                    for (key, value) in headers {
                        if key.lowercased() != "cookie" {
                            request.setValue(value, forHTTPHeaderField: key)
                        }
                    }
                }
                // Inject appliMobile=1 as a separate cookie so it's stored and forwarded on redirects.
                // `appliMobile: false` (the ENT page fetch) removes it instead: with it Pronote
                // serves its direct login page and never redirects to the ENT's CAS.
                if options.objectForKeyedSubscript("appliMobile")?.isBoolean == true,
                   options.objectForKeyedSubscript("appliMobile")?.toBool() == false {
                    for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.name == "appliMobile" {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                } else if let appliCookie = HTTPCookie(properties: [
                    .name: "appliMobile", .value: "1",
                    .domain: url.host ?? "", .path: "/", .discard: true
                ]) {
                    HTTPCookieStorage.shared.setCookie(appliCookie)
                }

                // Set body
                if let content = options.objectForKeyedSubscript("content")?.toString(), content != "undefined" {
                    request.httpBody = content.data(using: .utf8)
                }

                // Handle redirect — use shared cookie storage always so appliMobile=1 is sent
                let redirect = options.objectForKeyedSubscript("redirect")?.toString()
                let session: URLSession
                if redirect == "manual" {
                    let config = URLSessionConfiguration.default
                    config.httpCookieStorage = .shared
                    config.httpCookieAcceptPolicy = .always
                    session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
                } else {
                    session = URLSession.shared
                }

                // JSValue is not Sendable; both callbacks are only ever invoked
                // back on the main queue (where the JSContext lives), so crossing
                // the URLSession completion boundary is safe. Required by Swift 6.4
                // (Xcode 27) region-isolation checking.
                nonisolated(unsafe) let jsResolve = resolve
                nonisolated(unsafe) let jsReject = reject
                session.dataTask(with: request) { data, response, error in
                    if let error {
                        DispatchQueue.main.async { jsReject.call(withArguments: [error.localizedDescription]) }
                        return
                    }

                    let content = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                    // Extract set-cookie headers
                    let headers = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String] ?? [:]

                    #if DEBUG
                    NSLog("[noto] pawnote response: %d %@ (%.200@)", statusCode, urlString, content)
                    #endif
                    DispatchQueue.main.async {
                        let result: [String: Any] = [
                            "content": content,
                            "statusCode": statusCode,
                            "headers": headers,
                            "finalUrl": response?.url?.absoluteString ?? "",
                        ]
                        jsResolve.call(withArguments: [result])
                    }
                }.resume()
            }
            return promise!
        }

        context.setObject(unsafeBitCast(fetchImpl, to: AnyObject.self), forKeyedSubscript: "__nativeFetch" as NSString)

        // Override fetch to match what @literate.ink/utilities expects:
        // fetch(url, opts) → { status, content: string, headers }
        context.evaluateScript("""
            globalThis.fetch = async (urlOrHref, opts = {}) => {
                const url = typeof urlOrHref === 'string' ? urlOrHref : urlOrHref.toString();
                const result = await __nativeFetch({
                    url: url,
                    method: opts.method || 'GET',
                    headers: opts.headers || {},
                    content: opts.body || undefined,
                    redirect: opts.redirect || 'follow',
                    appliMobile: opts.appliMobile === false ? false : true,
                });
                // Return format compatible with both standard fetch and @literate.ink
                const hdrs = result.headers || {};
                return {
                    ok: result.statusCode >= 200 && result.statusCode < 300,
                    status: result.statusCode,
                    url: result.finalUrl || url,
                    text: async () => result.content,
                    json: async () => JSON.parse(result.content),
                    headers: {
                        get: (key) => hdrs[key] || hdrs[key.toLowerCase()] || null,
                        ...hdrs,
                    },
                };
            };

        """)
    }

    private func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - No Redirect Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Don't follow redirects
    }
}

// MARK: - String JS Escape

private extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
