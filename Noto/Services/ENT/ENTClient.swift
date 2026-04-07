import Foundation

/// Client for ENT/PCN (Paris Classe Numérique) REST API.
/// Session managed via cookie jar — credentials stay on-device.
final class ENTClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    /// Session cache: re-login after 10 minutes
    private let sessionTimeout: TimeInterval = 600

    init(baseURL: URL = URL(string: "https://ent.parisclassenumerique.fr")!) {
        self.baseURL = baseURL
        // Ephemeral session with cookie storage (no disk persistence)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws {
        let url = baseURL.appendingPathComponent("/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "email=\(email.urlEncoded)&password=\(password.urlEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }

        // PCN returns 200 on success, 401 on bad credentials
        // Also check for HTML response (indicates redirect/session issue)
        if http.statusCode == 401 {
            throw ENTError.badCredentials
        }

        if let text = String(data: data, encoding: .utf8), text.contains("<html") {
            throw ENTError.badCredentials
        }
    }

    // MARK: - Children

    func fetchChildren() async throws -> [ENTChildInfo] {
        let data = try await get("/userbook/api/person")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["result"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { person in
            guard let id = person["id"] as? String,
                  let displayName = person["displayName"] as? String else { return nil }
            let className = person["classes"] as? String ?? ""
            return ENTChildInfo(id: id, displayName: displayName, className: className)
        }
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
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }

        if http.statusCode == 401 {
            throw ENTError.sessionExpired
        }

        // HTML response means session expired (redirect to login page)
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("<!DOCTYPE") || text.hasPrefix("<html") {
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
