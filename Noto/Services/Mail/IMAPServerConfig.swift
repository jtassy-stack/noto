import Foundation

/// IMAP server configuration + credentials.
///
/// The whole struct is JSON-encoded into a single Keychain blob under
/// `IMAPService.keychainKey`. The `password` field is plaintext inside
/// that blob — the privacy guarantee comes from the Keychain itself,
/// not from the struct's representation. `CustomStringConvertible` is
/// overridden to redact the password so any accidental `print(config)`
/// or `os_log("\(config)")` cannot leak it to the unified log.
struct IMAPServerConfig: Codable, Sendable, Equatable, CustomStringConvertible {
    /// Stable per-account identity used for Keychain keying, dedup, and disconnect.
    /// Optional in the Codable payload so blobs written before multi-account
    /// support decode without error — a fresh UUID is assigned on decode.
    let id: UUID
    let host: String
    let port: Int
    let username: String
    let password: String

    /// Provider identifier used for Keychain namespacing and UI labelling.
    /// The canonical list lives in `IMAPProviderResolver`; values are
    /// lowercase and produced exclusively by that resolver.
    let providerID: String

    /// True when the IMAP account is a school-provisioned mailbox where
    /// every message is by definition a school-parent communication.
    /// Personal email never transits here — it is a closed channel
    /// issued by the ENT.
    ///
    /// When true, callers MUST skip whitelist filtering: every fetched
    /// message is kept and presented as school content, and the UI must
    /// frame the mailbox as a dedicated channel rather than a generic
    /// inbox being filtered.
    var isDedicatedSchoolChannel: Bool {
        Self.isDedicatedSchoolChannel(providerID: providerID)
    }

    /// Provider IDs whose mailbox is inherently a school-parent channel.
    /// Extend here — and only here — when another ENT (e-Lyco,
    /// Educ'Horus, ENT77, …) exposes IMAP.
    private static let dedicatedSchoolChannelIDs: Set<String> = [
        "monlycee",
    ]

    /// Shared rule so `Preset` (setup-time, no credentials) and full
    /// config (post-auth) answer the same question.
    static func isDedicatedSchoolChannel(providerID: String) -> Bool {
        dedicatedSchoolChannelIDs.contains(providerID)
    }

    /// Lightweight preset describing an IMAP server without credentials.
    /// Used by `IMAPProviderResolver` to return the server half of the
    /// config; the caller then attaches `username`/`password`.
    struct Preset: Sendable, Equatable {
        let host: String
        let port: Int
        let providerID: String

        var isDedicatedSchoolChannel: Bool {
            IMAPServerConfig.isDedicatedSchoolChannel(providerID: providerID)
        }
    }

    /// Convenience: build a full config from a preset + credentials.
    init(preset: Preset, username: String, password: String, id: UUID = UUID()) {
        self.id = id
        self.host = preset.host
        self.port = preset.port
        self.providerID = preset.providerID
        self.username = username
        self.password = password
    }

    init(host: String, port: Int, username: String, password: String, providerID: String, id: UUID = UUID()) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.providerID = providerID
    }

    // MARK: - Codable (backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, host, port, username, password, providerID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        host       = try c.decode(String.self, forKey: .host)
        port       = try c.decode(Int.self, forKey: .port)
        username   = try c.decode(String.self, forKey: .username)
        password   = try c.decode(String.self, forKey: .password)
        providerID = try c.decode(String.self, forKey: .providerID)
    }

    /// Human-readable provider label shown in Settings.
    var providerDisplayName: String {
        switch providerID {
        case "gmail":    return "Gmail"
        case "outlook":  return "Outlook / Hotmail"
        case "icloud":   return "iCloud Mail"
        case "monlycee": return "MonLycée.net"
        default:         return host
        }
    }

    var description: String {
        "IMAPServerConfig(host: \(host), port: \(port), username: \(username), password: <redacted>, providerID: \(providerID))"
    }
}
