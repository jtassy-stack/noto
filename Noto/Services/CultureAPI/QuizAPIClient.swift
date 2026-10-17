import Foundation

/// Client for celyn's quiz v2 « bank » (`GET /api/quiz/v2/bank`): programme
/// questions for one level, served for the Révisions module (Phase 3.2).
/// Contract: celyn `docs/quiz-v2-contrat.md` §11 (agreed 15 Oct 2026, amended
/// the same day: `removed`, cursor non-null only while rows follow), mirrored
/// by `BankResponse` / `BankQuizDto` / `BankRemovedDto` below.
///
/// Privacy (CLAUDE.md, design brief B.5):
/// - Requests carry ONLY `app=noto` (constant, required by the contract) and
///   public programme vocabulary: `grade`, `subject`, `theme`, `limit`,
///   `updatedSince`. Never a child id, name, school, location, homework text
///   or answer.
/// - The `x-api-key` is the app key shared with `CultureAPIClient`, injected
///   at build time (Infisical → `Config.xcconfig` → Info.plist). Never
///   hard-coded.
/// - Corrections happen on device; results are never sent.
final class QuizAPIClient: Sendable {
    /// Only consumer accepted by the bank endpoint for now.
    static let app = "noto"
    /// Server bounds for `limit` (contract: 1…200, default 50).
    static let limitRange = 1...200
    /// celyn caps `reason` at 500 chars.
    static let maxReportReasonLength = 500

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://celyn.io/api")!,
        apiKey: String = CultureAPIClient.bundledAPIKey,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Bank (GET)

    /// One page of the bank for `grade` (canonical nōto level, `6e` … `Tle`).
    /// `theme` is only sent together with `subject` (the server answers 400
    /// otherwise), so a theme without a subject is dropped here rather than
    /// producing a request that can never succeed. Callers loop while
    /// `nextUpdatedSince` is non-null, whatever the page size (see
    /// `QuizBankStore`).
    func bank(
        grade: String,
        subject: String? = nil,
        theme: String? = nil,
        limit: Int = 50,
        updatedSince: String? = nil
    ) async throws -> BankResponse {
        var params = [
            URLQueryItem(name: "app", value: Self.app),
            URLQueryItem(name: "grade", value: grade),
        ]
        let subject = subject.flatMap { $0.isEmpty ? nil : $0 }
        if let subject {
            params.append(URLQueryItem(name: "subject", value: subject))
            if let theme, !theme.isEmpty {
                params.append(URLQueryItem(name: "theme", value: theme))
            }
        }
        let clamped = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        params.append(URLQueryItem(name: "limit", value: "\(clamped)"))
        if let updatedSince, !updatedSince.isEmpty {
            params.append(URLQueryItem(name: "updatedSince", value: updatedSince))
        }

        var request = URLRequest(url: url(path: "/quiz/v2/bank", params: params))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request, expecting: [200])
        do {
            return try JSONDecoder().decode(BankResponse.self, from: data)
        } catch {
            throw QuizAPIError.decoding(error)
        }
    }

    // MARK: - Culture lot of the day (GET)

    /// Daily culture lot consumer. Keskonfé's lot is culture-only, grade-free
    /// and the same for everyone, so asking for it says nothing about the
    /// child (design brief C.1 item 6: « via B.1 keskonfe until celyn grade
    /// support lands »).
    static let cultureLotApp = "keskonfe"

    /// Every Koi ? app whose lots feed the culture G quiz (contract §6:
    /// `app=keskonfe|sirius|leclub`): Keskonfé (œuvres), Sirius (actu et
    /// culture G), Le Club (sport). Each lot is public and the same for
    /// everyone; audience filtering happens on device (`CultureQuizFilter`).
    static let cultureLotApps = ["keskonfe", "sirius", "leclub"]

    /// One Koi lot: `GET /api/quiz/v2/lot?app=<app>[&date=YYYY-MM-DD]`
    /// (contract §6, `KoiDailyDto` + v2 fields). The request carries ONLY
    /// `app` and, for a past lot, its public `date`: no level, no location,
    /// nothing about the child. Without `date` celyn answers the Paris day,
    /// which is the day the lot is generated for (a device-local date could
    /// ask for a lot that does not exist yet). 404 = no lot that day.
    func cultureLot(app: String = cultureLotApp, date: String? = nil) async throws -> CultureLotResponse {
        var params = [URLQueryItem(name: "app", value: app)]
        if let date, !date.isEmpty { params.append(URLQueryItem(name: "date", value: date)) }
        var request = URLRequest(url: url(path: "/quiz/v2/lot", params: params))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request, expecting: [200])
        do {
            return try JSONDecoder().decode(CultureLotResponse.self, from: data)
        } catch {
            throw QuizAPIError.decoding(error)
        }
    }

    // MARK: - Report (POST)

    /// Flags a wrong or inappropriate question:
    /// `POST /api/quiz/v2/quiz/:id/report`, body `{reason?}` (≤ 500 UTF-16 units),
    /// answered 202 (new or duplicate report, idempotent per reporter).
    ///
    /// Only to be called from a parent-side action (or the child side behind
    /// the parent gate) — future UI, nothing calls it yet. `deviceID` is a
    /// random per-install UUID (`QuizReporterID`), never a child id or a
    /// `PersistentIdentifier`; celyn stores only `sha256(salt + id)`.
    /// Unit tests always mock it (CLAUDE.md: no POST to live APIs).
    func report(quizId: UUID, reason: String? = nil, deviceID: String? = nil) async throws {
        var request = URLRequest(url: url(path: "/quiz/v2/quiz/\(quizId.uuidString.lowercased())/report"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let deviceID, !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
        }
        var body: [String: String] = [:]
        if let reason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body["reason"] = Self.truncatedReason(trimmed) }
        }
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await send(request, expecting: [200, 202])
    }

    /// celyn validates `reason` with zod `.max(500)`, i.e. JS UTF-16 code
    /// units, not Swift Characters: an emoji counts 2+ units. Keeps whole
    /// Characters while the UTF-16 length stays within the limit.
    static func truncatedReason(_ reason: String) -> String {
        guard reason.utf16.count > maxReportReasonLength else { return reason }
        var result = ""
        var units = 0
        for character in reason {
            let width = character.utf16.count
            if units + width > maxReportReasonLength { break }
            result.append(character)
            units += width
        }
        return result
    }

    // MARK: - HTTP

    private func url(path: String, params: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !params.isEmpty { components.queryItems = params }
        return components.url!
    }

    private func send(_ request: URLRequest, expecting okStatuses: Set<Int>) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuizAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuizAPIError.invalidResponse
        }
        if okStatuses.contains(http.statusCode) { return data }
        let snippet = Self.bodySnippet(data)
        switch http.statusCode {
        case 400: throw QuizAPIError.badRequest(snippet)
        case 401: throw QuizAPIError.unauthorized
        case 404: throw QuizAPIError.notFound
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw QuizAPIError.rateLimited(retryAfter: retryAfter)
        default: throw QuizAPIError.httpError(http.statusCode, snippet)
        }
    }

    /// Up to 512 bytes of the body for diagnostics; celyn errors are `{error}`.
    private static func bodySnippet(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data.prefix(512), encoding: .utf8)
    }
}

// MARK: - Wire format (contract mirror)

/// `GET /api/quiz/v2/bank` 200 envelope (contract amendment, 15 Oct 2026).
struct BankResponse: Decodable, Sendable, Equatable {
    let app: String
    let grade: String
    let count: Int
    let items: [BankQuizDto]
    /// Rows of the requested scope that are no longer servable (reported past
    /// the threshold, excluded) since `updatedSince`. Always `[]` on a full
    /// sync (no `updatedSince`). The client deletes them by `id`.
    let removed: [BankRemovedDto]
    /// Non-null ONLY when more rows follow (the `updatedAt` of the page's last
    /// row); the client loops while it is non-null. A non-final page may hold
    /// fewer than `limit` items (removals share the page). Kept as the raw
    /// string celyn emitted (fractional seconds, `Z`) so it round-trips
    /// exactly as the next `updatedSince`.
    let nextUpdatedSince: String?

    private enum CodingKeys: String, CodingKey {
        case app, grade, count, items, removed, nextUpdatedSince
    }

    init(
        app: String, grade: String, count: Int, items: [BankQuizDto],
        removed: [BankRemovedDto] = [], nextUpdatedSince: String?
    ) {
        self.app = app
        self.grade = grade
        self.count = count
        self.items = items
        self.removed = removed
        self.nextUpdatedSince = nextUpdatedSince
    }

    /// Strict: every key must be present, nullable ones included
    /// (`decode(String?.self)` throws `keyNotFound`, unlike the synthesized
    /// `decodeIfPresent`), and `removed` too (may be empty). Unknown keys are
    /// ignored for forward compatibility.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        grade = try c.decode(String.self, forKey: .grade)
        count = try c.decode(Int.self, forKey: .count)
        items = try c.decode([BankQuizDto].self, forKey: .items)
        removed = try c.decode([BankRemovedDto].self, forKey: .removed)
        nextUpdatedSince = try c.decode(String?.self, forKey: .nextUpdatedSince)
    }
}

/// One `removed` entry: a bank row the client must delete (`id`, unknown ids
/// ignored). `updatedAt` feeds the high-water mark like an item's.
struct BankRemovedDto: Decodable, Sendable, Equatable {
    let id: UUID
    let questionKey: String
    /// ISO-8601 with fractional seconds, kept raw (see `BankResponse`).
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, questionKey, updatedAt
    }

    init(id: UUID, questionKey: String, updatedAt: String) {
        self.id = id
        self.questionKey = questionKey
        self.updatedAt = updatedAt
    }

    /// Strict: all three keys required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        questionKey = try c.decode(String.self, forKey: .questionKey)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }
}

/// One bank question, celyn `BankQuizDto`. Field-for-field with the contract;
/// enum-like fields (`kind`, `domain`, `tone`, `reviewMethod`) stay `String` so
/// a value celyn adds later never fails a whole page. Structural checks
/// (4 distinct choices, ranges) live in `QuizBankMapper` and drop the item.
struct BankQuizDto: Decodable, Sendable, Equatable {
    let id: UUID
    let questionKey: String
    let grade: String
    let subject: String
    let theme: String
    let notion: String?
    /// "programme"
    let kind: String
    /// "scolaire"
    let domain: String
    /// 1…3
    let difficulty: Int
    /// "histoire"
    let tone: String
    let question: String
    let choices: [String]
    /// 0…3
    let answerIndex: Int
    let explanation: String?
    let oeuvreId: UUID?
    let oeuvreTitle: String?
    let imageUrl: String?
    /// "jev" | "llm" | "deterministic" (non-null by contract; tolerated as
    /// null, which maps to `reviewed = false`).
    let reviewMethod: String?
    /// 0…1
    let reviewConfidence: Double
    /// ISO-8601 with fractional seconds, kept raw (see `BankResponse`).
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, questionKey, grade, subject, theme, notion, kind, domain, difficulty, tone,
             question, choices, answerIndex, explanation, oeuvreId, oeuvreTitle, imageUrl,
             reviewMethod, reviewConfidence, updatedAt
    }

    init(
        id: UUID, questionKey: String, grade: String, subject: String, theme: String,
        notion: String?, kind: String, domain: String, difficulty: Int, tone: String,
        question: String, choices: [String], answerIndex: Int, explanation: String?,
        oeuvreId: UUID?, oeuvreTitle: String?, imageUrl: String?,
        reviewMethod: String?, reviewConfidence: Double, updatedAt: String
    ) {
        self.id = id
        self.questionKey = questionKey
        self.grade = grade
        self.subject = subject
        self.theme = theme
        self.notion = notion
        self.kind = kind
        self.domain = domain
        self.difficulty = difficulty
        self.tone = tone
        self.question = question
        self.choices = choices
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.oeuvreId = oeuvreId
        self.oeuvreTitle = oeuvreTitle
        self.imageUrl = imageUrl
        self.reviewMethod = reviewMethod
        self.reviewConfidence = reviewConfidence
        self.updatedAt = updatedAt
    }

    /// Strict: every contract key must be present (nullable ones may be null).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        questionKey = try c.decode(String.self, forKey: .questionKey)
        grade = try c.decode(String.self, forKey: .grade)
        subject = try c.decode(String.self, forKey: .subject)
        theme = try c.decode(String.self, forKey: .theme)
        notion = try c.decode(String?.self, forKey: .notion)
        kind = try c.decode(String.self, forKey: .kind)
        domain = try c.decode(String.self, forKey: .domain)
        difficulty = try c.decode(Int.self, forKey: .difficulty)
        tone = try c.decode(String.self, forKey: .tone)
        question = try c.decode(String.self, forKey: .question)
        choices = try c.decode([String].self, forKey: .choices)
        answerIndex = try c.decode(Int.self, forKey: .answerIndex)
        explanation = try c.decode(String?.self, forKey: .explanation)
        oeuvreId = try c.decode(UUID?.self, forKey: .oeuvreId)
        oeuvreTitle = try c.decode(String?.self, forKey: .oeuvreTitle)
        imageUrl = try c.decode(String?.self, forKey: .imageUrl)
        reviewMethod = try c.decode(String?.self, forKey: .reviewMethod)
        reviewConfidence = try c.decode(Double.self, forKey: .reviewConfidence)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }
}

/// `GET /api/quiz/v2/lot` 200 (`KoiDailyDto`, celyn `src/lib/koi/read.ts`).
/// Tolerant, like CelynKit (contract §8): an unreadable quiz is dropped,
/// never the lot. `citation`, `editions`, `nextEditionAt` are ignored.
struct CultureLotResponse: Decodable, Sendable, Equatable {
    /// YYYY-MM-DD (Paris day of the lot).
    let date: String
    let number: Int
    let quizzes: [CultureLotQuizDto]

    private enum CodingKeys: String, CodingKey { case date, number, quizzes }

    init(date: String, number: Int, quizzes: [CultureLotQuizDto]) {
        self.date = date
        self.number = number
        self.quizzes = quizzes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        let lossy = try c.decodeIfPresent([Lossy<CultureLotQuizDto>].self, forKey: .quizzes) ?? []
        quizzes = lossy.compactMap(\.value)
    }

    /// Decodes an element or swallows its error (keeps the array going).
    private struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}

/// One quiz of the lot (`KoiQuizV2Dto`), the fields nōto shows. Required:
/// `id`, `domain`, `question`, `choices`, `answerIndex`; the rest is optional
/// so a field celyn drops or nulls never hides the card.
struct CultureLotQuizDto: Codable, Sendable, Equatable {
    let id: UUID
    /// films | series | animes | livres | musique | podcasts | spectacles | expos | jeux (Keskonfé),
    /// or a news domain on Sirius / Le Club (politique, international, societe, economie, sante,
    /// environnement, sciences_tech, sport, culture).
    let domain: String
    let difficulty: Int
    /// actu | catalogue | bridge | filmo | fait
    let kind: String
    let question: String
    let choices: [String]
    let answerIndex: Int
    let explanation: String?
    let oeuvreTitle: String?
    /// actu | histoire | fun (v2).
    let tone: String?
    /// YYYY-MM-DD, nil = evergreen (v2).
    let validUntil: String?

    private enum CodingKeys: String, CodingKey {
        case id, domain, difficulty, kind, question, choices, answerIndex, explanation, oeuvreTitle,
             tone, validUntil
    }

    init(id: UUID, domain: String, difficulty: Int = 1, kind: String = "catalogue", question: String,
         choices: [String], answerIndex: Int, explanation: String? = nil, oeuvreTitle: String? = nil,
         tone: String? = nil, validUntil: String? = nil) {
        self.id = id
        self.domain = domain
        self.difficulty = difficulty
        self.kind = kind
        self.question = question
        self.choices = choices
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.oeuvreTitle = oeuvreTitle
        self.tone = tone
        self.validUntil = validUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        difficulty = (try? c.decodeIfPresent(Int.self, forKey: .difficulty)) ?? 1
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        question = try c.decode(String.self, forKey: .question)
        choices = try c.decode([String].self, forKey: .choices)
        answerIndex = try c.decode(Int.self, forKey: .answerIndex)
        explanation = try? c.decodeIfPresent(String.self, forKey: .explanation)
        oeuvreTitle = try? c.decodeIfPresent(String.self, forKey: .oeuvreTitle)
        tone = try? c.decodeIfPresent(String.self, forKey: .tone)
        validUntil = try? c.decodeIfPresent(String.self, forKey: .validUntil)
    }
}

// MARK: - Errors

enum QuizAPIError: Error, LocalizedError {
    case invalidResponse
    /// 400: bad app / grade / limit / updatedSince, or theme without subject.
    case badRequest(String?)
    /// 401: missing or invalid key (e.g. empty `CultureAPIKey` on a fresh clone).
    case unauthorized
    case notFound
    /// 429, with `Retry-After` seconds when the server sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case httpError(Int, String?)
    case decoding(Error)
    /// Offline, timeout, TLS…
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Réponse invalide du service de quiz"
        case .badRequest(let body): return "Requête refusée par le service de quiz\(body.map { ": \($0)" } ?? "")"
        case .unauthorized: return "Clé d'API du service de quiz absente ou invalide"
        case .notFound: return "Question introuvable"
        case .rateLimited: return "Service de quiz momentanément saturé"
        case .httpError(let code, let body):
            if let body, !body.isEmpty { return "Erreur HTTP \(code): \(body)" }
            return "Erreur HTTP \(code)"
        case .decoding(let err): return "Décodage: \(err.localizedDescription)"
        case .transport(let err): return "Réseau: \(err.localizedDescription)"
        }
    }
}

// MARK: - Reporter identity

/// Random per-install UUID sent as `x-device-id` with reports, so celyn can
/// cap reports per reporter without falling back to the client IP. Stored in
/// the Keychain (survives reinstall-free updates), never derived from a
/// child, an account or the hardware.
enum QuizReporterID {
    static let keychainKey = "QuizReporterDeviceID"

    static func current() -> String {
        if let data = try? KeychainService.load(key: keychainKey),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try? KeychainService.save(key: keychainKey, data: Data(fresh.utf8))
        return fresh
    }
}
