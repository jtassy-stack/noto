import Foundation

// MARK: - ENT Provider

enum ENTProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case pcn        // Paris Classe Numérique — élémentaire/collège Paris
    case monlycee   // MonLycée.net — lycées Île-de-France

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pcn: "Paris Classe Numérique"
        case .monlycee: "MonLycée.net"
        }
    }

    var subtitle: String {
        switch self {
        case .pcn: "Élémentaire, collège — Paris"
        case .monlycee: "Lycées — Île-de-France"
        }
    }

    var baseURL: URL {
        switch self {
        case .pcn: URL(string: "https://ent.parisclassenumerique.fr")!
        case .monlycee: URL(string: "https://psn.monlycee.net")!
        }
    }

    var color: String {
        switch self {
        case .pcn: "#E30613"
        case .monlycee: "#1B3A6B"
        }
    }

    var icon: String {
        switch self {
        case .pcn: "building.columns"
        case .monlycee: "graduationcap"
        }
    }

    /// MonLycée uses Zimbra for email, not the Conversation REST API
    var usesZimbraMail: Bool { self == .monlycee }
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

struct ENTBlogPostContent: Sendable {
    let id: String
    let blogId: String
    let title: String
    let author: String?
    let date: Date
    let imagePaths: [String]   // /workspace/document/<id> paths extracted from HTML
}

// MARK: - Photo attachment (blog or schoolbook)

struct ENTPhotoAttachment: Sendable {
    let id: String             // workspace document id
    let path: String           // /workspace/document/<id>
    let title: String?         // blog post title or schoolbook word title
    let authorName: String?
    let date: Date
    let source: ENTPhotoSource
}

enum ENTPhotoSource: String, Codable, Sendable {
    case blog
    case schoolbook
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
