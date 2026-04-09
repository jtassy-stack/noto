import Foundation
import SwiftMail

/// Credentials for MonLycée IMAP — stored in Keychain.
struct IMAPCredentials: Codable, Sendable {
    let email: String
    let password: String
}

/// Lightweight model for a fetched IMAP message.
struct IMAPMessageInfo: Sendable {
    let uid: UInt32?
    let subject: String
    let from: String
    let date: Date
    let body: String
    let isRead: Bool
}

/// Connects to imaps.monlycee.net and fetches inbox messages.
/// Credentials are stored in Keychain — never on a server.
enum IMAPService {
    static let keychainKey = "imap_credentials_monlycee"
    private static let host = "imaps.monlycee.net"
    private static let port = 993

    // MARK: - Keychain

    static func saveCredentials(_ creds: IMAPCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        try KeychainService.save(key: keychainKey, data: data)
    }

    static func loadCredentials() -> IMAPCredentials? {
        guard let data = try? KeychainService.load(key: keychainKey),
              let creds = try? JSONDecoder().decode(IMAPCredentials.self, from: data) else { return nil }
        return creds
    }

    static func clearCredentials() {
        KeychainService.delete(key: keychainKey)
    }

    // MARK: - Fetch

    /// Validate credentials by connecting and logging in — throws on failure.
    static func validate(credentials: IMAPCredentials) async throws {
        let server = IMAPServer(host: host, port: port)
        try await server.connect()
        try await server.login(username: credentials.email, password: credentials.password)
        try await server.logout()
    }

    /// Fetch the latest `limit` messages from INBOX.
    static func fetchInbox(credentials: IMAPCredentials, limit: Int = 50) async throws -> [IMAPMessageInfo] {
        let server = IMAPServer(host: host, port: port)
        try await server.connect()
        defer { Task { try? await server.disconnect() } }

        try await server.login(username: credentials.email, password: credentials.password)
        let selection = try await server.selectMailbox("INBOX")

        guard let seqSet = selection.latest(limit) else { return [] }

        var messages: [IMAPMessageInfo] = []
        for try await msg in server.fetchMessages(using: seqSet) {
            let rawText = msg.textBody.map { cleanBody($0) }
            let rawHTML = msg.htmlBody.map { stripHTML($0) }
            let body = (rawText?.isEmpty == false ? rawText : nil) ?? rawHTML ?? ""
            messages.append(IMAPMessageInfo(
                uid: msg.uid?.value,
                subject: msg.subject ?? "(sans objet)",
                from: extractDisplayName(msg.from ?? "?"),
                date: msg.date ?? .now,
                body: body,
                isRead: msg.flags.contains(.seen)
            ))
        }
        // Newest first
        return messages.sorted { $0.date > $1.date }
    }

    /// Extract display name from RFC 5322 address: `"Name" <email>` → `"Name"`, else return as-is.
    private static func extractDisplayName(_ address: String) -> String {
        // Match: "Display Name" <email@domain> or Display Name <email@domain>
        if let ltRange = address.range(of: "<") {
            let name = address[address.startIndex..<ltRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? address : name
        }
        return address
    }

    /// Strip zero-width/invisible characters and whitespace; returns nil if effectively empty.
    private static func cleanBody(_ text: String) -> String {
        // Remove zero-width characters (ZWNJ U+200C, ZWJ U+200D, BOM U+FEFF, etc.)
        let cleaned = text
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
