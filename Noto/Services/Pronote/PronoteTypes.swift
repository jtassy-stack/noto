import Foundation

// MARK: - Account

enum PronoteAccountKind: Int, Codable, Sendable {
    case student = 6
    case parent = 7
    case teacher = 8

    var path: String {
        switch self {
        case .student: "eleve"
        case .parent: "parent"
        case .teacher: "professeur"
        }
    }
}

// MARK: - Tab Locations

enum PronoteTab: Int, Sendable {
    case timetable = 16
    case presence = 7
    case news = 8
    case menus = 10
    case notebook = 19
    case assignments = 88
    case resources = 89
    case discussions = 131
    case grades = 198
    case evaluations = 201
}

// MARK: - Grade

enum PronoteGradeKind: Int, Codable, Sendable {
    case grade = 0
    case absent = 1
    case exempted = 2
    case notGraded = 3
}

struct PronoteGrade: Sendable {
    let id: String
    let subjectName: String
    let value: Double?
    let kind: PronoteGradeKind
    let outOf: Double
    let coefficient: Double
    let date: Date
    let chapter: String?
    let comment: String?
    let classAverage: Double?
    let classMin: Double?
    let classMax: Double?
}

// MARK: - Timetable

struct PronoteLesson: Sendable {
    let id: String
    let subject: String?
    let startDate: Date
    let endDate: Date
    let cancelled: Bool
    let status: String?
    let teacherNames: [String]
    let classrooms: [String]
    let isTest: Bool
    /// Pronote cahier de textes resource id of the lesson (`cahierDeTextes.N`),
    /// for joining with `PronoteLessonContentEntry.id` later. Unused yet.
    var lessonResourceID: String? = nil
}

// MARK: - Assignment

enum PronoteAssignmentDifficulty: Int, Codable, Sendable {
    case none = 0
    case easy = 1
    case medium = 2
    case hard = 3
}

struct PronoteAssignment: Sendable {
    let id: String
    let subjectName: String
    let description: String
    let deadline: Date
    let done: Bool
    let difficulty: PronoteAssignmentDifficulty
    let themes: [String]
    /// Cahier de textes resource the homework was set in (`cahierDeTextes.N`).
    /// Join key only; nothing depends on it yet.
    var resourceID: String? = nil
}

// MARK: - Lesson contents (cahier de textes, onglet 89)

/// One cahier de textes entry as returned by `PawnoteBridge.fetchLessonContents`
/// (hand-patched in `pawnote-bundle.js`). Every field is optional: the raw
/// Pronote shape (`ListeCahierDeTextes` / `listeContenus` / `descriptif` /
/// `ListeThemes`) has not been checked on a live parent account yet.
/// The text stays on the device (`LessonContent`).
struct PronoteLessonContentEntry: Decodable, Sendable, Equatable {
    let id: String?
    let subject: String?
    let startDate: String?
    let endDate: String?
    let contents: [Item]?

    struct Item: Decodable, Sendable, Equatable {
        let id: String?
        let title: String?
        let description: String?
        let categoryLabel: String?
        let themes: [String]?
    }
}

/// Wrapper returned by the JS side: the entries plus the raw key names of the
/// first response entry / content (keys only, never values) for the DEBUG
/// shape check.
struct PronoteLessonContentsPayload: Decodable, Sendable {
    let entries: [PronoteLessonContentEntry]?
    let rawKeys: [String]?
    let rawEntryKeys: [String]?
    let rawContentKeys: [String]?
}

// MARK: - Discussion

struct PronoteDiscussion: Sendable {
    let participantsMessageID: String
    let subject: String
    let creator: String?
    let date: Date
    let unreadCount: Int
}

struct PronoteMessage: Sendable {
    let id: String
    let content: String
    let date: Date
    let sender: String
}

// MARK: - Session Info

struct PronoteInstanceInfo: Sendable {
    let version: [Int]
    let name: String
    let casURL: String?
}

/// What nōto keeps to reopen a Pronote session without a new QR scan.
/// `kind` and `navigatorIdentifier` come back from pawnote on every login
/// and must be replayed as-is: Pronote keys the mobile token on the account
/// space (élève / parent) and on the `identifiantNav` it handed out, so a
/// token replayed as « parent » for a student QR, or with a fresh navigator
/// id, is refused. `navigatorIdentifier` is optional so tokens stored by
/// earlier builds (which dropped it) still decode; they get a value on
/// their first successful reconnect.
struct PronoteRefreshToken: Codable, Sendable, Equatable {
    let url: String
    let token: String
    let username: String
    let kind: PronoteAccountKind
    var navigatorIdentifier: String? = nil
}

// MARK: - Errors

enum PronoteError: Error, LocalizedError {
    case badCredentials
    case sessionExpired
    case accessDenied
    case suspendedIP
    case rateLimited
    case securityModal
    /// Pronote asks the account to set up double authentication (PIN /
    /// trusted device) before it hands out a mobile token. pawnote's token
    /// login throws on it; the parent has to go through the Pronote app or
    /// web once, then rescan.
    case doubleAuthRequired
    case encryptionFailed(String)
    case networkError(Error)
    case invalidResponse(String)
    case tabNotAuthorized(PronoteTab)

    var errorDescription: String? {
        switch self {
        case .badCredentials: "Identifiants incorrects"
        case .sessionExpired: "Session expirée"
        case .accessDenied: "Accès refusé"
        case .suspendedIP: "Adresse IP temporairement bloquée"
        case .rateLimited: "Trop de requêtes, réessayez dans quelques minutes"
        case .securityModal: "Vérification de sécurité requise — connectez-vous depuis Pronote"
        case .doubleAuthRequired: "Pronote demande une double authentification. Connectez-vous une fois dans l'app ou sur le site Pronote, puis rescannez le QR code."
        case .encryptionFailed(let msg): "Erreur de chiffrement: \(msg)"
        case .networkError(let err): "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): "Réponse invalide: \(msg)"
        case .tabNotAuthorized(let tab): "Accès non autorisé à l'onglet \(tab)"
        }
    }
}
