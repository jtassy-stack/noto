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
    /// Shared cookie storage for ENT sessions.
    /// HTTPCookieStorage() custom init silently drops setCookie calls — must use .shared.
    /// Session cookies (oneSessionId etc.) are short-lived tokens, not credentials.
    static let cookieStorage: HTTPCookieStorage = .shared

    init(provider: ENTProvider = .pcn) {
        self.baseURL = provider.baseURL
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
    }

    /// Import cookies from WKWebView into our session cookie storage
    static func importCookies(_ cookies: [HTTPCookie]) {
        entLog("[noto] ENTClient.importCookies: \(cookies.map { "\($0.name)@\($0.domain)" })")
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
        let stored = cookieStorage.cookies ?? []
        entLog("[noto] ENTClient.cookieStorage after import: \(stored.map { "\($0.name)@\($0.domain)" })")
    }

    // MARK: - Auth

    func login(email login: String, password: String) async throws {
        let loginPageURL = URL(string: "\(baseURL.absoluteString)/auth/login")!

        // Step 1: GET login page — establishes initial session cookie
        var getRequest = URLRequest(url: loginPageURL)
        getRequest.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        getRequest.setValue(loginPageURL.absoluteString, forHTTPHeaderField: "Referer")
        let (_, _) = try await session.data(for: getRequest)
        let cookiesAfterGet = ENTClient.cookieStorage.cookies(for: loginPageURL) ?? []
        entLog("[noto] ENT cookies after GET: \(cookiesAfterGet.map { $0.name })")

        // Step 2: POST credentials — mimic browser behavior with Origin/Referer headers
        // Edifice/ENTCore expects these for CSRF validation
        let body = "email=\(login.formEncoded)&password=\(password.formEncoded)"
        var request = URLRequest(url: loginPageURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(loginPageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = body.data(using: .utf8)

        entLog("[noto] ENT login POST → \(loginPageURL.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }

        let finalURL = http.url?.absoluteString ?? loginPageURL.absoluteString
        entLog("[noto] ENT login → \(http.statusCode) finalURL=\(finalURL)")

        if http.statusCode == 401 { throw ENTError.badCredentials }

        // If we landed back on a login form, credentials were rejected
        let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
        if finalURL.contains("/auth/login") && text.contains("name=\"password\"") {
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

    /// Fetch blogs accessible to parents via the timeline.
    /// /blog/list returns 401 for parent accounts — the timeline gives us blog IDs directly.
    func fetchBlogPosts() async throws -> [ENTBlogPost] {
        let data = try await get("/timeline/lastNotifications")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        // Extract unique blog IDs from BLOG-type notifications
        var seen = Set<String>()
        let blogs: [ENTBlogPost] = results.compactMap { notif in
            guard (notif["type"] as? String) == "BLOG",
                  let blogId = notif["resource"] as? String,
                  seen.insert(blogId).inserted else { return nil }
            let params = notif["params"] as? [String: Any]
            let title = params?["blogTitle"] as? String ?? ""
            let date = parseMongoDate(notif["date"]) ?? .now
            return ENTBlogPost(id: blogId, title: title, modified: date, thumbnail: nil)
        }
        NSLog("[noto] fetchBlogPosts via timeline: %d unique blogs", blogs.count)
        return blogs
    }

    /// Fetch all posts for a blog and extract photo workspace paths from their HTML content.
    /// Uses /blog/post/list/all/<blogId> — the correct parent-accessible endpoint (confirmed via React bundle analysis).
    func fetchBlogPhotoAttachments(blogId: String) async throws -> [ENTPhotoAttachment] {
        let data = try await get("/blog/post/list/all/\(blogId)?page=0&content=true&comments=false&nbComments=true")

        let posts: [[String: Any]]
        let root2 = try JSONSerialization.jsonObject(with: data)
        if let arr = root2 as? [[String: Any]] {
            posts = arr
        } else if let json = root2 as? [String: Any], let p = json["rows"] as? [[String: Any]] {
            posts = p
        } else if let json = root2 as? [String: Any], let p = json["posts"] as? [[String: Any]] {
            posts = p
        } else {
            NSLog("[noto] fetchBlogPhotoAttachments %@: unexpected format — %@", blogId, String(data: data.prefix(200), encoding: .utf8) ?? "")
            return []
        }
        NSLog("[noto] blog %@ → %d posts", blogId, posts.count)

        var attachments: [ENTPhotoAttachment] = []
        for post in posts {
            let postId = post["_id"] as? String ?? post["id"] as? String ?? ""
            let title = post["title"] as? String ?? ""
            let date = parseMongoDate(post["firstPublishDate"] ?? post["modified"]) ?? .now
            let authorName: String?
            if let author = post["author"] as? [String: Any] {
                authorName = author["username"] as? String
            } else {
                authorName = post["author"] as? String
            }
            let content = post["content"] as? String ?? ""
            let paths = extractWorkspacePaths(from: content)
            // Also include thumbnail if present
            var allPaths = paths
            if let thumb = post["thumbnail"] as? String, !thumb.isEmpty {
                let thumbPath = thumb.hasPrefix("/") ? thumb : "/workspace/document/\(thumb)"
                if !allPaths.contains(thumbPath) { allPaths.insert(thumbPath, at: 0) }
            }
            for path in allPaths {
                attachments.append(ENTPhotoAttachment(
                    path: path,
                    title: title,
                    authorName: authorName,
                    date: date,
                    source: .blog
                ))
            }
        }
        return attachments
    }

    /// Fetch photos embedded in Actualités posts (parent-accessible on PCN).
    /// Extracts workspace image src paths from the HTML content of each news item.
    func fetchActualitesPhotos() async throws -> [ENTPhotoAttachment] {
        let data = try await get("/actualites/list?filter=all&page=0&limit=100")

        let items: [[String: Any]]
        let root = try JSONSerialization.jsonObject(with: data)
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let obj = root as? [String: Any], let rows = obj["rows"] as? [[String: Any]] {
            items = rows
        } else {
            NSLog("[noto] fetchActualitesPhotos: unexpected format — %@", String(data: data.prefix(200), encoding: .utf8) ?? "")
            return []
        }
        NSLog("[noto] fetchActualitesPhotos: %d items", items.count)

        var photos: [ENTPhotoAttachment] = []
        for item in items {
            let title = item["title"] as? String ?? ""
            let content = item["content"] as? String ?? item["text"] as? String ?? ""
            let date = parseMongoDate(item["modified"] ?? item["publicationDate"] ?? item["created"]) ?? .now
            let ownerName: String?
            if let owner = item["owner"] as? [String: Any] {
                ownerName = owner["displayName"] as? String
            } else {
                ownerName = nil
            }
            for path in extractWorkspacePaths(from: content) {
                photos.append(ENTPhotoAttachment(path: path, title: title, authorName: ownerName, date: date, source: .blog))
            }
        }
        NSLog("[noto] fetchActualitesPhotos: %d photos extracted", photos.count)
        return photos
    }

    /// Fetch schoolbook word detail and extract photo attachment paths.
    func fetchSchoolbookPhotoAttachments(wordId: String, wordTitle: String, wordDate: Date, authorName: String) async throws -> [ENTPhotoAttachment] {
        let rawData = try await get("/schoolbook/word/\(wordId)")
        guard let json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else { return [] }

        // Parse word content from the single response
        let text = json["text"] as? String ?? ""

        // Extract images from HTML body
        let htmlPaths = extractWorkspacePaths(from: text)
        var attachments: [ENTPhotoAttachment] = htmlPaths.map { path in
            return ENTPhotoAttachment(
                path: path,
                title: wordTitle,
                authorName: authorName,
                date: wordDate,
                source: .schoolbook
            )
        }

        // Also include image attachments from the `attachments` array in the same response
        if let rawAttachments = json["attachments"] as? [[String: Any]] {
            for att in rawAttachments {
                let attId = att["id"] as? String ?? att["_id"] as? String ?? ""
                let mime = att["contentType"] as? String ?? att["mime"] as? String ?? ""
                guard mime.hasPrefix("image/"), !attId.isEmpty else { continue }
                let path = "/workspace/document/\(attId)"
                let attName = att["filename"] as? String ?? att["name"] as? String
                if !attachments.contains(where: { $0.path == path }) {
                    attachments.append(ENTPhotoAttachment(
                        path: path,
                        title: attName ?? wordTitle,
                        authorName: authorName,
                        date: wordDate,
                        source: .schoolbook
                    ))
                }
            }
        }

        return attachments
    }

    /// Extract /workspace/document/<id> paths from HTML string.
    private func extractWorkspacePaths(from html: String) -> [String] {
        // Match src="/workspace/document/<id>" or src="https://host/workspace/document/<id>"
        let pattern = #"src=[\"']((?:https?://[^\"']*)?/workspace/document/[a-zA-Z0-9\-_]+)[\"']"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            NSLog("[noto] extractWorkspacePaths: regex compilation failed: %@", error.localizedDescription)
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        var seen = Set<String>()
        return matches.compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            let full = String(html[r])
            // Normalize to relative path
            let path: String
            if let url = URL(string: full), let relPath = url.path.isEmpty ? nil : url.path {
                path = relPath.hasPrefix("/workspace") ? relPath : full
            } else {
                path = full
            }
            guard seen.insert(path).inserted else { return nil }
            return path
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
            do {
                let words = try await fetchSchoolbookAt(path: path)
                if !words.isEmpty { return words }
            } catch ENTError.sessionExpired {
                throw ENTError.sessionExpired
            } catch {
                entLog("[noto] fetchSchoolbook path \(path) failed: \(error.localizedDescription)")
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

    // MARK: - Schoolbook Acknowledgment

    func acknowledgeSchoolbookWord(id: String) async throws {
        let tryPUT = await performAck(method: "PUT", id: id)
        if tryPUT { return }
        // Fallback to POST
        let tryPOST = await performAck(method: "POST", id: id)
        if !tryPOST {
            throw ENTError.invalidResponse("Impossible d'acquitter le mot \(id)")
        }
    }

    private func performAck(method: String, id: String) async -> Bool {
        let url = URL(string: "\(baseURL.absoluteString)/schoolbook/word/\(id)/ack")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        entLog("[noto] ENT \(method) /schoolbook/word/\(id)/ack")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        entLog("[noto] ENT ack response: \(http.statusCode)")
        return (200...299).contains(http.statusCode)
    }

    /// Authenticated data fetch for workspace documents (images, attachments).
    /// Uses URLSession.shared so all image requests share a single HTTP/2 connection
    /// instead of opening a new TCP+TLS connection per photo thumbnail.
    func fetchData(path: String) async throws -> Data {
        let urlString: String
        if path.hasPrefix("http") {
            urlString = path
        } else {
            urlString = "\(baseURL.absoluteString)\(path)"
        }
        guard let url = URL(string: urlString) else {
            throw ENTError.invalidResponse("URL invalide: \(path)")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        entLog("[noto] ENT fetchData \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }
        if http.statusCode == 401 { throw ENTError.sessionExpired }
        return data
    }

    /// HEAD request to fetch Content-Disposition filename for a workspace document.
    func fetchFilename(path: String) async -> String? {
        let urlString = path.hasPrefix("http") ? path : "\(baseURL.absoluteString)\(path)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        // Content-Disposition: attachment; filename="document.pdf"
        let parts = disposition.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                let name = trimmed.dropFirst("filename=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: "\(baseURL.absoluteString)\(path)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let sentCookies = ENTClient.cookieStorage.cookies(for: url) ?? []
        entLog("[noto] ENT GET \(url.absoluteString) cookies=\(sentCookies.map(\.name))")
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

        // displayNames is an array of [id, name, isGroup] tuples (JSON arrays)
        // e.g. [["abc123", "M. Dupont", false], ["grp456", "CM2 A", true]]
        let displayNames = json["displayNames"] as? [[Any]] ?? []
        let fromEntry = displayNames.first { ($0[safe: 2] as? Bool) == false }
        let from = fromEntry?[safe: 1] as? String
            ?? json["from"] as? String ?? ""
        let groupNames = displayNames
            .filter { ($0[safe: 2] as? Bool) == true }
            .compactMap { $0[safe: 1] as? String }

        // date is a millisecond timestamp (Int or Double), not an ISO string
        let date: Date
        if let ms = json["date"] as? Double {
            date = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = json["date"] as? Int {
            date = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            date = parseISO(json["date"] as? String) ?? .now
        }

        return ENTConversation(
            id: id,
            subject: json["subject"] as? String ?? "",
            from: from,
            date: date,
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
            text: json["text"] as? String ?? "",
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
    /// encodeURIComponent-equivalent: encodes everything except A-Z a-z 0-9 - _ . ! ~ * ' ( )
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
