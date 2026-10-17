import Foundation

// MARK: - Auth

struct EDLoginResponse: Sendable {
    let token: String
    let accounts: [EDAccount]
}

struct EDAccount: Sendable {
    let id: Int
    let displayName: String         // "Nom Prénom"
    let eleves: [EDEleve]
}

struct EDEleve: Sendable {
    let id: Int
    let firstName: String
    let lastName: String
    let grade: String               // classe libellé e.g. "3ème A"
    let establishmentName: String
}

// MARK: - School data

struct EDGrade: Sendable {
    let id: String
    let date: Date
    let subject: String
    let rawValue: String            // French decimal string or "Abs"/"Disp"/"NE"
    let outOf: Double
    let coefficient: Double
    let classAverage: Double?
}

struct EDLesson: Sendable {
    let id: String
    let date: Date
    let startTime: String           // "HH:MM"
    let endTime: String
    let subject: String
    let room: String?
    let teacher: String?
    let cancelled: Bool
}

struct EDHomework: Sendable {
    let id: String
    let subject: String
    let description: String         // HTML-stripped
    let dueDate: Date
}

/// One subject of one cahier de textes day (3.8). Local only.
struct EDSeance: Sendable, Equatable {
    let id: String
    let subject: String
    let date: Date
    /// `contenuDeSeance.contenu`, base64-decoded, HTML stripped.
    let seanceText: String
    /// `aFaire.contenu`, same treatment; nil when there is none.
    let homeworkText: String?
}

struct EDMessage: Sendable {
    let id: Int
    let from: String
    let subject: String
    let date: Date
    let body: String                // base64-decoded, HTML-stripped
    let read: Bool
}

// MARK: - Grade value parser

/// Returns the raw parsed numeric value without normalizing to /20.
/// Normalization is handled by `Grade.normalizedValue` which keeps the original outOf.
/// Returns nil for non-gradeable markers ("Abs", "Disp", "NE", "Inf", "Exc", "/") or invalid input.
func parseGradeValue(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          trimmed != "/",
          !["Abs", "Disp", "NE", "Inf", "Exc"].contains(trimmed) else { return nil }
    return Double(trimmed.replacingOccurrences(of: ",", with: "."))
}

// MARK: - Errors

enum EcoleDirecteError: Error, LocalizedError {
    case badCredentials
    case accountBlocked
    case tokenExpired
    case networkError(Error)
    case invalidResponse(String)
    case noAccountFound

    var errorDescription: String? {
        switch self {
        case .badCredentials: "Identifiants École Directe incorrects"
        case .accountBlocked: "Compte École Directe bloqué"
        case .tokenExpired: "Session École Directe expirée"
        case .networkError(let err): "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): "Réponse invalide: \(msg)"
        case .noAccountFound: "Aucun compte trouvé"
        }
    }
}

// MARK: - Date / HTML helpers

/// Parses ED date strings (always French school-year dates in Europe/Paris timezone).
/// Uses en_US_POSIX locale to guarantee Gregorian calendar on all device locales.
func edParseDate(_ string: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "dd/MM/yyyy"] {
        f.dateFormat = format
        if let d = f.date(from: string) { return d }
    }
    return nil
}

func edStripHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// École Directe base64-encodes rich text (messages, cahier de textes). Returns
/// the decoded UTF-8 string, or the input unchanged when it is not base64.
func edDecodeBase64HTML(_ raw: String) -> String {
    if let decoded = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
       let str = String(data: decoded, encoding: .utf8) {
        return str
    }
    return raw
}

/// `edStripHTML` that keeps word boundaries (tags become spaces), decodes the
/// common entities and collapses whitespace: `<p>a</p><p>b</p>` → "a b".
func edPlainText(_ html: String) -> String {
    var text = edStripHTML(html.replacingOccurrences(of: "<", with: " <"))
    for (entity, char) in [("&nbsp;", " "), ("&#39;", "'"), ("&apos;", "'"), ("&quot;", "\""),
                           ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
        text = text.replacingOccurrences(of: entity, with: char)
    }
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
