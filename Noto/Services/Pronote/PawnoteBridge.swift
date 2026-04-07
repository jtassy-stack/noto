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
                    get(k) { return this._params[k] ?? null; }
                    toString() { return Object.entries(this._params).map(([k,v]) => k+'='+encodeURIComponent(v)).join('&'); }
                }
                globalThis.URLSearchParams = URLSearchParams;
            }
        """)

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
        let qrJSON = try JSONSerialization.data(withJSONObject: qrData)
        let qrJSONString = String(data: qrJSON, encoding: .utf8)!

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

        return PronoteRefreshToken(
            url: dict["url"] as? String ?? "",
            token: dict["token"] as? String ?? "",
            username: dict["username"] as? String ?? "",
            kind: .parent
        )
    }

    func loginWithToken(url: String, username: String, token: String, deviceUUID: String) async throws -> PronoteRefreshToken {
        context.evaluateScript("globalThis._pawnoteSession = PawnoteBridge.createSession()")
        session = context.objectForKeyedSubscript("_pawnoteSession")

        let result = try await callAsync("""
            PawnoteBridge.loginToken(
                \(sessionRef),
                "\(url.jsEscaped)",
                "\(username.jsEscaped)",
                "\(token.jsEscaped)",
                "\(deviceUUID.jsEscaped)"
            )
        """)

        guard let dict = result.toDictionary() as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid login response")
        }

        return PronoteRefreshToken(
            url: dict["url"] as? String ?? "",
            token: dict["token"] as? String ?? "",
            username: dict["username"] as? String ?? "",
            kind: .parent
        )
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
                isTest: l["isTest"] as? Bool ?? false
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
                themes: h["themes"] as? [String] ?? []
            )
        }
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
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            if let errorVal = context.objectForKeyedSubscript(errorKey),
               !errorVal.isNull, !errorVal.isUndefined,
               let errorStr = errorVal.toString(), !errorStr.isEmpty {
                context.evaluateScript("delete globalThis.\(resultKey); delete globalThis.\(errorKey)")
                throw PronoteError.invalidResponse("JS error: \(errorStr)")
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

                var request = URLRequest(url: url)
                request.httpMethod = method

                // Set headers
                if let headers = options.objectForKeyedSubscript("headers")?.toDictionary() as? [String: String] {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
                request.setValue("appliMobile=1", forHTTPHeaderField: "Cookie")

                // Set body
                if let content = options.objectForKeyedSubscript("content")?.toString(), content != "undefined" {
                    request.httpBody = content.data(using: .utf8)
                }

                // Handle redirect
                let redirect = options.objectForKeyedSubscript("redirect")?.toString()
                let delegate = redirect == "manual" ? NoRedirectDelegate() : nil
                let session = delegate != nil ? URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil) : URLSession.shared

                session.dataTask(with: request) { data, response, error in
                    if let error {
                        DispatchQueue.main.async { reject.call(withArguments: [error.localizedDescription]) }
                        return
                    }

                    let content = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                    // Extract set-cookie headers
                    let headers = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String] ?? [:]

                    DispatchQueue.main.async {
                        let result: [String: Any] = [
                            "content": content,
                            "statusCode": statusCode,
                            "headers": headers,
                        ]
                        resolve.call(withArguments: [result])
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
                const url = typeof urlOrHref === 'string' ? urlOrHref : urlOrHref.href || urlOrHref.toString();
                const result = await __nativeFetch({
                    url: url,
                    method: opts.method || 'GET',
                    headers: opts.headers || {},
                    content: opts.body || undefined,
                    redirect: opts.redirect || 'follow',
                });
                // Return format compatible with both standard fetch and @literate.ink
                const hdrs = result.headers || {};
                return {
                    ok: result.statusCode >= 200 && result.statusCode < 300,
                    status: result.statusCode,
                    text: async () => result.content,
                    json: async () => JSON.parse(result.content),
                    headers: {
                        get: (key) => hdrs[key] || hdrs[key.toLowerCase()] || null,
                        ...hdrs,
                    },
                };
            };

            // Also need URL class for pawnote
            if (typeof URL === 'undefined') {
                class URL {
                    constructor(url, base) {
                        if (base) url = base.replace(/\\/$/, '') + '/' + url.replace(/^\\//, '');
                        const match = url.match(/^(https?:\\/\\/[^/?#]+)(\\/[^?#]*)?([^#]*)?/);
                        this.protocol = url.startsWith('https') ? 'https:' : 'http:';
                        this.host = match ? match[1].replace(/^https?:\\/\\//, '') : '';
                        this.hostname = this.host.split(':')[0];
                        this.pathname = match && match[2] ? match[2] : '/';
                        this.search = match && match[3] ? match[3] : '';
                        this.href = url;
                        this.searchParams = new URLSearchParams(this.search);
                    }
                    toString() { return this.href; }
                }
                globalThis.URL = URL;
            }
        """)
    }

    private func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
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
