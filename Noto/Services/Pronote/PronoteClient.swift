import Foundation

/// High-level Pronote client for fetching school data.
/// Wraps PronoteSession and PronoteAuth into a clean API.
///
/// Usage:
/// ```swift
/// let client = PronoteClient(url: "https://demo.pronote.net")
/// try await client.login(username: "parent", password: "pass", deviceUUID: uuid)
/// let grades = try await client.fetchGrades()
/// ```
final class PronoteClient: Sendable {
    private let session: PronoteSession
    private let deviceUUID: String

    init(url: String, deviceUUID: String, accountKind: PronoteAccountKind = .parent) {
        let baseURL = URL(string: url)!
        self.session = PronoteSession(baseURL: baseURL, accountKind: accountKind)
        self.deviceUUID = deviceUUID
    }

    // MARK: - Auth

    /// Login with username/password. Returns a refresh token to store in Keychain.
    func login(username: String, password: String) async throws -> PronoteRefreshToken {
        try await PronoteAuth.loginWithCredentials(
            session: session,
            username: username,
            password: password,
            deviceUUID: deviceUUID
        )
    }

    /// Reconnect using a stored refresh token.
    func reconnect(username: String, token: String) async throws -> PronoteRefreshToken {
        try await PronoteAuth.loginWithToken(
            session: session,
            username: username,
            token: token,
            deviceUUID: deviceUUID
        )
    }

    /// Switch active child (for parent accounts with multiple children).
    func switchChild(index: Int) async {
        await session.setActiveChild(index: index)
    }

    /// Get list of children on this account.
    var children: [PronoteChildResource] {
        get async { await session.childResources }
    }

    // MARK: - Grades

    func fetchGrades(periodIndex: Int = 0) async throws -> [PronoteGrade] {
        try await session.ensureTabAuthorized(.grades)

        let payload: [String: Any] = [
            "_Signature_": ["onglet": PronoteTab.grades.rawValue],
            "donnees": ["Periode": ["N": periodIndex]],
        ]

        let response = try await session.request(function: "DernieresNotes", payload: payload)

        guard let data = response["donneesSec"] as? [String: Any],
              let gradeList = data["listeDevoirs"] as? [[String: Any]] else {
            return []
        }

        return gradeList.compactMap { parseGrade($0) }
    }

    // MARK: - Timetable

    func fetchTimetable(from: Date, to: Date? = nil) async throws -> [PronoteLesson] {
        try await session.ensureTabAuthorized(.timetable)

        let formatter = ISO8601DateFormatter()
        let endDate = to ?? Calendar.current.date(byAdding: .day, value: 7, to: from)!

        let payload: [String: Any] = [
            "_Signature_": ["onglet": PronoteTab.timetable.rawValue],
            "donnees": [
                "dateDebut": ["V": formatter.string(from: from)],
                "dateFin": ["V": formatter.string(from: endDate)],
                "avecCoursAnnule": true,
            ],
        ]

        let response = try await session.request(function: "PageEmploiDuTemps", payload: payload)

        guard let data = response["donneesSec"] as? [String: Any],
              let lessonList = data["ListeCours"] as? [[String: Any]] else {
            return []
        }

        return lessonList.compactMap { parseLesson($0) }
    }

    // MARK: - Homework

    func fetchHomework(from: Date, to: Date? = nil) async throws -> [PronoteAssignment] {
        try await session.ensureTabAuthorized(.assignments)

        let formatter = ISO8601DateFormatter()
        let endDate = to ?? Calendar.current.date(byAdding: .day, value: 14, to: from)!

        let payload: [String: Any] = [
            "_Signature_": ["onglet": PronoteTab.assignments.rawValue],
            "donnees": [
                "dateDebut": ["V": formatter.string(from: from)],
                "dateFin": ["V": formatter.string(from: endDate)],
            ],
        ]

        let response = try await session.request(function: "PageCahierDeTexte", payload: payload)

        guard let data = response["donneesSec"] as? [String: Any],
              let hwList = data["ListeTravauxAFaire"] as? [[String: Any]] else {
            return []
        }

        return hwList.compactMap { parseAssignment($0) }
    }

    // MARK: - Messages

    func fetchDiscussions() async throws -> [PronoteDiscussion] {
        try await session.ensureTabAuthorized(.discussions)

        let payload: [String: Any] = [
            "_Signature_": ["onglet": PronoteTab.discussions.rawValue],
            "donnees": [:],
        ]

        let response = try await session.request(function: "ListeDiscussions", payload: payload)

        guard let data = response["donneesSec"] as? [String: Any],
              let discussions = data["listeDiscussions"] as? [[String: Any]] else {
            return []
        }

        return discussions.compactMap { parseDiscussion($0) }
    }

    func fetchMessages(discussionId: String) async throws -> [PronoteMessage] {
        let payload: [String: Any] = [
            "_Signature_": ["onglet": PronoteTab.discussions.rawValue],
            "donnees": [
                "Objet": ["N": discussionId],
                "marpiercqueLu": true,
            ],
        ]

        let response = try await session.request(function: "ListeMessages", payload: payload)

        guard let data = response["donneesSec"] as? [String: Any],
              let messages = data["listeMessages"] as? [[String: Any]] else {
            return []
        }

        return messages.compactMap { parseMessage($0) }
    }

    // MARK: - Parsers

    private func parseGrade(_ json: [String: Any]) -> PronoteGrade? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any]
        let subjectName = subjectDict?["L"] as? String ?? "?"

        let kindRaw = json["estEnGroupe"] as? Int ?? 0
        let kind = PronoteGradeKind(rawValue: kindRaw) ?? .grade

        let value: Double? = if kind == .grade {
            parseGradeValue(json["note"] as? [String: Any])
        } else {
            nil
        }

        return PronoteGrade(
            id: id,
            subjectName: subjectName,
            value: value,
            kind: kind,
            outOf: parseGradeValue(json["bareme"] as? [String: Any]) ?? 20,
            coefficient: json["coefficient"] as? Double ?? 1,
            date: parseDate(json["date"] as? [String: Any]) ?? .now,
            chapter: json["commentaire"] as? String,
            comment: nil,
            classAverage: parseGradeValue(json["moyenne"] as? [String: Any]),
            classMin: parseGradeValue(json["noteMin"] as? [String: Any]),
            classMax: parseGradeValue(json["noteMax"] as? [String: Any])
        )
    }

    private func parseLesson(_ json: [String: Any]) -> PronoteLesson? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any]
        let subject = subjectDict?["L"] as? String

        return PronoteLesson(
            id: id,
            subject: subject,
            startDate: parseDate(json["DateDuCours"] as? [String: Any]) ?? .now,
            endDate: parseDate(json["DateFinCours"] as? [String: Any]) ?? .now,
            cancelled: json["estAnnule"] as? Bool ?? false,
            status: json["Statut"] as? String,
            teacherNames: parseStringArray(json["ListeProfesseurs"]),
            classrooms: parseStringArray(json["ListeSalles"]),
            isTest: json["estDevoir"] as? Bool ?? false
        )
    }

    private func parseAssignment(_ json: [String: Any]) -> PronoteAssignment? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any]
        let subjectName = subjectDict?["L"] as? String ?? "?"

        return PronoteAssignment(
            id: id,
            subjectName: subjectName,
            description: stripHTML(json["descriptif"] as? String ?? ""),
            deadline: parseDate(json["PourLe"] as? [String: Any]) ?? .now,
            done: json["TAFFait"] as? Bool ?? false,
            difficulty: PronoteAssignmentDifficulty(rawValue: json["niveauDifficulte"] as? Int ?? 0) ?? .none,
            themes: parseStringArray(json["ListeThemes"])
        )
    }

    private func parseDiscussion(_ json: [String: Any]) -> PronoteDiscussion? {
        guard let id = json["N"] as? String else { return nil }
        return PronoteDiscussion(
            participantsMessageID: id,
            subject: json["Objet"] as? String ?? "",
            creator: json["Auteur"] as? String,
            date: parseDate(json["Date"] as? [String: Any]) ?? .now,
            unreadCount: json["nbNonLus"] as? Int ?? 0
        )
    }

    private func parseMessage(_ json: [String: Any]) -> PronoteMessage? {
        guard let id = json["N"] as? String else { return nil }
        return PronoteMessage(
            id: id,
            content: stripHTML(json["contenu"] as? String ?? ""),
            date: parseDate(json["Date"] as? [String: Any]) ?? .now,
            sender: json["Auteur"] as? String ?? ""
        )
    }

    // MARK: - Parse Helpers

    private func parseGradeValue(_ dict: [String: Any]?) -> Double? {
        guard let v = dict?["V"] as? String else { return nil }
        return Double(v.replacingOccurrences(of: ",", with: "."))
    }

    private func parseDate(_ dict: [String: Any]?) -> Date? {
        guard let v = dict?["V"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: v)
    }

    private func parseStringArray(_ value: Any?) -> [String] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { $0["L"] as? String }
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
