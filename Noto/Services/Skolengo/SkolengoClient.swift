import Foundation

@inline(__always)
private func skoLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

/// REST client for Skolengo's EMS v2 API (https://api.skolengo.com/api/v1/bff-sko-app),
/// the platform behind Occitanie, Auvergne-Rhône-Alpes, Bourgogne-Franche-Comté,
/// Grand Est, Corse, Savoie, Haute-Savoie, Loire, and Isère's school ENTs.
///
/// Auth is a real OIDC authorization-code flow (not a plain form POST like École
/// Directe): each school exposes its own `emsOIDCWellKnownUrl` for OIDC discovery,
/// and the official Skolengo mobile app's own OAuth client identity is reused —
/// the same "impersonate the official app" reverse-engineering technique already
/// used for Pronote (pawnote) and École Directe, applied to OAuth instead of a form.
/// Client id/secret below are base64-encoded exactly as the reference client
/// (`maelgangloff/scolengo-api`) stores them — not a secret worth protecting,
/// just avoiding a bare plaintext OAuth client secret sitting in the diff.
/// Session is per-school: the API requires `X-Skolengo-School-Id`/`X-Skolengo-Ems-Code`
/// headers on every authenticated call, so one `SkolengoClient` instance == one school.
actor SkolengoClient {
    static let baseURL = URL(string: "https://api.skolengo.com/api/v1/bff-sko-app")!
    static let redirectURI = "skoapp-prod://sign-in-callback"

    private static let clientID = Data(base64Encoded: "U2tvQXBwLlByb2QuMGQzNDkyMTctOWE0ZS00MWVjLTlhZjktZGY5ZTY5ZTA5NDk0")
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    private static let clientSecret = Data(base64Encoded: "N2NiNGQ5YTgtMjU4MC00MDQxLTlhZTgtZDU4MDM4NjkxODNm")
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""

    let school: SkolengoSchool
    private var tokenSet: SkolengoTokenSet?
    private let session: URLSession

    // Credential key pattern: "skolengo_credentials_<schoolId>"
    private var credentialsKey: String { "skolengo_credentials_\(school.id)" }

    init(school: SkolengoSchool) {
        self.school = school
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - School search (unauthenticated)

    /// `GET /schools?filter[text]=...` — no auth required, used for the
    /// pre-login school picker. Confirmed against scolengo-api source:
    /// no Authorization header is sent for this endpoint.
    static func searchSchools(text: String) async throws -> [SkolengoSchool] {
        var components = URLComponents(url: baseURL.appendingPathComponent("schools"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter[text]", value: text),
            URLQueryItem(name: "page[limit]", value: "10"),
        ]
        guard let url = components.url else {
            throw SkolengoError.invalidResponse("URL de recherche invalide")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        skoLog("[noto] Skolengo GET \(url.path)?\(url.query ?? "")")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SkolengoError.invalidResponse("recherche établissement: statut inattendu")
        }
        let resources = try SkolengoJSONAPI.resources(from: data)
        return resources.compactMap { attrs in
            guard let id = attrs["id"] as? String,
                  let name = attrs["name"] as? String,
                  let wellKnownUrl = attrs["emsOIDCWellKnownUrl"] as? String else { return nil }
            return SkolengoSchool(
                id: id,
                name: name,
                city: attrs["city"] as? String,
                emsCode: attrs["emsCode"] as? String,
                emsOIDCWellKnownUrl: wellKnownUrl
            )
        }
    }

    // MARK: - OIDC login

    /// Fetches the school's OIDC discovery document and builds the
    /// authorization URL to present in an `ASWebAuthenticationSession`
    /// (callbackURLScheme: "skoapp-prod"). No PKCE — confirmed absent
    /// from the reference client's auth flow.
    func buildAuthorizationURL() async throws -> URL {
        let (authEndpoint, _) = try await discoverEndpoints()
        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid"),
        ]
        guard let url = components?.url else {
            throw SkolengoError.invalidResponse("URL d'autorisation invalide")
        }
        return url
    }

    /// Exchanges the `?code=...` captured from the ASWebAuthenticationSession
    /// callback for a token set, and resolves the logged-in user's id from
    /// the ID token's `sub` claim (no extra round trip needed for that part).
    /// Returns the resolved user id.
    @discardableResult
    func completeLogin(callbackURL: URL) async throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            if callbackURL.query?.contains("error") == true {
                throw SkolengoError.authCancelled
            }
            throw SkolengoError.invalidResponse("code d'autorisation manquant")
        }

        let (_, tokenEndpoint) = try await discoverEndpoints()
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
        ]
        let data = try await tokenRequest(endpoint: tokenEndpoint, body: body)
        let newTokenSet = try parseTokenResponse(data, tokenEndpoint: tokenEndpoint)
        self.tokenSet = newTokenSet
        storeCredentials(newTokenSet)

        guard let idToken = newTokenSet.idToken, let sub = skoDecodeIDTokenSub(idToken) else {
            throw SkolengoError.invalidResponse("identifiant utilisateur introuvable dans le jeton")
        }
        skoLog("[noto] Skolengo login OK for school \(school.id)")
        return sub
    }

    /// Saves the current token set to Keychain, best-effort (ED pattern —
    /// non-fatal on failure, logged rather than thrown).
    private func storeCredentials(_ tokenSet: SkolengoTokenSet) {
        do {
            let data = try JSONEncoder().encode(tokenSet)
            try KeychainService.save(key: credentialsKey, data: data)
        } catch {
            NSLog("[noto][error] Skolengo Keychain save failed for school %@: %@", school.id, error.localizedDescription)
        }
    }

    /// Loads a valid token from Keychain, refreshing it if expired.
    /// Throws `.tokenExpired` if nothing is stored (parent must re-login).
    func ensureValidToken() async throws {
        if tokenSet != nil { return }
        guard let data = try? KeychainService.load(key: credentialsKey),
              let stored = try? JSONDecoder().decode(SkolengoTokenSet.self, from: data) else {
            throw SkolengoError.tokenExpired
        }
        tokenSet = stored
    }

    /// Refreshes the access token via the OAuth refresh-token grant
    /// (confirmed present in scolengo-api — not an École-Directe-style
    /// full re-login).
    private func refreshToken() async throws {
        guard let current = tokenSet, let refreshToken = current.refreshToken else {
            self.tokenSet = nil
            throw SkolengoError.tokenExpired
        }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
        ]
        let data = try await tokenRequest(endpoint: current.tokenEndpoint, body: body)
        let refreshed = try parseTokenResponse(data, tokenEndpoint: current.tokenEndpoint, fallbackRefreshToken: refreshToken)
        self.tokenSet = refreshed
        storeCredentials(refreshed)
        skoLog("[noto] Skolengo token refreshed for school \(school.id)")
    }

    // MARK: - Linked users

    /// Resolves who the login belongs to: for a parent account, the
    /// linked children ("students" relationship); for a student logging
    /// in directly, themselves. The exact `/users-info/{id}` response
    /// shape (whether a parent/student relationship is even present) is
    /// unconfirmed against a real payload — falls back to treating the
    /// logged-in user as the pupil if no linked students are found,
    /// which is the safe default for the common single-child-login case.
    func fetchLinkedUsers(userId: String) async throws -> [SkolengoUserInfo] {
        let data = try await get(path: "/users-info/\(userId)", queryItems: [])
        let resources = try SkolengoJSONAPI.resources(from: data)
        guard let me = resources.first else {
            throw SkolengoError.invalidResponse("profil utilisateur introuvable")
        }
        if let students = me["students"] as? [[String: Any]], !students.isEmpty {
            return students.compactMap(parseUserInfo)
        }
        return [parseUserInfo(me)].compactMap { $0 }
    }

    private func parseUserInfo(_ attrs: [String: Any]) -> SkolengoUserInfo? {
        guard let id = attrs["id"] as? String else { return nil }
        return SkolengoUserInfo(
            id: id,
            firstName: attrs["firstName"] as? String ?? "",
            lastName: attrs["lastName"] as? String ?? "",
            className: (attrs["className"] as? String) ?? (attrs["classes"] as? [[String: Any]])?.first?["label"] as? String,
            schoolName: school.name
        )
    }

    // MARK: - Fetch endpoints

    func fetchGrades(userId: String) async throws -> [SkolengoGrade] {
        let data = try await get(path: "/evaluation-services", queryItems: [URLQueryItem(name: "filter[student]", value: userId)])
        return try parseGrades(data)
    }

    func fetchSchedule(userId: String, from: Date, to: Date) async throws -> [SkolengoLesson] {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let data = try await get(path: "/agendas", queryItems: [
            URLQueryItem(name: "filter[student]", value: userId),
            URLQueryItem(name: "filter[startDate]", value: fmt.string(from: from)),
            URLQueryItem(name: "filter[endDate]", value: fmt.string(from: to)),
        ])
        return try parseSchedule(data)
    }

    func fetchHomework(userId: String) async throws -> [SkolengoHomework] {
        let data = try await get(path: "/homework-assignments", queryItems: [URLQueryItem(name: "filter[student]", value: userId)])
        return try parseHomework(data)
    }

    func fetchMessages(userId: String) async throws -> [SkolengoMessage] {
        let data = try await get(path: "/communications", queryItems: [URLQueryItem(name: "filter[recipient]", value: userId)])
        return try parseMessages(data)
    }

    // MARK: - HTTP core

    private func discoverEndpoints() async throws -> (authorization: String, token: String) {
        guard let url = URL(string: school.emsOIDCWellKnownUrl) else {
            throw SkolengoError.invalidResponse("emsOIDCWellKnownUrl invalide")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authEndpoint = json["authorization_endpoint"] as? String,
              let tokenEndpoint = json["token_endpoint"] as? String else {
            throw SkolengoError.invalidResponse("document de découverte OIDC invalide")
        }
        return (authEndpoint, tokenEndpoint)
    }

    private func tokenRequest(endpoint: String, body: [String: String]) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw SkolengoError.invalidResponse("token_endpoint invalide")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkolengoError.invalidResponse("Not HTTP")
        }
        // Exact token_endpoint_auth_method (Basic vs body credentials) isn't
        // confirmed against a live discovery doc yet — if this consistently
        // 401s once a real account is available, that's the first thing to check.
        if http.statusCode == 400 || http.statusCode == 401 {
            throw SkolengoError.badCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            throw SkolengoError.invalidResponse("token endpoint: statut \(http.statusCode)")
        }
        return data
    }

    private func parseTokenResponse(_ data: Data, tokenEndpoint: String, fallbackRefreshToken: String? = nil) throws -> SkolengoTokenSet {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw SkolengoError.invalidResponse("token: format inattendu")
        }
        return SkolengoTokenSet(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? fallbackRefreshToken,
            idToken: json["id_token"] as? String,
            tokenEndpoint: tokenEndpoint
        )
    }

    /// Authenticated GET with automatic refresh-then-retry on 401.
    private func get(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        try await ensureValidToken()
        do {
            return try await performGet(path: path, queryItems: queryItems)
        } catch SkolengoError.tokenExpired {
            try await refreshToken()
            return try await performGet(path: path, queryItems: queryItems)
        }
    }

    private func performGet(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let tokenSet else { throw SkolengoError.tokenExpired }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SkolengoError.invalidResponse("URL de requête invalide")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(tokenSet.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("utc", forHTTPHeaderField: "X-Skolengo-Date-Format")
        request.setValue(school.id, forHTTPHeaderField: "X-Skolengo-School-Id")
        if let emsCode = school.emsCode {
            request.setValue(emsCode, forHTTPHeaderField: "X-Skolengo-Ems-Code")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        skoLog("[noto] Skolengo GET \(path)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkolengoError.invalidResponse("Not HTTP")
        }
        skoLog("[noto] Skolengo GET \(path) → \(http.statusCode) \(data.count)B")
        if http.statusCode == 401 {
            self.tokenSet = nil
            throw SkolengoError.tokenExpired
        }
        guard (200...299).contains(http.statusCode) else {
            throw SkolengoError.invalidResponse("Skolengo API: statut \(http.statusCode)")
        }
        return data
    }

    // MARK: - Response parsers
    //
    // Field names below match the confirmed JSON:API `attributes` shapes
    // from scolengo-api's TypeScript models. Per-evaluation score details
    // (EvaluationDetail) and message body content (Participation) were not
    // fully confirmed — kept tolerant (compactMap/??) so a mismatch drops
    // one item rather than failing the whole parse, matching EcoleDirecteClient's style.

    private func parseGrades(_ data: Data) throws -> [SkolengoGrade] {
        let resources = try SkolengoJSONAPI.resources(from: data)
        return resources.compactMap { attrs -> SkolengoGrade? in
            guard let id = attrs["id"] as? String else { return nil }
            let subjectName = (attrs["subject"] as? [String: Any])?["label"] as? String
                ?? (attrs["subject"] as? [String: Any])?["name"] as? String ?? "?"
            let scale = attrs["scale"] as? Double ?? 20
            let value = attrs["studentAverage"] as? Double ?? attrs["average"] as? Double
            let coeff = attrs["coefficient"] as? Double ?? 1
            return SkolengoGrade(
                id: id,
                date: skoParseDate(attrs["date"] as? String) ?? .now,
                subject: subjectName,
                rawValue: value.map { String($0) } ?? "",
                outOf: scale,
                coefficient: coeff,
                classAverage: attrs["classAverage"] as? Double
            )
        }
    }

    private func parseSchedule(_ data: Data) throws -> [SkolengoLesson] {
        let resources = try SkolengoJSONAPI.resources(from: data)
        return resources.compactMap { attrs -> SkolengoLesson? in
            guard let id = attrs["id"] as? String,
                  let start = skoParseDate(attrs["startDateTime"] as? String),
                  let end = skoParseDate(attrs["endDateTime"] as? String) else { return nil }
            let subjectName = (attrs["subject"] as? [String: Any])?["label"] as? String ?? "?"
            let teacherName = (attrs["teachers"] as? [[String: Any]])?.first?["lastName"] as? String
            return SkolengoLesson(
                id: id,
                start: start,
                end: end,
                subject: subjectName,
                room: attrs["location"] as? String,
                teacher: teacherName,
                cancelled: attrs["canceled"] as? Bool ?? false
            )
        }
    }

    private func parseHomework(_ data: Data) throws -> [SkolengoHomework] {
        let resources = try SkolengoJSONAPI.resources(from: data)
        return resources.compactMap { attrs -> SkolengoHomework? in
            guard let id = attrs["id"] as? String,
                  let dueDate = skoParseDate(attrs["dueDateTime"] as? String ?? attrs["dueDate"] as? String) else { return nil }
            let subjectName = (attrs["subject"] as? [String: Any])?["label"] as? String ?? "?"
            let html = attrs["html"] as? String ?? attrs["title"] as? String ?? ""
            return SkolengoHomework(
                id: id,
                subject: subjectName,
                description: skoStripHTML(html),
                dueDate: dueDate,
                done: attrs["done"] as? Bool ?? false
            )
        }
    }

    private func parseMessages(_ data: Data) throws -> [SkolengoMessage] {
        let resources = try SkolengoJSONAPI.resources(from: data)
        return resources.compactMap { attrs -> SkolengoMessage? in
            guard let id = attrs["id"] as? String else { return nil }
            let bodyRaw = attrs["firstParticipationContent"] as? String ?? ""
            return SkolengoMessage(
                id: id,
                from: attrs["recipientsSummary"] as? String ?? "Skolengo",
                subject: attrs["subject"] as? String ?? "",
                date: skoParseDate(attrs["date"] as? String) ?? .now,
                body: skoStripHTML(bodyRaw),
                read: attrs["read"] as? Bool ?? false
            )
        }
    }
}
