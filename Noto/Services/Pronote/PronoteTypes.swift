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

/// What Pronote answered when it refused to open the session until the
/// account sets up its double authentication (`actionsDoubleAuth`). pawnote
/// throws there, but the answer already carries the renewed single-use
/// mobile token: keeping it means the account survives the refusal instead
/// of needing a new QR scan once the parent has done the setup in Pronote.
/// Decoded from the JSON the bridge appends to `DOUBLE_AUTH_REQUIRED:`.
struct PronoteDoubleAuth: Codable, Sendable, Equatable {
    var token: String? = nil
    var username: String? = nil
    var url: String? = nil
    var kind: Int? = nil
    var navigatorIdentifier: String? = nil
    var needsPIN: Bool = false
    var needsChoice: Bool = false
    var needsPassword: Bool = false

    init(token: String? = nil, username: String? = nil, url: String? = nil, kind: Int? = nil,
         navigatorIdentifier: String? = nil, needsPIN: Bool = false, needsChoice: Bool = false,
         needsPassword: Bool = false) {
        self.token = token
        self.username = username
        self.url = url
        self.kind = kind
        self.navigatorIdentifier = navigatorIdentifier
        self.needsPIN = needsPIN
        self.needsChoice = needsChoice
        self.needsPassword = needsPassword
    }

    /// Every key is optional on the wire: a bridge build that omits a flag
    /// must not turn the whole payload (and its token) into nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        kind = try c.decodeIfPresent(Int.self, forKey: .kind)
        navigatorIdentifier = try c.decodeIfPresent(String.self, forKey: .navigatorIdentifier)
        needsPIN = try c.decodeIfPresent(Bool.self, forKey: .needsPIN) ?? false
        needsChoice = try c.decodeIfPresent(Bool.self, forKey: .needsChoice) ?? false
        needsPassword = try c.decodeIfPresent(Bool.self, forKey: .needsPassword) ?? false
    }

    /// The renewed token, when Pronote sent one we can store.
    var rescuedToken: PronoteRefreshToken? {
        guard let token, !token.isEmpty, let username, !username.isEmpty,
              let url, !url.isEmpty else { return nil }
        return PronoteRefreshToken(
            url: url,
            token: token,
            username: username,
            kind: kind.flatMap(PronoteAccountKind.init(rawValue:)) ?? .parent,
            navigatorIdentifier: (navigatorIdentifier?.isEmpty == false) ? navigatorIdentifier : nil
        )
    }

    /// What the parent has to do in Pronote, in their words.
    var instruction: String {
        if needsPIN {
            return "Pronote demande de choisir un code PIN pour cette application."
        }
        if needsChoice {
            return "Pronote demande de choisir une méthode de double authentification pour ce compte."
        }
        if needsPassword {
            return "Pronote demande de changer le mot de passe de ce compte."
        }
        return "Pronote demande de configurer la double authentification de ce compte."
    }
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
    /// trusted device) before it opens the session. pawnote throws on it;
    /// the parent has to go through the Pronote app or web once. The payload
    /// (nil when the bridge could not read Pronote's answer) carries the
    /// renewed token so the account is kept and a retry needs no QR scan.
    case doubleAuthRequired(PronoteDoubleAuth?)
    case encryptionFailed(String)
    case networkError(Error)
    case invalidResponse(String)
    case tabNotAuthorized(PronoteTab)

    var errorDescription: String? {
        switch self {
        case .badCredentials: return "Identifiants incorrects"
        case .sessionExpired: return "Session expirée"
        case .accessDenied: return "Accès refusé"
        case .suspendedIP: return "Adresse IP temporairement bloquée"
        case .rateLimited: return "Trop de requêtes, réessayez dans quelques minutes"
        case .securityModal: return "Vérification de sécurité requise — connectez-vous depuis Pronote"
        case .doubleAuthRequired(let info):
            let what = info?.instruction ?? "Pronote demande une double authentification pour ce compte."
            let how = info?.rescuedToken != nil
                ? "Faites-le une fois dans l'app ou sur le site Pronote, puis touchez « Réessayer » dans nōto."
                : "Faites-le une fois dans l'app ou sur le site Pronote, puis rescannez le QR code."
            return what + " " + how
        case .encryptionFailed(let msg): return "Erreur de chiffrement: \(msg)"
        case .networkError(let err): return "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): return "Réponse invalide: \(msg)"
        case .tabNotAuthorized(let tab): return "Accès non autorisé à l'onglet \(tab)"
        }
    }
}
