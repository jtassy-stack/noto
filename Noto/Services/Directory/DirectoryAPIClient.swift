import Foundation

/// Client for the `celyn.io/api/directory/*` namespace — French school
/// registry (RNE), commune services, and ENT platforms.
///
/// Every method throws on error (network, HTTP, decoding). The caller
/// decides whether to fall back to `ENTRegistry.bundledENTs` for the
/// ENT list, or to surface the failure to the user (onboarding).
final class DirectoryAPIClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    private static let defaultAPIKey = "noto_32dd04dfb3a21056"

    init(
        baseURL: URL = URL(string: "https://celyn.io/api/directory")!,
        apiKey: String = DirectoryAPIClient.defaultAPIKey,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - ENT registry

    /// Live list of ENT platforms served by celyn. Callers that need
    /// offline tolerance should `catch` and fall back to
    /// `ENTRegistry.bundledENTs`.
    func fetchENTs() async throws -> [DirectoryENTProvider] {
        let data = try await get("/ents")
        return try decode(ENTsResponse.self, from: data).ents
    }

    // MARK: - School lookup

    /// Fetch a school by its RNE code (Répertoire National des
    /// Établissements). The response bundles the school's commune,
    /// ENT, service domains, and a flat `mailDomains` array ready to
    /// seed the mail whitelist.
    func fetchSchool(rne: String) async throws -> DirectorySchool {
        let data = try await get("/schools/\(rne.uppercased())")
        return try decode(DirectorySchool.self, from: data)
    }

    /// Postgres FTS on the school name, optionally scoped to a commune.
    /// Used at onboarding when the app knows the school name but not
    /// yet the RNE.
    func searchSchools(
        q: String? = nil,
        insee: String? = nil,
        limit: Int = 20
    ) async throws -> [DirectorySchoolSummary] {
        var params: [URLQueryItem] = [URLQueryItem(name: "limit", value: "\(limit)")]
        // Skip empty `q` — UI often binds a @State String that's "" before
        // the user types; server FTS on empty is unspecified.
        if let q, !q.isEmpty { params.append(URLQueryItem(name: "q", value: q)) }
        if let insee, !insee.isEmpty { params.append(URLQueryItem(name: "insee", value: insee)) }

        let data = try await get("/schools/search", params: params)
        return try decode(SchoolsSearchResponse.self, from: data).schools
    }

    // MARK: - Commune services

    /// Commune + its administrative service domains (cantine,
    /// périscolaire, mairie, caisse des écoles). Used to widen the
    /// mail whitelist beyond the school's ENT.
    func fetchCommune(insee: String) async throws -> DirectoryCommune {
        let data = try await get("/communes/\(insee)/services")
        return try decode(DirectoryCommune.self, from: data)
    }

    // MARK: - HTTP

    private func get(_ path: String, params: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !params.isEmpty {
            components.queryItems = params
        }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DirectoryAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200: return data
        case 404: throw DirectoryAPIError.notFound
        default:  throw DirectoryAPIError.httpError(http.statusCode, bodySnippet(data))
        }
    }

    /// Extracts up to 512 bytes of the response body as UTF-8 for
    /// diagnostic context in error messages (Sentry, logs). celyn's
    /// error responses carry `{"error":"..."}` — without this, 4xx/5xx
    /// surface as opaque status codes.
    private func bodySnippet(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let slice = data.prefix(512)
        return String(data: slice, encoding: .utf8)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DirectoryAPIError.decoding(error)
        }
    }
}

// MARK: - Response envelopes

private struct ENTsResponse: Decodable {
    let version: Int?
    let ents: [DirectoryENTProvider]
}

private struct SchoolsSearchResponse: Decodable {
    let schools: [DirectorySchoolSummary]
}

// MARK: - Public models

struct DirectorySchool: Codable, Sendable, Equatable {
    let rne: String
    let name: String
    let kind: String?
    let academy: String?
    let holidayZone: String?
    let website: String?
    let commune: DirectoryCommuneRef?
    let ent: DirectoryENTRef?
    let services: [DirectoryCommuneService]
    let mailDomains: [String]
}

struct DirectorySchoolSummary: Codable, Sendable, Identifiable, Equatable {
    var id: String { rne }
    let rne: String
    let name: String
    let kind: String?
    let communeInsee: String?
    let academy: String?
}

struct DirectoryCommune: Codable, Sendable, Equatable {
    let insee: String
    let name: String
    let dept: String
    let region: String
    let services: [DirectoryCommuneService]
}

struct DirectoryCommuneRef: Codable, Sendable, Equatable {
    let insee: String
    let name: String?
    let dept: String?
    let region: String?
}

struct DirectoryENTRef: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let domains: [String]
}

struct DirectoryCommuneService: Codable, Sendable, Equatable {
    let kind: String
    let providerName: String?
    let domain: String
    let confidence: String?
}

// MARK: - Errors

enum DirectoryAPIError: Error, LocalizedError {
    case invalidResponse
    case notFound
    case httpError(Int, String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Réponse invalide du service annuaire"
        case .notFound:
            return "Entrée introuvable dans l'annuaire"
        case .httpError(let code, let body):
            if let body, !body.isEmpty { return "Erreur HTTP \(code): \(body)" }
            return "Erreur HTTP \(code)"
        case .decoding(let err):
            return "Décodage: \(err.localizedDescription)"
        }
    }
}
