import Foundation
import SwiftMail

/// Legacy credential struct — kept for backward compat while existing
/// MonLycée Keychain entries are migrated to `IMAPServerConfig`.
/// New code should use `IMAPServerConfig` directly.
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

/// Multi-provider IMAP client.
///
/// Credentials are stored in Keychain per-provider (one entry per
/// configured account). The primary API takes `IMAPServerConfig`
/// explicitly; legacy convenience helpers keep reading the old
/// MonLycée key for backward compat during the migration window.
enum IMAPService {

    // MARK: - Keychain keys

    /// Legacy key — MonLycée only, pre-Phase-7 install base.
    static let legacyMonLyceeKey = "imap_credentials_monlycee"
    /// Current key — single configured mailbox per device (we only
    /// support one mail account at a time for now; multi-account
    /// would expand this to per-provider keys).
    static let keychainKey = "imap_config_v2"

    // MARK: - Keychain — new API (IMAPServerConfig)

    static func saveConfig(_ config: IMAPServerConfig) throws {
        let data = try JSONEncoder().encode(config)
        try KeychainService.save(key: keychainKey, data: data)
        // Clean up legacy entry on successful save so users don't keep
        // two stale copies after migrating off MonLycée-hardcoded flow.
        KeychainService.delete(key: legacyMonLyceeKey)
    }

    static func loadConfig() -> IMAPServerConfig? {
        // Primary: new key
        if let data = try? KeychainService.load(key: keychainKey),
           let config = try? JSONDecoder().decode(IMAPServerConfig.self, from: data) {
            return config
        }
        // Backward compat: legacy MonLycée-only entry — hydrate to
        // IMAPServerConfig on the fly so existing installs keep working
        // without a forced re-auth.
        if let creds = loadCredentials() {
            return IMAPServerConfig(
                host: "imaps.monlycee.net",
                port: 993,
                username: creds.email,
                password: creds.password,
                providerID: "monlycee"
            )
        }
        return nil
    }

    static func clearConfig() {
        KeychainService.delete(key: keychainKey)
        KeychainService.delete(key: legacyMonLyceeKey)
    }

    // MARK: - Keychain — legacy API (kept for existing call sites)

    static func saveCredentials(_ creds: IMAPCredentials) throws {
        // Legacy path assumes MonLycée — upgrade to new key on save.
        let config = IMAPServerConfig(
            host: "imaps.monlycee.net",
            port: 993,
            username: creds.email,
            password: creds.password,
            providerID: "monlycee"
        )
        try saveConfig(config)
    }

    static func loadCredentials() -> IMAPCredentials? {
        guard let data = try? KeychainService.load(key: legacyMonLyceeKey),
              let creds = try? JSONDecoder().decode(IMAPCredentials.self, from: data) else { return nil }
        return creds
    }

    static func clearCredentials() {
        clearConfig()
    }

    // MARK: - Fetch (new API — takes full config)

    /// Validate by connecting + logging in. Throws on failure.
    static func validate(config: IMAPServerConfig) async throws {
        let server = IMAPServer(host: config.host, port: config.port)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        try await server.logout()
    }

    /// Fetch the latest `limit` messages from INBOX.
    static func fetchInbox(config: IMAPServerConfig, limit: Int = 50) async throws -> [IMAPMessageInfo] {
        let server = IMAPServer(host: config.host, port: config.port)
        try await server.connect()
        defer { Task { try? await server.disconnect() } }

        try await server.login(username: config.username, password: config.password)
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
        return messages.sorted { $0.date > $1.date }
    }

    // MARK: - Fetch (legacy wrappers — route to new API)

    static func validate(credentials: IMAPCredentials) async throws {
        let config = IMAPServerConfig(
            host: "imaps.monlycee.net",
            port: 993,
            username: credentials.email,
            password: credentials.password,
            providerID: "monlycee"
        )
        try await validate(config: config)
    }

    static func fetchInbox(credentials: IMAPCredentials, limit: Int = 50) async throws -> [IMAPMessageInfo] {
        let config = IMAPServerConfig(
            host: "imaps.monlycee.net",
            port: 993,
            username: credentials.email,
            password: credentials.password,
            providerID: "monlycee"
        )
        return try await fetchInbox(config: config, limit: limit)
    }

    // MARK: - Helpers

    private static func extractDisplayName(_ address: String) -> String {
        if let ltRange = address.range(of: "<") {
            let name = address[address.startIndex..<ltRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? address : name
        }
        return address
    }

    private static func cleanBody(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
