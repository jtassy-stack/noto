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

struct PronoteRefreshToken: Codable, Sendable {
    let url: String
    let token: String
    let username: String
    let kind: PronoteAccountKind
}

// MARK: - Errors

enum PronoteError: Error, LocalizedError {
    case badCredentials
    case sessionExpired
    case accessDenied
    case suspendedIP
    case rateLimited
    case securityModal
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
        case .encryptionFailed(let msg): "Erreur de chiffrement: \(msg)"
        case .networkError(let err): "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): "Réponse invalide: \(msg)"
        case .tabNotAuthorized(let tab): "Accès non autorisé à l'onglet \(tab)"
        }
    }
}
