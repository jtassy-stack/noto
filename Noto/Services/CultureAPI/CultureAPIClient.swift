import Foundation

/// Client for culture-api (celyn.io).
/// Fetches cultural recommendations based on school context.
final class CultureAPIClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    private static let defaultAPIKey = "ck_caccfd12fb2d4dd99551769a0ab33196"

    init(baseURL: URL = URL(string: "https://celyn.io/api")!, apiKey: String = CultureAPIClient.defaultAPIKey) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Thematic Search

    func searchThematic(
        query: String,
        types: [String] = ["event", "podcast", "oeuvre"],
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        geo: (lat: Double, lng: Double)? = nil,
        limit: Int = 10
    ) async throws -> [CultureSearchResult] {
        var params = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: types.joined(separator: ",")),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let ageMin { params.append(URLQueryItem(name: "age_min", value: "\(ageMin)")) }
        if let ageMax { params.append(URLQueryItem(name: "age_max", value: "\(ageMax)")) }
        if let geo {
            params.append(URLQueryItem(name: "lat", value: "\(geo.lat)"))
            params.append(URLQueryItem(name: "lng", value: "\(geo.lng)"))
        }

        let data = try await get("/search/thematic", params: params)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseSearchResult($0) }
    }

    // MARK: - Recommendations

    func recommendations(
        topics: [String],
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        context: String? = nil,
        geo: (lat: Double, lng: Double)? = nil,
        limit: Int = 5
    ) async throws -> [CultureSearchResult] {
        var body: [String: Any] = [
            "topics": topics,
            "limit": limit,
        ]
        if let ageMin { body["age_min"] = ageMin }
        if let ageMax { body["age_max"] = ageMax }
        if let context { body["context"] = context }
        if let geo { body["geo"] = ["lat": geo.lat, "lng": geo.lng] }

        let data = try await post("/recommendations", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["recommendations"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseSearchResult($0) }
    }

    // MARK: - Batch Recommendations (multi-child)

    func batchRecommendations(queries: [BatchQuery]) async throws -> BatchResult {
        let queriesPayload: [[String: Any]] = queries.map { q in
            var dict: [String: Any] = [
                "topics": q.topics,
                "limit": q.limit,
            ]
            if let ageMin = q.ageMin { dict["age_min"] = ageMin }
            if let ageMax = q.ageMax { dict["age_max"] = ageMax }
            if let context = q.context { dict["context"] = context }
            if let geo = q.geo { dict["geo"] = ["lat": geo.lat, "lng": geo.lng] }
            return dict
        }

        let data = try await post("/recommendations/batch", body: ["queries": queriesPayload])

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BatchResult(perQuery: [], shared: [])
        }

        // Parse per-query results
        var perQuery: [[CultureSearchResult]] = []
        if let results = json["results"] as? [[String: Any]] {
            for result in results {
                let recos = (result["recommendations"] as? [[String: Any]]) ?? []
                perQuery.append(recos.compactMap { parseSearchResult($0) })
            }
        }

        // Parse shared (family) results
        var shared: [SharedResult] = []
        if let sharedJson = json["shared"] as? [[String: Any]] {
            for s in sharedJson {
                let matchedQueries = s["matched_queries"] as? [Int] ?? []
                if let reco = s["recommendation"] as? [String: Any],
                   let parsed = parseSearchResult(reco) {
                    shared.append(SharedResult(matchedQueryIndices: matchedQueries, result: parsed))
                }
            }
        }

        return BatchResult(perQuery: perQuery, shared: shared)
    }

    // MARK: - Events with filters

    func events(
        topic: String? = nil,
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        limit: Int = 20
    ) async throws -> [CultureSearchResult] {
        var params = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let topic { params.append(URLQueryItem(name: "topic", value: topic)) }
        if let ageMin { params.append(URLQueryItem(name: "age_min", value: "\(ageMin)")) }
        if let ageMax { params.append(URLQueryItem(name: "age_max", value: "\(ageMax)")) }

        let data = try await get("/events", params: params)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["events"] as? [[String: Any]] ?? json["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseSearchResult($0) }
    }

    // MARK: - HTTP

    private func get(_ path: String, params: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = params

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CultureAPIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CultureAPIError.httpError(http.statusCode)
        }
    }

    // MARK: - Parsing

    private func parseSearchResult(_ json: [String: Any]) -> CultureSearchResult? {
        // id can be a UUID string or an Int depending on the result type
        let id: String
        if let strId = json["id"] as? String { id = strId }
        else if let intId = json["id"] as? Int { id = String(intId) }
        else { return nil }
        return CultureSearchResult(
            id: id,
            type: json["type"] as? String ?? "event",
            title: json["title"] as? String ?? "",
            description: json["description"] as? String,
            score: json["score"] as? Double,
            topics: json["topics"] as? [String] ?? [],
            imageURL: json["image_url"] as? String ?? json["imageUrl"] as? String,
            ageMin: json["age_min"] as? Int,
            ageMax: json["age_max"] as? Int,
            venueName: json["venue_name"] as? String,
            venueCity: json["venue_city"] as? String,
            startTime: json["start_time"] as? String,
            endTime: json["end_time"] as? String,
            category: json["category"] as? String,
            oeuvreTitle: json["oeuvre_title"] as? String,
            episodeTitle: json["episode_title"] as? String,
            showName: json["show_name"] as? String,
            station: json["station"] as? String,
            audioURL: json["audio_url"] as? String,
            publishedAt: json["published_at"] as? String,
            opinionSummary: json["opinion_summary"] as? String,
            oeuvreType: json["oeuvre_type"] as? String,
            director: json["director"] as? String,
            author: json["author"] as? String,
            year: json["year"] as? Int,
            genres: json["genres"] as? [String] ?? []
        )
    }
}

// MARK: - Types

struct CultureSearchResult: Sendable, Identifiable {
    let id: String
    let type: String
    let title: String
    let description: String?
    let score: Double?
    let topics: [String]
    let imageURL: String?
    let ageMin: Int?
    let ageMax: Int?

    // Event-specific
    let venueName: String?
    let venueCity: String?
    let startTime: String?
    let endTime: String?
    let category: String?
    let oeuvreTitle: String?

    // Podcast-specific
    let episodeTitle: String?
    let showName: String?
    let station: String?
    let audioURL: String?
    let publishedAt: String?
    let opinionSummary: String?

    // Oeuvre-specific
    let oeuvreType: String?
    let director: String?
    let author: String?
    let year: Int?
    let genres: [String]

    // Context metadata (set by caller, not from API)
    var linkedSubject: String? = nil
    var linkedChildName: String? = nil
    var linkedLevel: String? = nil
}

struct BatchQuery {
    let topics: [String]
    let ageMin: Int?
    let ageMax: Int?
    let context: String?
    let geo: (lat: Double, lng: Double)?
    let limit: Int

    init(topics: [String], ageMin: Int? = nil, ageMax: Int? = nil, context: String? = nil, geo: (lat: Double, lng: Double)? = nil, limit: Int = 5) {
        self.topics = topics
        self.ageMin = ageMin
        self.ageMax = ageMax
        self.context = context
        self.geo = geo
        self.limit = limit
    }
}

struct BatchResult {
    let perQuery: [[CultureSearchResult]]
    let shared: [SharedResult]
}

struct SharedResult {
    let matchedQueryIndices: [Int]
    let result: CultureSearchResult
}

enum CultureAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Réponse invalide de culture-api"
        case .httpError(let code): "Erreur HTTP \(code)"
        }
    }
}
