import Foundation

// MARK: - ENT Provider

enum ENTProvider: String, Codable, Sendable {
    case pcn  // Paris Classe Numérique
}

// MARK: - Conversation

struct ENTConversation: Sendable {
    let id: String
    let subject: String
    let from: String
    let date: Date
    let body: String?
    let unread: Bool
    let groupNames: [String]
}

// MARK: - Blog

struct ENTBlogPost: Sendable {
    let id: String
    let title: String
    let modified: Date
    let thumbnail: String?
}

// MARK: - Timeline

struct ENTTimelineNotification: Sendable {
    let id: String
    let type: String          // "MESSAGERIE", "BLOG", "SCHOOLBOOK"
    let message: String
    let date: Date
    let senderName: String?
    let wordId: String?       // Extracted from schoolbook resourceUri
}

// MARK: - Schoolbook

struct ENTSchoolbookWord: Sendable {
    let id: String
    let title: String
    let text: String
    let date: Date
    let ownerName: String
    let acknowledged: Bool
}

// MARK: - Homework

struct ENTHomework: Sendable {
    let id: String
    let subject: String
    let description: String
    let dueDate: Date
}

// MARK: - Child Info

struct ENTChildInfo: Sendable {
    let id: String
    let displayName: String
    let className: String
}

// MARK: - Errors

enum ENTError: Error, LocalizedError {
    case badCredentials
    case sessionExpired
    case networkError(Error)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .badCredentials: "Identifiants ENT incorrects"
        case .sessionExpired: "Session ENT expirée"
        case .networkError(let err): "Erreur réseau: \(err.localizedDescription)"
        case .invalidResponse(let msg): "Réponse invalide: \(msg)"
        }
    }
}
