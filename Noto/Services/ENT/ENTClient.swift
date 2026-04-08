import Foundation

/// Debug-only logging — no PII in production
@inline(__always)
private func entLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

/// Client for ENT/PCN (Paris Classe Numérique) REST API.
/// Session managed via cookie jar — credentials stay on-device.
final class ENTClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    /// Dedicated in-memory cookie storage — never persisted to disk
    static let cookieStorage: HTTPCookieStorage = {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        return storage
    }()

    init(provider: ENTProvider = .pcn) {
        self.baseURL = provider.baseURL
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = ENTClient.cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
    }

    /// Import cookies from WKWebView into our ephemeral session
    static func importCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }

    // MARK: - Auth

    func login(email login: String, password: String) async throws {
        // Step 1: GET the login page to find the form action and hidden fields (CAS tokens)
        let loginPageURL = URL(string: "\(baseURL.absoluteString)/auth/login")!
        let (pageData, _) = try await session.data(for: URLRequest(url: loginPageURL))
        let pageHTML = String(data: pageData, encoding: .utf8) ?? ""

        // Extract CAS hidden fields (lt, execution, _eventId) if present
        var formFields: [(String, String)] = [
            ("email", login),
            ("password", password),
        ]

        // Parse hidden inputs from the login form
        let hiddenPattern = #"<input[^>]+type=["\']hidden["\'][^>]*>"#
        if let regex = try? NSRegularExpression(pattern: hiddenPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML))
            for match in matches {
                let tag = String(pageHTML[Range(match.range, in: pageHTML)!])
                if let name = extractAttr(tag, "name"), let value = extractAttr(tag, "value") {
                    formFields.append((name, value))
                }
            }
        }

        // Detect form action URL (may differ from /auth/login for CAS)
        var postURL = loginPageURL
        let formPattern = #"<form[^>]+action=["\']([^"\']+)["\']"#
        if let formRegex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive),
           let formMatch = formRegex.firstMatch(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)),
           let actionRange = Range(formMatch.range(at: 1), in: pageHTML) {
            let action = String(pageHTML[actionRange])
            if action.hasPrefix("http") {
                postURL = URL(string: action) ?? postURL
            } else if action.hasPrefix("/") {
                postURL = URL(string: "\(baseURL.absoluteString)\(action)") ?? postURL
            }
        }

        // Also try "username" field name (CAS standard) alongside "email" (Edifice standard)
        if pageHTML.contains("name=\"username\"") {
            formFields = formFields.map { ($0.0 == "email" ? "username" : $0.0, $0.1) }
        }

        // Step 2: POST credentials
        let body = formFields.map { "\($0.0)=\($0.1.urlEncoded)" }.joined(separator: "&")
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        entLog("[noto] ENT login POST → \(postURL.absoluteString) fields=\(formFields.map(\.0))")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        let finalURL = http.url?.absoluteString ?? postURL.absoluteString
        entLog("[noto] ENT login response: \(http.statusCode), finalURL=\(finalURL), body prefix: \(String(text.prefix(300)))")

        if http.statusCode == 401 {
            throw ENTError.badCredentials
        }

        // If we landed back on a login form, credentials were wrong
        if text.contains("name=\"password\"") && (text.contains("auth/login") || text.contains("cas/login")) {
            throw ENTError.badCredentials
        }
    }

    /// Extract an HTML attribute value from a tag string
    private func extractAttr(_ tag: String, _ attr: String) -> String? {
        let pattern = "\(attr)=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    // MARK: - Children

    func fetchChildren() async throws -> [ENTChildInfo] {
        let data = try await get("/userbook/api/person")

        let preview = String(data: data.prefix(500), encoding: .utf8) ?? "?"
        entLog("[noto] ENT fetchChildren response: \(preview)")

        let results: [[String: Any]]
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let r = json["result"] as? [[String: Any]] {
            results = r
        } else if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            results = arr
        } else {
            throw ENTError.invalidResponse("Format JSON inattendu pour /userbook/api/person")
        }

        // Each entry has relatedName (child's full name) and relatedId (child's ENT user ID)
        var seen = Set<String>()
        var children: [ENTChildInfo] = []

        for entry in results {
            guard let relatedName = entry["relatedName"] as? String,
                  let relatedId = entry["relatedId"] as? String,
                  !relatedName.isEmpty,
                  !seen.contains(relatedName) else { continue }
            seen.insert(relatedName)

            // Fetch child's class info
            var className = ""
            do {
                let childData = try await get("/userbook/api/person?id=\(relatedId)")
                if let childJson = try JSONSerialization.jsonObject(with: childData) as? [String: Any],
                   let childResults = childJson["result"] as? [[String: Any]],
                   let childEntry = childResults.first,
                   let schools = childEntry["schools"] as? [[String: Any]],
                   let school = schools.first,
                   let classes = school["classes"] as? [String],
                   let firstClass = classes.first {
                    className = firstClass
                }
            } catch {
                entLog("[noto] ENT failed to fetch class for \(relatedName): \(error)")
            }

            entLog("[noto] ENT child: \(relatedName) (id=\(relatedId), class=\(className))")
            children.append(ENTChildInfo(id: relatedId, displayName: relatedName, className: className))
        }

        return children
    }

    // MARK: - Conversation

    func fetchConversations(page: Int = 0, pageSize: Int = 20) async throws -> [ENTConversation] {
        let data = try await get("/conversation/list/INBOX?page=\(page)&pageSize=\(pageSize)")

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { parseConversation($0) }
    }

    func fetchMessage(id: String) async throws -> ENTConversation? {
        let data = try await get("/conversation/message/\(id)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseConversation(json)
    }

    // MARK: - Blog

    func fetchBlogPosts() async throws -> [ENTBlogPost] {
        let data = try await get("/blog/list/all")

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { json in
            guard let id = json["_id"] as? String ?? json["id"] as? String else { return nil }
            return ENTBlogPost(
                id: id,
                title: json["title"] as? String ?? "",
                modified: parseMongoDate(json["modified"]) ?? .now,
                thumbnail: json["thumbnail"] as? String
            )
        }
    }

    // MARK: - Timeline

    func fetchTimeline() async throws -> [ENTTimelineNotification] {
        let data = try await get("/timeline/lastNotifications")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { notif in
            guard let id = notif["_id"] as? String else { return nil }

            let params = notif["params"] as? [String: Any]
            var wordId: String?
            if let uri = params?["resourceUri"] as? String,
               let range = uri.range(of: "/word/") {
                wordId = String(uri[range.upperBound...])
            }

            return ENTTimelineNotification(
                id: id,
                type: notif["type"] as? String ?? notif["event-type"] as? String ?? "",
                message: stripHTML(notif["message"] as? String ?? ""),
                date: parseMongoDate(notif["date"]) ?? .now,
                senderName: params?["username"] as? String,
                wordId: wordId
            )
        }
    }

    // MARK: - Schoolbook

    func fetchSchoolbook(childId: String) async throws -> [ENTSchoolbookWord] {
        // Try with child ID first, then fallback
        let paths = [
            "/schoolbook/list/0/\(childId)",
            "/schoolbook/list/0",
            "/schoolbook/list",
        ]

        for path in paths {
            if let words = try? await fetchSchoolbookAt(path: path), !words.isEmpty {
                return words
            }
        }
        return []
    }

    func fetchSchoolbookWord(id: String) async throws -> ENTSchoolbookWord? {
        let data = try await get("/schoolbook/word/\(id)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseSchoolbookWord(json)
    }

    // MARK: - Homework

    func fetchHomework() async throws -> [ENTHomework] {
        let data = try await get("/homeworks/list")

        let parsed: [[String: Any]]
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            parsed = results
        } else if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            parsed = array
        } else {
            return []
        }

        return parsed.compactMap { json in
            guard let id = json["id"] as? String ?? json["_id"] as? String else { return nil }

            let subject: String
            if let subjectDict = json["subject"] as? [String: Any] {
                subject = subjectDict["label"] as? String ?? "?"
            } else {
                subject = json["subject"] as? String ?? "?"
            }

            return ENTHomework(
                id: id,
                subject: subject,
                description: stripHTML(json["description"] as? String ?? ""),
                dueDate: parseMongoDate(json["dueDate"] ?? json["due_date"] ?? json["date"]) ?? .now
            )
        }
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: "\(baseURL.absoluteString)\(path)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        entLog("[noto] ENT GET \(url.absoluteString)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        entLog("[noto] ENT GET \(path) → \(http.statusCode), \(data.count) bytes, type=\(contentType)")

        if http.statusCode == 401 {
            throw ENTError.sessionExpired
        }

        // Any HTML response means the API didn't return JSON (session issue or wrong endpoint)
        if contentType.contains("text/html") {
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            entLog("[noto] ENT GET \(path) returned HTML: \(text)")
            throw ENTError.sessionExpired
        }

        return data
    }

    private func fetchSchoolbookAt(path: String) async throws -> [ENTSchoolbookWord] {
        let data = try await get(path)

        let items: [[String: Any]]
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            items = results
        } else if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        return items.compactMap { parseSchoolbookWord($0) }
    }

    // MARK: - Parsers

    private func parseConversation(_ json: [String: Any]) -> ENTConversation? {
        guard let id = json["id"] as? String else { return nil }

        let displayNames = json["displayNames"] as? [[String: Any]] ?? []
        let from = displayNames.first?["name"] as? String
            ?? json["from"] as? String ?? ""

        let groupNames = displayNames
            .filter { $0["isGroup"] as? Bool == true }
            .compactMap { $0["name"] as? String }

        return ENTConversation(
            id: id,
            subject: json["subject"] as? String ?? "",
            from: from,
            date: parseISO(json["date"] as? String) ?? .now,
            body: json["body"] as? String,
            unread: json["unread"] as? Bool ?? false,
            groupNames: groupNames
        )
    }

    private func parseSchoolbookWord(_ json: [String: Any]) -> ENTSchoolbookWord? {
        guard let id = json["id"] as? String ?? json["_id"] as? String else { return nil }

        let ownerName: String
        if let owner = json["owner"] as? [String: Any] {
            ownerName = owner["displayName"] as? String ?? ""
        } else {
            ownerName = json["ownerName"] as? String ?? json["sender"] as? String ?? ""
        }

        return ENTSchoolbookWord(
            id: id,
            title: json["title"] as? String ?? json["subject"] as? String ?? "",
            text: stripHTML(json["text"] as? String ?? ""),
            date: parseMongoDate(json["modified"] ?? json["created"]) ?? .now,
            ownerName: ownerName,
            acknowledged: json["ack"] as? Bool ?? false
        )
    }

    // MARK: - Date Parsing

    private func parseMongoDate(_ value: Any?) -> Date? {
        if let dict = value as? [String: Any], let dateStr = dict["$date"] as? String {
            return parseISO(dateStr)
        }
        if let str = value as? String {
            return parseISO(str)
        }
        return nil
    }

    private func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - URL Encoding

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
