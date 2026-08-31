import Foundation

// MARK: - School search

struct SkolengoSchool: Sendable, Codable {
    let id: String
    let name: String
    let city: String?
    let emsCode: String?
    let emsOIDCWellKnownUrl: String
}

// MARK: - OIDC

/// Persisted across app launches (Keychain-backed) so a re-login isn't
/// needed every session. `idToken`'s `sub` claim is the Skolengo user id.
struct SkolengoTokenSet: Sendable, Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenEndpoint: String
}

/// Minimal claims read out of the OIDC `id_token` JWT payload — just
/// enough to identify the logged-in Skolengo user without an extra
/// round trip. Signature is NOT verified: the token only ever leaves
/// the device as a bearer credential sent back to Skolengo's own API,
/// so a forged claim couldn't grant access to anything real.
struct SkolengoIDTokenClaims: Sendable {
    let sub: String
}

/// A user linked to the authenticated account — either the logged-in
/// user themselves (a student logging in directly) or, for a parent
/// account, one of their children.
struct SkolengoUserInfo: Sendable {
    let id: String
    let firstName: String
    let lastName: String
    let className: String?
    let schoolName: String?
}

// MARK: - School data

struct SkolengoGrade: Sendable {
    let id: String
    let date: Date
    let subject: String
    let rawValue: String
    let outOf: Double
    let coefficient: Double
    let classAverage: Double?
}

struct SkolengoLesson: Sendable {
    let id: String
    let start: Date
    let end: Date
    let subject: String
    let room: String?
    let teacher: String?
    let cancelled: Bool
}

struct SkolengoHomework: Sendable {
    let id: String
    let subject: String
    let description: String
    let dueDate: Date
    let done: Bool
}

struct SkolengoMessage: Sendable {
    let id: String
    let from: String
    let subject: String
    let date: Date
    let body: String
    let read: Bool
}

// MARK: - JSON:API envelope

/// Skolengo's EMS v2 API wraps every response in a JSON:API envelope:
/// `{ "data": [{ "id", "type", "attributes": {...} }, ...], "included": [...] }`.
/// This strips that envelope down to a flat array of `attributes` dicts
/// (with `id` merged in), which the rest of this file's tolerant
/// `compactMap`/`??` parsers consume — matching EcoleDirecteClient's
/// parsing style rather than a strict Codable/JSON:API deserializer.
enum SkolengoJSONAPI {
    /// Returns the `attributes` dict for every "data" resource (or just
    /// `data` itself if the server returned a single object, not an
    /// array), with `id` and `type` folded into the dict so callers
    /// don't need to track them separately.
    static func resources(from data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkolengoError.invalidResponse("format inattendu (racine non-objet)")
        }
        let rawItems: [[String: Any]]
        if let array = root["data"] as? [[String: Any]] {
            rawItems = array
        } else if let single = root["data"] as? [String: Any] {
            rawItems = [single]
        } else {
            return []
        }
        return rawItems.map { item in
            var flat = item["attributes"] as? [String: Any] ?? [:]
            flat["id"] = item["id"]
            flat["type"] = item["type"]
            return flat
        }
    }
}

// MARK: - Errors

enum SkolengoError: Error, LocalizedError {
    case badCredentials
    case tokenExpired
    case authCancelled
    case schoolNotFound
    case networkError(Error)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .badCredentials: "Identifiants Skolengo incorrects"
        case .tokenExpired: "Session Skolengo expirée"
        case .authCancelled: "Connexion annulée"
        case .schoolNotFound: "Établissement introuvable"
        case .networkError(let err): "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): "Réponse invalide: \(msg)"
        }
    }
}

// MARK: - JWT decoding

/// Decodes the `sub` claim from an OIDC `id_token` JWT without verifying
/// its signature (see `SkolengoIDTokenClaims` doc — safe in this context
/// since the token is only ever replayed back to Skolengo itself).
func skoDecodeIDTokenSub(_ idToken: String) -> String? {
    let parts = idToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var base64 = String(parts[1])
    base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sub = json["sub"] as? String else { return nil }
    return sub
}

// MARK: - Date / value helpers

/// Skolengo dates are ISO-8601 with an offset, e.g. "2026-04-16T08:00:00+02:00".
func skoParseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}

/// Same tolerant "mostly non-gradeable marker" filter as École Directe's
/// `parseGradeValue` — Skolengo's raw grade value shape is unconfirmed
/// against a real payload yet, so this stays permissive.
func skoParseGradeValue(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != "/" else { return nil }
    return Double(trimmed.replacingOccurrences(of: ",", with: "."))
}

func skoStripHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
