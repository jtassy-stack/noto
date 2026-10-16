import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "MonLyceeMailService")

// MARK: - Errors

/// Why a monlycee.net webmail call failed. Carries no message content and
/// no identifier — safe to log as-is.
enum MonLyceeMailError: Error, Equatable, Sendable {
    /// No `CSRF_TOKEN` cookie, even after visiting the webmail once: the SSO
    /// session is gone (logged out, cookies cleared) or never existed.
    case noSession
    /// 401/403, or a redirect away from monlycee.net: the session cookies
    /// expired, or the WAF in front of the API refused the request.
    case unauthorized(status: Int)
    /// Any other non-200 status.
    case http(status: Int)
    /// 200 but not the JSON shape the webmail returns (typically an HTML
    /// login page served in place of the API response).
    case invalidPayload
    /// Transport failure (offline, timeout, TLS, …).
    case network(URLError.Code)
}

// MARK: - Header

/// One row of `getMailHeaderList.json`, decoded into a Sendable value so it
/// can cross from the network layer to the MainActor SwiftData writer.
struct MonLyceeMailHeader: Sendable, Equatable {
    let msgId: Int
    let from: String
    let subject: String
    let date: Date?
    let unread: Bool
}

// MARK: - Parser (pure)

/// Pure decoding of the monlycee.net webmail JSON API. No network, no
/// SwiftData: every branch is covered by fixtures in
/// `MonLyceeMailParserTests`.
///
/// The shapes below come from the webmail's own XHR traffic
/// (`apis-mail.monlycee.net/webmail/xml/*.json`):
///   - header list: `{"response": {"mailHeader": [{"id": {"msgId": 42}, "from": …, "subject": …, "dateUTC": …, "unread": …}]}}`
///   - single mail: `{"response": {"mail": {"message": "<html>…"}}}`
/// The parser is deliberately tolerant on scalar types (`msgId` as number or
/// string, `dateUTC` as epoch seconds/ms or string, `from` as string or
/// `{name, email}` object) because the API is undocumented.
enum MonLyceeMailParser {

    static func headers(from data: Data) throws(MonLyceeMailError) -> [MonLyceeMailHeader] {
        let response = try responseObject(from: data)
        guard let rows = response["mailHeader"] as? [[String: Any]] else { return [] }
        return rows.compactMap(header(from:))
    }

    static func body(from data: Data) throws(MonLyceeMailError) -> String {
        let response = try responseObject(from: data)
        guard let mail = response["mail"] as? [String: Any] else { throw .invalidPayload }
        return plainText(fromHTML: mail["message"] as? String ?? "")
    }

    static func header(from row: [String: Any]) -> MonLyceeMailHeader? {
        guard let idInfo = row["id"] as? [String: Any],
              let msgId = intValue(idInfo["msgId"]) else { return nil }
        let subject = (row["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MonLyceeMailHeader(
            msgId: msgId,
            from: sender(from: row["from"]),
            // Same placeholder as `IMAPService.fetchInbox` so the composite
            // dedupe against IMAP rows compares like with like.
            subject: subject.isEmpty ? "(sans objet)" : subject,
            date: date(from: row),
            unread: (row["unread"] as? Bool) ?? false
        )
    }

    /// Display name when present, otherwise the bare address — the same
    /// rule `IMAPService.extractDisplayName` applies, so a mail seen through
    /// both channels carries the same `sender`.
    static func sender(from raw: Any?) -> String {
        if let dict = raw as? [String: Any] {
            let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty { return name }
            return (dict["email"] as? String) ?? (dict["address"] as? String) ?? ""
        }
        guard let string = raw as? String else { return "" }
        if let lt = string.range(of: "<") {
            let name = string[string.startIndex..<lt.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
            return string[lt.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return string.trimmingCharacters(in: .whitespaces)
    }

    /// `dateUTC` has been seen both as a number and as a numeric string, in
    /// seconds or milliseconds; `date` is a display string fallback.
    static func date(from row: [String: Any]) -> Date? {
        if let epoch = doubleValue(row["dateUTC"]) {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        if let string = row["date"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.timeZone = TimeZone(identifier: "Europe/Paris")
            for format in ["dd/MM/yyyy HH:mm", "yyyy-MM-dd'T'HH:mm:ssZ"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: string) { return date }
            }
        }
        return nil
    }

    /// Reduces the webmail's HTML body to the plain text the feed renders.
    static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(p|div|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"),
                               ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func responseObject(from data: Data) throws(MonLyceeMailError) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            throw .invalidPayload
        }
        return response
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }
}

// MARK: - Network client

/// HTTP layer for `apis-mail.monlycee.net`. Talks to monlycee.net hosts
/// only, authenticates with the SSO session cookies already sitting in the
/// session's cookie storage (transferred from the login WKWebView by
/// `ENTLoginView`), and never sees a password.
///
/// The session is injectable so tests can route every request through a
/// `URLProtocol` stub; the CSRF cookie is read from that same session's
/// cookie storage, never from a global.
struct MonLyceeWebmailClient: Sendable {
    static let apiBaseURL = URL(string: "https://apis-mail.monlycee.net/webmail/xml")!
    static let webmailURL = URL(string: "https://web-mail.monlycee.net/main.html")!
    static let csrfCookieName = "CSRF_TOKEN"

    /// The WAF in front of apis-mail.monlycee.net (F5 BIG-IP, per the TS01…
    /// cookies) 403s a request that does not look like the webmail's own
    /// same-origin XHR call.
    /// Per-request cap, well under URLSession's 60 s default: a sync makes
    /// up to `pageSize + 2` calls in a row, so a stalled WAF must fail fast.
    static let requestTimeout: TimeInterval = 15

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `true` for `monlycee.net` and its subdomains (cookie domains may carry
    /// a leading dot). Stricter than `contains("monlycee")`, which would also
    /// match an unrelated `monlycee-foo.com`.
    static func isMonLyceeDomain(_ domain: String) -> Bool {
        var host = domain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return host == "monlycee.net" || host.hasSuffix(".monlycee.net")
    }

    // MARK: CSRF

    /// The webmail's `tok` parameter is its own `CSRF_TOKEN` cookie. That
    /// cookie is minted by `web-mail.monlycee.net`, which the ENT SSO flow
    /// never visits — so when it is missing, one GET to the webmail page
    /// (riding the SSO cookies) mints it, exactly like a browser would.
    func resolveCSRFToken() async throws(MonLyceeMailError) -> String {
        if let token = storedCSRFToken() { return token }

        var request = URLRequest(url: Self.webmailURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try await perform(request)

        guard let token = storedCSRFToken() else { throw .noSession }
        return token
    }

    func storedCSRFToken() -> String? {
        let storage = session.configuration.httpCookieStorage ?? .shared
        return storage.cookies?.first {
            $0.name == Self.csrfCookieName && Self.isMonLyceeDomain($0.domain) && !$0.value.isEmpty
        }?.value
    }

    // MARK: Endpoints

    /// First page of the inbox, most recent first.
    func fetchHeaders(csrfToken: String, pageSize: Int) async throws(MonLyceeMailError) -> [MonLyceeMailHeader] {
        let request = Self.formRequest(path: "getMailHeaderList.json", params: [
            ("FOLDER", "SF_INBOX"),
            ("SORTBY", "45"),
            ("FLAGS_FILTER_TYPE", "0"),
            ("NBDISPLAYMSG", "\(pageSize)"),
            ("returnProfileId", "false"),
            ("append", "false"),
            ("PAGE", "1"),
            ("START", "0"),
            ("END", "\(max(pageSize - 1, 0))"),
            ("callContext", "readRouteLoad"),
            ("DISPLAY_ATTACHMENTS_INFOS", "false"),
            ("tok", csrfToken),
        ])
        return try MonLyceeMailParser.headers(from: try await perform(request))
    }

    func fetchBody(msgId: Int, csrfToken: String) async throws(MonLyceeMailError) -> String {
        let request = Self.formRequest(path: "getMail.json", params: [
            ("FOLDER", "SF_INBOX"),
            ("IDMSG", "\(msgId)"),
            ("IGNORE_SESSION_DATA", "true"),
            ("SORTBY", "45"),
            ("callContext", "readRouteLoad"),
            ("tok", csrfToken),
        ])
        return try MonLyceeMailParser.body(from: try await perform(request))
    }

    // MARK: Request building (pure)

    /// The webmail API is RPC over POST even for reads: both endpoints used
    /// here only read the inbox, nothing is sent, flagged or deleted.
    static func formRequest(path: String, params: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://web-mail.monlycee.net/main.html", forHTTPHeaderField: "Referer")
        request.setValue("https://web-mail.monlycee.net", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncode(params).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded` per the WHATWG URL spec: only
    /// `A-Za-z0-9-._*` pass through, space becomes `+`. (`.urlQueryAllowed`
    /// would leave `&`, `=` and `+` raw and corrupt a token containing them.)
    static func formEncode(_ params: [(String, String)]) -> String {
        params.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }.joined(separator: "&")
    }

    private static let formAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")

    private static func encodeComponent(_ string: String) -> String {
        (string.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "")
            .replacingOccurrences(of: " ", with: "+")
    }

    // MARK: Transport

    private func perform(_ request: URLRequest) async throws(MonLyceeMailError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw .network(error.code)
        } catch {
            throw .network(.unknown)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidPayload }
        // An expired session is redirected to the CAS login page: anything
        // that ends up off monlycee.net is a lost session, not mail.
        if let host = http.url?.host, !Self.isMonLyceeDomain(host) {
            throw .unauthorized(status: http.statusCode)
        }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw .unauthorized(status: http.statusCode)
        default: throw .http(status: http.statusCode)
        }
    }
}

// MARK: - Sync

/// Imports monlycee.net mail into SwiftData through the webmail's own JSON
/// API, reusing the SSO session established at ENT login — no separate
/// credential entry, nothing stored besides the messages themselves.
///
/// Best-effort throughout: session cookies expire between launches, and a
/// failure here must never block the notes/homework sync that runs
/// alongside it (`ENTLoginView`, `FullSyncService`). The next ENT login
/// re-establishes the session.
@MainActor
enum MonLyceeMailService {
    /// `imapProvider` stamp on rows inserted by this service, distinct from
    /// `"monlycee"` (the IMAP preset) so the two channels stay tellable apart.
    static let providerTag = "monlycee-sso"
    /// `IMAPServerConfig.providerID` of the manual monlycee.net IMAP preset.
    static let imapProviderID = "monlycee"

    /// The SSO channel steps aside when the parent connected the same inbox
    /// via IMAP ("Connecter une boîte mail" → MonLycée): one inbox, one
    /// fetcher. Any *other* IMAP mailbox (Gmail, Outlook…) does not count.
    static func shouldSync(configuredIMAPProviderIDs: [String]) -> Bool {
        !configuredIMAPProviderIDs.contains(imapProviderID)
    }

    static var shouldSyncWithCurrentIMAPConfig: Bool {
        shouldSync(configuredIMAPProviderIDs: IMAPService.loadConfigs().map(\.providerID))
    }

    /// Children whose sync is running. The ENT login fires a sync in the
    /// background right before `RootView`/`FullSyncService` may start one
    /// for the same freshly added child: both would pass `isDuplicate`
    /// before either saves, and insert every mail twice.
    private static var inFlight: Set<PersistentIdentifier> = []

    /// Whether the body loop must stop after `error`. Only a plain HTTP
    /// error is specific to one message (worth skipping, retried next
    /// sync); everything else fails every remaining body the same way:
    ///   - `.unauthorized` / `.noSession`: the SSO session is gone;
    ///   - `.network`: offline or a stalled WAF — each further call would
    ///     wait for its own timeout;
    ///   - `.invalidPayload`: an expired session served as a 200 HTML login
    ///     page still on *.monlycee.net.
    static func shouldStopBodyLoop(after error: MonLyceeMailError) -> Bool {
        switch error {
        case .http: return false
        case .unauthorized, .noSession, .network, .invalidPayload: return true
        }
    }

    /// Syncs the first page of the inbox into `child.messages`.
    /// - Returns: the number of inserted messages (0 when a sync for this
    ///   child is already running), or why it stopped.
    @discardableResult
    static func sync(
        child: Child,
        modelContext: ModelContext,
        client: MonLyceeWebmailClient = MonLyceeWebmailClient(),
        pageSize: Int = 50
    ) async -> Result<Int, MonLyceeMailError> {
        let childID = child.persistentModelID
        guard inFlight.insert(childID).inserted else {
            logger.info("monlycee webmail sync already running for this child — skipped")
            return .success(0)
        }
        defer { inFlight.remove(childID) }

        let headers: [MonLyceeMailHeader]
        let token: String
        do throws(MonLyceeMailError) {
            token = try await client.resolveCSRFToken()
            headers = try await client.fetchHeaders(csrfToken: token, pageSize: pageSize)
        } catch {
            logger.notice("monlycee webmail sync skipped: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }

        var inserted = 0
        var bodyFailures = 0
        var stoppedEarly = false
        for header in headers where !isDuplicate(header, among: child.messages) {
            let body: String
            do throws(MonLyceeMailError) {
                body = try await client.fetchBody(msgId: header.msgId, csrfToken: token)
            } catch {
                bodyFailures += 1
                if shouldStopBodyLoop(after: error) {
                    logger.notice("monlycee webmail body loop stopped: \(String(describing: error), privacy: .public)")
                    stoppedEarly = true
                    break
                }
                continue
            }
            let message = makeMessage(from: header, body: body)
            message.child = child
            modelContext.insert(message)
            inserted += 1
        }

        if inserted > 0 {
            do { try modelContext.save() } catch {
                logger.error("monlycee webmail save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Counts only — no child name, no sender, no subject (RGPD, same
        // rule as `IMAPSyncService.process`).
        logger.info("monlycee webmail sync: fetched=\(headers.count) inserted=\(inserted) bodyFailures=\(bodyFailures) stoppedEarly=\(stoppedEarly)")
        return .success(inserted)
    }

    // MARK: Mapping & dedupe (pure)

    static func makeMessage(from header: MonLyceeMailHeader, body: String) -> Message {
        let message = Message(
            sender: header.from,
            subject: header.subject,
            body: body,
            date: header.date ?? .now,
            source: .monlycee,
            kind: .conversation,
            imapUID: String(header.msgId),
            imapProvider: providerTag
        )
        message.read = !header.unread
        return message
    }

    /// A header is already known when:
    ///   1. this channel stored the same webmail `msgId` (primary key), or
    ///   2. the monlycee.net IMAP channel stored the same mail — webmail ids
    ///      and IMAP UIDs are different namespaces, so match on
    ///      (sender, subject, same day) instead. Covers a parent who adds the
    ///      IMAP inbox after SSO mail was already imported.
    /// Pronote, ENT and other IMAP providers are never matched: a collision
    /// with them is a different message and must not be swallowed.
    static func isDuplicate(
        _ header: MonLyceeMailHeader,
        among messages: [Message],
        calendar: Calendar = .current
    ) -> Bool {
        let uid = String(header.msgId)
        let sender = normalized(header.from)
        let subject = normalized(header.subject)
        return messages.contains { message in
            switch message.source {
            case .monlycee:
                return message.imapUID == uid
            case .imap:
                guard message.imapProvider == imapProviderID,
                      message.kind == .conversation,
                      let date = header.date else { return false }
                return normalized(message.sender) == sender
                    && normalized(message.subject) == subject
                    && calendar.isDate(message.date, inSameDayAs: date)
            case .pronote, .ent:
                return false
            }
        }
    }

    /// Shared with `IMAPSyncService.findSSOMatch` so both directions of the
    /// cross-channel dedupe compare the same way.
    static func normalized(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}
