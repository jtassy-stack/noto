import Foundation

@inline(__always)
private func edLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

/// REST client for the École Directe API (https://api.ecoledirecte.com/v3/).
/// All "read" operations use POST with `data={}` body and `X-Token` header.
/// Token is short-lived (~30 min idle); credentials are stored in Keychain for silent re-auth.
actor EcoleDirecteClient {
    static let baseURL = URL(string: "https://api.ecoledirecte.com/v3")!

    private var token: String?
    private let session: URLSession

    // Credential key pattern: "ed_credentials_<accountId>"
    let accountId: String

    init(accountId: String) {
        self.accountId = accountId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    /// Authenticate and store the token. Credentials are saved to Keychain for future re-auth.
    func login(username: String, password: String) async throws -> EDLoginResponse {
        let body = "data=" + ("""
        {"identifiant":"\(username.edEscaped)","motdepasse":"\(password.edEscaped)","isReLogin":false,"uuid":""}
        """).trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!

        let (data, _) = try await post(path: "/login.awp", body: body, token: nil)
        let response = try parseLoginResponse(data)

        token = response.token
        // Store credentials for silent re-auth
        let creds = "\(username):\(password)"
        try? KeychainService.save(key: "ed_credentials_\(accountId)", data: Data(creds.utf8))
        edLog("[noto] ED login OK — token acquired, \(response.accounts.count) account(s)")
        return response
    }

    // MARK: - Token management
    //
    // TODO: Implémente la stratégie de renouvellement de token (5-10 lignes).
    //
    // Cette fonction est appelée avant chaque requête API.
    // Le token ED expire après ~30 min d'inactivité (l'API répond code:520).
    //
    // Options à considérer :
    //   A. Si `token == nil`, tenter un re-login silencieux via les credentials Keychain.
    //      Si pas de credentials → throw .tokenExpired (l'UI affiche "reconnectez-vous").
    //   B. Ne rien faire ici — laisser les appelants gérer l'erreur .tokenExpired
    //      en catchant et en relançant via `login(username:password:)`.
    //   C. Hybrid : re-login silencieux si credentials présents, throw si absents.
    //
    // Impact UX :
    //   - Option A (silencieux) : le parent ne voit jamais d'erreur de session → meilleur UX
    //   - Option B (explicite) : plus simple, mais le parent retape son MDP souvent
    //   - Option C : compromis recommandé
    //
    // Contrainte privacy : ne pas logger les credentials, même en DEBUG.
    //
    func ensureValidToken() async throws {
        guard token == nil else { return }
        // Token absent — attempt silent re-auth from stored Keychain credentials
        guard let credsData = try? KeychainService.load(key: "ed_credentials_\(accountId)"),
              let creds = String(data: credsData, encoding: .utf8) else {
            throw EcoleDirecteError.tokenExpired
        }
        let parts = creds.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { throw EcoleDirecteError.tokenExpired }
        let response = try await login(username: String(parts[0]), password: String(parts[1]))
        token = response.token
        edLog("[noto] ED silent re-auth OK for account \(accountId)")
    }

    // MARK: - Fetch endpoints

    func fetchGrades(eleveId: Int) async throws -> [EDGrade] {
        try await ensureValidToken()
        let (data, _) = try await post(path: "/eleves/\(eleveId)/notes.awp?verbe=get&", body: "data={}", token: token)
        return try parseGrades(data)
    }

    func fetchSchedule(eleveId: Int, from: Date, to: Date) async throws -> [EDLesson] {
        try await ensureValidToken()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateDebut = fmt.string(from: from)
        let dateFin = fmt.string(from: to)
        let (data, _) = try await post(
            path: "/E/\(eleveId)/emploidutemps.awp?verbe=get&dateDebut=\(dateDebut)&dateFin=\(dateFin)&",
            body: "data={}",
            token: token
        )
        return try parseSchedule(data)
    }

    func fetchHomework(eleveId: Int) async throws -> [EDHomework] {
        try await ensureValidToken()
        let (data, _) = try await post(path: "/Eleves/\(eleveId)/cahierdetextes.awp?verbe=get&", body: "data={}", token: token)
        return try parseHomework(data)
    }

    func fetchMessages(familleId: Int) async throws -> [EDMessage] {
        try await ensureValidToken()
        let (data, _) = try await post(path: "/familles/\(familleId)/messages.awp?verbe=get&", body: "data={}", token: token)
        return try parseMessages(data)
    }

    // MARK: - HTTP

    private func post(path: String, body: String, token: String?) async throws -> (Data, HTTPURLResponse) {
        let url = Self.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // ED API expects these headers to avoid bot detection
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.ecoledirecte.com", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Token") }
        request.httpBody = body.data(using: .utf8)

        edLog("[noto] ED POST \(url.path)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EcoleDirecteError.invalidResponse("Not HTTP")
        }
        edLog("[noto] ED POST \(url.path) → \(http.statusCode) \(data.count)B")

        // Parse top-level code even on HTTP 200 — ED always returns 200 but uses a `code` field
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? Int {
            switch code {
            case 520: throw EcoleDirecteError.tokenExpired
            case 521: throw EcoleDirecteError.accountBlocked
            case 505: throw EcoleDirecteError.badCredentials
            default: break
            }
        }

        return (data, http)
    }

    // MARK: - Response parsers

    private func parseLoginResponse(_ data: Data) throws -> EDLoginResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String,
              let rawData = root["data"] as? [String: Any],
              let rawAccounts = rawData["accounts"] as? [[String: Any]] else {
            throw EcoleDirecteError.invalidResponse("login: format inattendu")
        }

        let accounts: [EDAccount] = rawAccounts.compactMap { acc in
            guard let id = acc["id"] as? Int,
                  let profile = acc["profile"] as? [String: Any] else { return nil }
            let nom = profile["nom"] as? String ?? ""
            let prenom = profile["prenom"] as? String ?? ""
            let displayName = "\(nom) \(prenom)".trimmingCharacters(in: .whitespaces)
            let rawEleves = profile["eleves"] as? [[String: Any]] ?? []
            let eleves: [EDEleve] = rawEleves.compactMap { el in
                guard let eleveId = el["id"] as? Int else { return nil }
                let classe = el["classe"] as? [String: Any]
                return EDEleve(
                    id: eleveId,
                    firstName: el["prenom"] as? String ?? "",
                    lastName: el["nom"] as? String ?? "",
                    grade: classe?["libelle"] as? String ?? "",
                    establishmentName: el["nomEtablissement"] as? String ?? "École Directe"
                )
            }
            return EDAccount(id: id, displayName: displayName, eleves: eleves)
        }

        return EDLoginResponse(token: token, accounts: accounts)
    }

    private func parseGrades(_ data: Data) throws -> [EDGrade] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edData = root["data"] as? [String: Any],
              let periodes = edData["periodes"] as? [[String: Any]] else { return [] }

        var grades: [EDGrade] = []
        for periode in periodes {
            let notes = periode["notes"] as? [[String: Any]] ?? []
            for note in notes {
                guard let id = note["id"].map({ "\($0)" }) else { continue }
                let outOf = (note["noteSur"] as? String).flatMap(Double.init) ?? 20
                let coeff = (note["coefficient"] as? String).flatMap(Double.init) ?? 1
                let avg = (note["moyenneClasse"] as? String).flatMap(Double.init)
                grades.append(EDGrade(
                    id: id,
                    date: edParseDate(note["date"] as? String ?? "") ?? .now,
                    subject: note["libelleMatiere"] as? String ?? "?",
                    rawValue: note["valeur"] as? String ?? "",
                    outOf: outOf,
                    coefficient: coeff,
                    classAverage: avg
                ))
            }
        }
        edLog("[noto] ED parsed \(grades.count) grades")
        return grades
    }

    private func parseSchedule(_ data: Data) throws -> [EDLesson] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lessons = root["data"] as? [[String: Any]] else { return [] }

        return lessons.compactMap { l in
            guard let id = l["idDuCours"].map({ "\($0)" }) else { return nil }
            let dateStr = l["date"] as? String ?? ""
            let start = l["hDebut"] as? String ?? ""
            let end = l["hFin"] as? String ?? ""
            let dateTime = edParseDate("\(dateStr) \(start)") ?? edParseDate(dateStr) ?? .now
            return EDLesson(
                id: id,
                date: dateTime,
                startTime: String(start.prefix(5)),
                endTime: String(end.prefix(5)),
                subject: l["matiere"] as? String ?? "?",
                room: l["salle"] as? String,
                teacher: (l["professeurs"] as? [[String: Any]])?.first?["nom"] as? String,
                cancelled: l["isAnnule"] as? Bool ?? false
            )
        }
    }

    private func parseHomework(_ data: Data) throws -> [EDHomework] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edData = root["data"] as? [String: Any],
              let dates = edData["dates"] as? [String: Any] else { return [] }

        var homework: [EDHomework] = []
        for (dateStr, dayData) in dates {
            guard let day = dayData as? [String: Any],
                  let matieres = day["matieres"] as? [[String: Any]] else { continue }
            let dueDate = edParseDate(dateStr) ?? .now
            for matiere in matieres {
                guard let aFaire = matiere["aFaire"] as? [String: Any],
                      let contenu = aFaire["contenu"] as? String, !contenu.isEmpty else { continue }
                let id = aFaire["id"].map({ "\($0)" }) ?? "\(dateStr)-\(matiere["codeMatiere"] as? String ?? "?")"
                homework.append(EDHomework(
                    id: id,
                    subject: matiere["libelle"] as? String ?? "?",
                    description: edStripHTML(contenu),
                    dueDate: dueDate
                ))
            }
        }
        return homework
    }

    private func parseMessages(_ data: Data) throws -> [EDMessage] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edData = root["data"] as? [String: Any],
              let messagesObj = edData["messages"] as? [String: Any],
              let received = messagesObj["received"] as? [[String: Any]] else { return [] }

        return received.compactMap { m in
            guard let id = m["id"] as? Int else { return nil }
            let from = (m["from"] as? [String: Any])?["name"] as? String ?? ""
            let bodyRaw = m["content"] as? String ?? ""
            // ED encodes message bodies in base64
            let bodyDecoded: String
            if let decoded = Data(base64Encoded: bodyRaw, options: .ignoreUnknownCharacters),
               let str = String(data: decoded, encoding: .utf8) {
                bodyDecoded = edStripHTML(str)
            } else {
                bodyDecoded = edStripHTML(bodyRaw)
            }
            return EDMessage(
                id: id,
                from: from,
                subject: m["subject"] as? String ?? "",
                date: edParseDate(m["date"] as? String ?? "") ?? .now,
                body: bodyDecoded,
                read: m["read"] as? Bool ?? false
            )
        }
    }
}

// MARK: - String helpers

private extension String {
    var edEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
