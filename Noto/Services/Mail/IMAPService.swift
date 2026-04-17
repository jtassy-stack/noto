import Foundation
import SwiftMail

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
/// Supports multiple simultaneous accounts (e.g. Gmail personal + MonLycée
/// school provisioned). Each account is stored by its `IMAPServerConfig.id`.
/// The list is JSON-encoded into a single Keychain blob under `accountsKey`.
///
/// Migration path (oldest → newest):
///   1. `legacyMonLyceeKey` — pre-Phase-7, MonLycée-only hardcoded creds
///   2. `keychainKey` (`imap_config_v2`) — Phase 7, single-account JSON blob
///   3. `accountsKey` (`imap_accounts_v3`) — current, array of accounts
///
/// `loadConfigs()` promotes the old blob into slot 0 on first read so
/// existing users don't re-authenticate after upgrading.
enum IMAPService {

    // MARK: - Keychain keys

    static let legacyMonLyceeKey = "imap_credentials_monlycee"
    static let keychainKey       = "imap_config_v2"
    static let accountsKey       = "imap_accounts_v3"

    static let configDidChangeNotification = Notification.Name("noto.imap.configDidChange")

    // MARK: - Multi-account persistence

    static func loadConfigs() -> [IMAPServerConfig] {
        // Try v3 array first
        if let data = try? KeychainService.load(key: accountsKey),
           let configs = try? JSONDecoder().decode([IMAPServerConfig].self, from: data),
           !configs.isEmpty {
            return configs
        }
        // Migrate from v2 single config
        if let single = migrateSingleConfig() {
            try? saveConfigs([single])
            return [single]
        }
        return []
    }

    static func saveConfigs(_ configs: [IMAPServerConfig]) throws {
        let data = try JSONEncoder().encode(configs)
        try KeychainService.save(key: accountsKey, data: data)
        NotificationCenter.default.post(name: configDidChangeNotification, object: nil)
    }

    static func addConfig(_ config: IMAPServerConfig) throws {
        var configs = loadConfigs()
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        try saveConfigs(configs)
    }

    static func removeConfig(id: UUID) throws {
        var configs = loadConfigs()
        configs.removeAll { $0.id == id }
        try saveConfigs(configs)
    }

    static func clearAllConfigs() throws {
        try? KeychainService.delete(key: accountsKey)
        try? KeychainService.delete(key: keychainKey)
        try? KeychainService.delete(key: legacyMonLyceeKey)
        NotificationCenter.default.post(name: configDidChangeNotification, object: nil)
    }

    static var isConfigured: Bool { !loadConfigs().isEmpty }

    // MARK: - Single-account shims (backward compat for call sites not yet migrated)

    static func loadConfig() -> IMAPServerConfig? { loadConfigs().first }

    static func saveConfig(_ config: IMAPServerConfig) throws {
        try addConfig(config)
    }

    static func clearConfig() throws {
        try clearAllConfigs()
    }

    // MARK: - Migration helpers

    private static func migrateSingleConfig() -> IMAPServerConfig? {
        let v2 = try? KeychainService.load(key: keychainKey)
        let legacy = try? KeychainService.load(key: legacyMonLyceeKey)
        return decodeConfig(primaryData: v2, legacyData: legacy)
    }

    /// Pure decode path exposed for unit tests.
    static func decodeConfig(primaryData: Data?, legacyData: Data?) -> IMAPServerConfig? {
        if let data = primaryData,
           let config = try? JSONDecoder().decode(IMAPServerConfig.self, from: data) {
            return config
        }
        if let data = legacyData,
           let legacy = try? JSONDecoder().decode(LegacyMonLyceeCredentials.self, from: data) {
            return IMAPServerConfig(
                host: "imaps.monlycee.net",
                port: 993,
                username: legacy.email,
                password: legacy.password,
                providerID: "monlycee"
            )
        }
        return nil
    }

    // MARK: - Fetch

    static func validate(config: IMAPServerConfig) async throws {
        let server = IMAPServer(host: config.host, port: config.port)
        try await server.connect()
        try await server.login(username: config.username, password: config.password)
        try await server.logout()
    }

    static func fetchInbox(config: IMAPServerConfig, limit: Int = 50) async throws -> [IMAPMessageInfo] {
        let server = IMAPServer(host: config.host, port: config.port)
        try await server.connect()
        defer {
            // Log disconnect failures rather than swallowing them — repeated
            // leaked connections have caused providers (Outlook especially)
            // to rate-limit LOGIN attempts.
            Task {
                do { try await server.disconnect() }
                catch { NSLog("[noto][warn] IMAP disconnect failed: \(String(describing: error))") }
            }
        }

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

// MARK: - Legacy migration struct (internal only)

/// Shape of the pre-Phase-7 Keychain payload under `imap_credentials_monlycee`.
/// Used exclusively by `decodeConfig` to read old entries and promote
/// them to `IMAPServerConfig`. Internal rather than private so unit
/// tests can round-trip JSON and assert the hydration path.
struct LegacyMonLyceeCredentials: Codable {
    let email: String
    let password: String
}
