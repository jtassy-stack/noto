import Foundation

/// High-level Pronote client for fetching school data.
/// Wraps PronoteSession and PronoteAuth into a clean API.
final class PronoteClient: Sendable {
    private let session: PronoteSession
    private let deviceUUID: String

    init(url: String, deviceUUID: String, accountKind: PronoteAccountKind = .parent) {
        let baseURL = URL(string: url)!
        self.session = PronoteSession(baseURL: baseURL, accountKind: accountKind)
        self.deviceUUID = deviceUUID
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws -> PronoteRefreshToken {
        try await PronoteAuth.loginWithCredentials(
            session: session, username: username, password: password, deviceUUID: deviceUUID
        )
    }

    func loginWithQRCode(qrData: [String: Any], pin: String) async throws -> PronoteRefreshToken {
        try await PronoteAuth.loginWithQRCode(
            session: session, qrData: qrData, pin: pin, deviceUUID: deviceUUID
        )
    }

    func reconnect(username: String, token: String) async throws -> PronoteRefreshToken {
        try await PronoteAuth.loginWithToken(
            session: session, username: username, token: token, deviceUUID: deviceUUID
        )
    }

    func switchChild(index: Int) async {
        await session.setActiveChild(index: index)
    }

    var children: [PronoteChildResource] {
        get async { await session.childResources }
    }

    // MARK: - Grades

    func fetchGrades() async throws -> [PronoteGrade] {
        let payload: [String: Any] = [
            "Signature": ["onglet": PronoteTab.grades.rawValue],
            "donnees": [String: Any](),
        ]

        let response = try await session.request(function: "DernieresNotes", payload: payload)

        // Debug: dump response keys to understand structure
        NSLog("[noto] DernieresNotes response keys: \(response.keys.sorted())")
        for (key, value) in response {
            if let dict = value as? [String: Any] {
                NSLog("[noto]   \(key) keys: \(dict.keys.sorted())")
            } else if let arr = value as? [Any] {
                NSLog("[noto]   \(key): array[\(arr.count)]")
            } else {
                NSLog("[noto]   \(key): \(type(of: value)) = \(String(describing: value).prefix(100))")
            }
        }

        // Response is the decrypted data — look for grade list
        let gradeList = response["listeDevoirs"] as? [[String: Any]]
            ?? (response["donnees"] as? [String: Any])?["listeDevoirs"] as? [[String: Any]]
            ?? []

        return gradeList.compactMap { parseGrade($0) }
    }

    // MARK: - Timetable

    func fetchTimetable(from: Date, to: Date? = nil) async throws -> [PronoteLesson] {
        let endDate = to ?? Calendar.current.date(byAdding: .day, value: 7, to: from)!

        let payload: [String: Any] = [
            "Signature": ["onglet": PronoteTab.timetable.rawValue],
            "donnees": [
                "estEDTAnnuel": false,
                "estEDTPermanence": false,
                "avecAbsencesEleve": false,
                "avecAbsencesRessource": true,
                "avecConseilDeClasse": true,
                "avecCoursSortiePeda": true,
                "avecInfosPrefsGrille": true,
                "avecRessourcesLibrePiedHoraire": false,
                "dateDebut": dateValue(from),
                "dateFin": dateValue(endDate),
            ] as [String: Any],
        ]

        let response = try await session.request(function: "PageEmploiDuTemps", payload: payload)

        let lessonList = response["ListeCours"] as? [[String: Any]]
            ?? (response["donnees"] as? [String: Any])?["ListeCours"] as? [[String: Any]]
            ?? []

        return lessonList.compactMap { parseLesson($0) }
    }

    // MARK: - Homework

    func fetchHomework(from: Date, to: Date? = nil) async throws -> [PronoteAssignment] {
        let endDate = to ?? Calendar.current.date(byAdding: .day, value: 14, to: from)!

        let payload: [String: Any] = [
            "Signature": ["onglet": PronoteTab.assignments.rawValue],
            "donnees": [
                "domaine": dateRangeValue(from: from, to: endDate),
            ] as [String: Any],
        ]

        let response = try await session.request(function: "PageCahierDeTexte", payload: payload)

        let hwList = response["ListeTravauxAFaire"] as? [String: Any]
        let items = hwList?["V"] as? [[String: Any]]
            ?? response["ListeTravauxAFaire"] as? [[String: Any]]
            ?? (response["donnees"] as? [String: Any])?["ListeTravauxAFaire"] as? [[String: Any]]
            ?? []

        return items.compactMap { parseAssignment($0) }
    }

    // MARK: - Messages

    func fetchDiscussions() async throws -> [PronoteDiscussion] {
        let payload: [String: Any] = [
            "Signature": ["onglet": PronoteTab.discussions.rawValue],
            "donnees": [String: Any](),
        ]

        let response = try await session.request(function: "ListeMessagerie", payload: payload)

        let discussions = response["listeMessagerie"] as? [[String: Any]]
            ?? response["ListeMessagerie"] as? [[String: Any]]
            ?? (response["donnees"] as? [String: Any])?["listeMessagerie"] as? [[String: Any]]
            ?? []

        return discussions.compactMap { parseDiscussion($0) }
    }

    // MARK: - Date Helpers (Pronote format)

    private func dateValue(_ date: Date) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        formatter.locale = Locale(identifier: "fr_FR")
        return ["_T": 7, "V": formatter.string(from: date)]
    }

    private func dateRangeValue(from: Date, to: Date) -> [String: Any] {
        // Pronote uses week numbers for assignments
        // For simplicity, use the _T:8 format with week range
        return ["_T": 8, "V": "[0..52]"] // All weeks — let client filter
    }

    // MARK: - Parsers

    private func parseGrade(_ json: [String: Any]) -> PronoteGrade? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any] ?? json["matiere"] as? [String: Any]
        let subjectName = subjectDict?["V"] as? [String: Any] != nil
            ? (subjectDict?["V"] as? [String: Any])?["L"] as? String ?? "?"
            : subjectDict?["L"] as? String ?? "?"

        let kind = PronoteGradeKind(rawValue: json["G"] as? Int ?? 0) ?? .grade

        let value: Double? = if kind == .grade {
            parseNumericValue(json["note"] as? [String: Any] ?? json["Note"] as? [String: Any])
        } else {
            nil
        }

        return PronoteGrade(
            id: id,
            subjectName: subjectName,
            value: value,
            kind: kind,
            outOf: parseNumericValue(json["bareme"] as? [String: Any] ?? json["Bareme"] as? [String: Any]) ?? 20,
            coefficient: json["coefficient"] as? Double ?? json["Coefficient"] as? Double ?? 1,
            date: parsePronoteDate(json["date"] as? [String: Any] ?? json["Date"] as? [String: Any]) ?? .now,
            chapter: json["commentaire"] as? String,
            comment: nil,
            classAverage: parseNumericValue(json["moyenne"] as? [String: Any]),
            classMin: parseNumericValue(json["noteMin"] as? [String: Any]),
            classMax: parseNumericValue(json["noteMax"] as? [String: Any])
        )
    }

    private func parseLesson(_ json: [String: Any]) -> PronoteLesson? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any]
        let subject = subjectDict?["L"] as? String
            ?? (subjectDict?["V"] as? [String: Any])?["L"] as? String

        return PronoteLesson(
            id: id,
            subject: subject,
            startDate: parsePronoteDate(json["DateDuCours"] as? [String: Any]) ?? .now,
            endDate: parsePronoteDate(json["DateFinCours"] as? [String: Any]
                ?? json["dateFin"] as? [String: Any]) ?? .now,
            cancelled: json["estAnnule"] as? Bool ?? false,
            status: json["Statut"] as? String,
            teacherNames: parseNameList(json["ListeProfesseurs"]),
            classrooms: parseNameList(json["ListeSalles"]),
            isTest: json["estDevoir"] as? Bool ?? false
        )
    }

    private func parseAssignment(_ json: [String: Any]) -> PronoteAssignment? {
        guard let id = json["N"] as? String else { return nil }

        let subjectDict = json["Matiere"] as? [String: Any]
        let subjectName = subjectDict?["L"] as? String
            ?? (subjectDict?["V"] as? [String: Any])?["L"] as? String ?? "?"

        return PronoteAssignment(
            id: id,
            subjectName: subjectName,
            description: stripHTML(json["descriptif"] as? [String: Any]),
            deadline: parsePronoteDate(json["PourLe"] as? [String: Any]) ?? .now,
            done: json["TAFFait"] as? Bool ?? false,
            difficulty: PronoteAssignmentDifficulty(rawValue: json["niveauDifficulte"] as? Int ?? 0) ?? .none,
            themes: parseNameList(json["ListeThemes"])
        )
    }

    private func parseDiscussion(_ json: [String: Any]) -> PronoteDiscussion? {
        guard let id = json["N"] as? String else { return nil }
        return PronoteDiscussion(
            participantsMessageID: id,
            subject: json["objet"] as? String ?? json["Objet"] as? String ?? "",
            creator: json["expediteur"] as? String ?? json["Expediteur"] as? String,
            date: parsePronoteDate(json["date"] as? [String: Any] ?? json["Date"] as? [String: Any]) ?? .now,
            unreadCount: json["nbNonLus"] as? Int ?? json["NbNonLus"] as? Int ?? 0
        )
    }

    // MARK: - Parse Helpers

    private func parseNumericValue(_ dict: [String: Any]?) -> Double? {
        guard let dict else { return nil }
        // Format: {_T: 10, V: "14.5"} or just {V: "14.5"}
        if let v = dict["V"] as? String {
            return Double(v.replacingOccurrences(of: ",", with: "."))
        }
        if let v = dict["V"] as? Double { return v }
        return nil
    }

    private func parsePronoteDate(_ dict: [String: Any]?) -> Date? {
        guard let v = dict?["V"] as? String else { return nil }
        // Pronote date format: "07/04/2026 08:00:00" or ISO
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        for format in ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: v) { return date }
        }
        return ISO8601DateFormatter().date(from: v)
    }

    private func parseNameList(_ value: Any?) -> [String] {
        guard let list = value as? [String: Any], let items = list["V"] as? [[String: Any]] else {
            guard let directList = value as? [[String: Any]] else { return [] }
            return directList.compactMap { $0["L"] as? String }
        }
        return items.compactMap { $0["L"] as? String }
    }

    private func stripHTML(_ dict: [String: Any]?) -> String {
        let raw = dict?["V"] as? String ?? dict?["L"] as? String ?? ""
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
