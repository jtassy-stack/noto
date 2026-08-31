import Foundation
import CoreLocation

/// Resolves a device GPS fix to a French commune (INSEE code + name) via
/// the official, free, keyless `geo.api.gouv.fr` reverse-geocoding API
/// (IGN/data.gouv.fr — the Base Adresse Nationale). celyn's own directory
/// only searches schools by INSEE code or name text, not lat/lon — this
/// is the missing "GPS → INSEE" step, kept as a separate small client
/// rather than bolted onto `DirectoryAPIClient` since it's a different
/// service with a different auth story (none).
enum GeoCommuneResolver {
    struct Commune: Sendable, Equatable {
        let insee: String
        let name: String
    }

    enum ResolverError: Error, LocalizedError {
        case notFound
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notFound: "Impossible de déterminer votre commune"
            case .invalidResponse: "Réponse invalide du service de géolocalisation"
            }
        }
    }

    static func resolve(coordinate: CLLocationCoordinate2D) async throws -> Commune {
        var components = URLComponents(string: "https://geo.api.gouv.fr/communes")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(coordinate.latitude)"),
            URLQueryItem(name: "lon", value: "\(coordinate.longitude)"),
            URLQueryItem(name: "fields", value: "nom,code"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ResolverError.invalidResponse
        }
        guard let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = results.first,
              let code = first["code"] as? String,
              let name = first["nom"] as? String else {
            throw ResolverError.notFound
        }
        return Commune(insee: code, name: name)
    }
}
