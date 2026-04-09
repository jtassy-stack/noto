import Foundation

// MARK: - Supporting Types

enum AbsenceMotif: String, CaseIterable, Sendable {
    case maladie
    case rdvMedical
    case raisonFamiliale
    case autre

    var label: String {
        switch self {
        case .maladie:          return "Maladie"
        case .rdvMedical:       return "Rendez-vous médical"
        case .raisonFamiliale:  return "Raison familiale"
        case .autre:            return "Autre"
        }
    }
}

struct AbsenceRecipient: Sendable, Identifiable {
    let id: String
    let displayName: String
    let isGroup: Bool
}

// MARK: - AbsenceService

/// Sends absence notifications via ENTCore Conversation API.
/// All credentials stay on-device — nothing transits through a third-party server.
@MainActor
final class AbsenceService {

    // MARK: - Public API

    /// Resolves the list of recipients for an absence notification.
    /// Ported from the RN prototype's `extractRecipients` function.
    func findRecipients(for child: Child, client: ENTClient) async throws -> [AbsenceRecipient] {
        let data = try await client.getJSON("/conversation/visible")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ENTError.invalidResponse("Format inattendu pour /conversation/visible")
        }
        return extractRecipients(from: json, child: child)
    }

    /// Builds and sends an absence message via the ENTCore Conversation API.
    func sendAbsence(
        child: Child,
        date: Date,
        dateEnd: Date?,
        motif: AbsenceMotif,
        motifDetail: String?,
        parentName: String,
        client: ENTClient
    ) async throws {
        let className = child.entClassName ?? child.grade
        let subject = buildSubject(firstName: child.firstName, className: className, date: date)
        let body = buildBody(
            firstName: child.firstName,
            className: className,
            date: date,
            dateEnd: dateEnd,
            motif: motif,
            motifDetail: motifDetail,
            parentName: parentName
        )

        let recipients = try await findRecipients(for: child, client: client)
        guard !recipients.isEmpty else {
            throw ENTError.invalidResponse("Aucun destinataire trouvé pour \(child.firstName)")
        }

        let toArray: [[String: String]] = recipients.map { r in
            ["id": r.id, "displayName": r.displayName]
        }

        let payload: [String: Any] = [
            "subject": subject,
            "body": body,
            "to": toArray,
            "cc": [] as [String],
            "bcc": [] as [String],
            "attachments": [] as [String],
        ]

        try await client.postJSON("/conversation", body: payload)
    }

    /// Returns a ready-to-use ENTClient for the child, re-authenticating via HeadlessENTAuth if needed.
    func getOrRefreshClient(for child: Child) async throws -> ENTClient {
        let provider = child.entProvider ?? .pcn
        let client = ENTClient(provider: provider)

        // Lightweight session check — /userbook/api/person returns JSON when logged in
        let isAlive: Bool
        do {
            _ = try await client.getJSON("/userbook/api/person")
            isAlive = true
        } catch ENTError.sessionExpired {
            isAlive = false
        } catch {
            isAlive = false
        }

        if isAlive { return client }

        // Session expired — re-authenticate using stored Keychain credentials
        let credKey = "ent_credentials_\(provider.rawValue)"
        guard
            let data = try? KeychainService.load(key: credKey),
            let raw = String(data: data, encoding: .utf8),
            let colon = raw.firstIndex(of: ":"),
            !raw.isEmpty
        else {
            throw ENTError.badCredentials
        }

        let login = String(raw[raw.startIndex..<colon])
        let password = String(raw[raw.index(after: colon)...])

        let loginURL = provider.baseURL.appendingPathComponent("auth/login")
        let cookies = try await HeadlessENTAuth.login(
            loginURL: loginURL,
            email: login,
            password: password
        )
        ENTClient.importCookies(cookies)
        return client
    }

    // MARK: - Message Building

    private func buildSubject(firstName: String, className: String, date: Date) -> String {
        let dateStr = formatDateShort(date)
        return "Absence de \(firstName) - \(className) - \(dateStr)"
    }

    private func buildBody(
        firstName: String,
        className: String,
        date: Date,
        dateEnd: Date?,
        motif: AbsenceMotif,
        motifDetail: String?,
        parentName: String
    ) -> String {
        let motifText: String
        if motif == .autre, let detail = motifDetail, !detail.trimmingCharacters(in: .whitespaces).isEmpty {
            motifText = detail.trimmingCharacters(in: .whitespaces)
        } else {
            motifText = motif.label
        }

        let dateText: String
        if let end = dateEnd {
            dateText = "du \(formatDateLong(date)) au \(formatDateLong(end))"
        } else {
            dateText = "le \(formatDateLong(date))"
        }

        return [
            "<p>Madame, Monsieur,</p>",
            "<p>Je vous informe que mon enfant <strong>\(firstName)</strong>, en classe de <strong>\(className)</strong>, sera absent(e) \(dateText).</p>",
            "<p>Motif\u{00A0}: \(motifText)</p>",
            "<p>Je vous prie d'agréer l'expression de mes salutations distinguées.</p>",
            "<p>\(parentName)</p>",
        ].joined(separator: "\n")
    }

    // MARK: - Recipient Resolution (ported from RN absence.ts / extractRecipients)

    private func extractRecipients(from json: [String: Any], child: Child) -> [AbsenceRecipient] {
        let groups = (json["groups"] as? [[String: Any]]) ?? []
        let users  = (json["users"]  as? [[String: Any]]) ?? []

        let className = child.entClassName ?? ""
        let classParts = className.components(separatedBy: " - ")

        // classShort: everything except the last part (teacher name)
        let classShort: String
        if classParts.count > 2 {
            classShort = classParts.dropLast().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            classShort = classParts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        }

        // Teacher last name extracted from last segment: "M. Lucas TOLOTTA" → "TOLOTTA"
        let teacherLastName: String
        let lastSegment = classParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        let stripped = lastSegment
            .replacingOccurrences(of: "^(M\\.|Mme|M)\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        teacherLastName = stripped.components(separatedBy: .whitespaces).last?.uppercased() ?? ""

        var seen = Set<String>()
        var recipients: [AbsenceRecipient] = []

        func add(_ r: AbsenceRecipient) {
            guard !seen.contains(r.id) else { return }
            seen.insert(r.id)
            recipients.append(r)
        }

        // 1. Teacher group for child's class
        for g in groups {
            guard let gId = g["id"] as? String, let gName = g["name"] as? String else { continue }
            if gName.contains("Enseignants") && !classShort.isEmpty && gName.contains(classShort) {
                add(AbsenceRecipient(id: gId, displayName: gName, isGroup: true))
            }
        }

        // 2. Individual teacher by last name
        if !teacherLastName.isEmpty {
            for u in users {
                guard let uId = u["id"] as? String,
                      let displayName = u["displayName"] as? String,
                      let profile = u["profile"] as? String,
                      profile == "Teacher" else { continue }
                if displayName.uppercased().contains(teacherLastName) {
                    add(AbsenceRecipient(id: uId, displayName: displayName, isGroup: false))
                }
            }
        }

        // 3. Director / principal
        for u in users {
            guard let uId = u["id"] as? String,
                  let displayName = u["displayName"] as? String else { continue }
            let lower = displayName.lowercased()
            if lower.contains("direct") || lower.contains("princip") {
                add(AbsenceRecipient(id: uId, displayName: displayName, isGroup: false))
            }
        }

        // 4. Fallback: any "Enseignants" group
        if recipients.isEmpty {
            for g in groups {
                guard let gId = g["id"] as? String, let gName = g["name"] as? String else { continue }
                if gName.contains("Enseignants") {
                    add(AbsenceRecipient(id: gId, displayName: gName, isGroup: true))
                    break
                }
            }
        }

        return recipients
    }

    // MARK: - Date Formatting

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .short
        return f
    }()

    private func formatDateLong(_ date: Date) -> String {
        AbsenceService.longFormatter.string(from: date)
    }

    private func formatDateShort(_ date: Date) -> String {
        AbsenceService.shortFormatter.string(from: date)
    }
}

// MARK: - ENTClient JSON helpers

extension ENTClient {
    /// GET that returns raw Data (already in ENTClient as private `get` — exposed here for AbsenceService).
    func getJSON(_ path: String) async throws -> Data {
        // Delegate to existing authenticated GET by reconstructing a URL request.
        let url = baseURL.appendingPathComponent(String(path.dropFirst()))
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if http.statusCode == 401 { throw ENTError.sessionExpired }
        if contentType.contains("text/html") { throw ENTError.sessionExpired }
        return data
    }

    /// POST JSON payload to the ENT API.
    func postJSON(_ path: String, body: [String: Any]) async throws {
        let url = baseURL.appendingPathComponent(String(path.dropFirst()))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ENTError.invalidResponse("Not HTTP")
        }
        if http.statusCode == 401 { throw ENTError.sessionExpired }
        guard (200...299).contains(http.statusCode) else {
            throw ENTError.invalidResponse("Conversation POST \(http.statusCode)")
        }
    }
}
