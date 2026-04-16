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

    var description: String {
        "IMAPServerConfig(host: \(host), port: \(port), username: \(username), password: <redacted>, providerID: \(providerID))"
    }
}
