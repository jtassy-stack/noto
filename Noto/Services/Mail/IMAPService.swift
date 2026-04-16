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
/// Credentials are stored in Keychain as a JSON-encoded `IMAPServerConfig`.
/// On first read after upgrading from the pre-Phase-7 MonLycée-hardcoded
/// release, `loadConfig()` transparently hydrates the legacy
/// `imap_credentials_monlycee` blob into an `IMAPServerConfig` so existing
/// users don't need to re-auth.
enum IMAPService {

    // MARK: - Keychain keys

    /// Legacy key — MonLycée only, pre-Phase-7 install base.
    /// Read-only after Phase 7: writes go to `keychainKey` and the
    /// legacy blob is cleaned up on first successful `saveConfig`.
    static let legacyMonLyceeKey = "imap_credentials_monlycee"

    /// Current key for the configured mailbox (single account per device).
    static let keychainKey = "imap_config_v2"

    // MARK: - Config persistence

    static func saveConfig(_ config: IMAPServerConfig) throws {
        let data = try JSONEncoder().encode(config)
        try KeychainService.save(key: keychainKey, data: data)
        // Best-effort legacy cleanup — failure here doesn't compromise
        // the save we just committed.
        try? KeychainService.delete(key: legacyMonLyceeKey)
    }

    static func loadConfig() -> IMAPServerConfig? {
        let primary = try? KeychainService.load(key: keychainKey)
        let legacy = try? KeychainService.load(key: legacyMonLyceeKey)
        return decodeConfig(primaryData: primary, legacyData: legacy)
    }

    /// Pure decode path — factored out of `loadConfig` so the
    /// hydration logic can be unit-tested without a Keychain seam.
    /// Tries the primary v2 blob first, then the legacy MonLycée
    /// blob. Returns nil if neither decodes successfully.
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

    static func clearConfig() throws {
        try KeychainService.delete(key: keychainKey)
        try KeychainService.delete(key: legacyMonLyceeKey)
    }

    /// Convenience — true when a mailbox is configured.
    /// All UI call sites (SettingsView, SchoolView, ActualitesView,
    /// OnboardingView) use this instead of direct Keychain reads so
    /// the legacy-hydration path in `loadConfig` stays authoritative.
    static var isConfigured: Bool {
        loadConfig() != nil
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
