import Foundation

/// IMAP server configuration + credentials. Stored in Keychain.
/// Supersedes the MonLycée-hardcoded `IMAPCredentials` — the old struct
/// is kept as a typealias for the migration window (legacy Keychain
/// entries are decoded on read and re-serialised as `IMAPServerConfig`
/// on next save).
struct IMAPServerConfig: Codable, Sendable, Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String

    /// Provider identifier used for Keychain namespacing and UI labelling.
    /// Values: "gmail", "outlook", "icloud", "monlycee", "custom"
    let providerID: String

    /// Lightweight preset describing an IMAP server without credentials.
    /// Used by `IMAPProviderResolver` to return the server half of the
    /// config; the caller then attaches `username`/`password`.
    struct Preset: Sendable, Equatable {
        let host: String
        let port: Int
        let providerID: String
    }

    /// Convenience: build a full config from a preset + credentials.
    init(preset: Preset, username: String, password: String) {
        self.host = preset.host
        self.port = preset.port
        self.providerID = preset.providerID
        self.username = username
        self.password = password
    }

    init(host: String, port: Int, username: String, password: String, providerID: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.providerID = providerID
    }
}
