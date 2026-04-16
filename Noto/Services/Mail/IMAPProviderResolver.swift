import Foundation

/// Maps an email address to its IMAP server configuration.
///
/// Strategy (in order):
///   1. Known-provider table (Gmail, Outlook, iCloud, MonLycée, …)
///   2. Generic fallback: `imap.{domain}:993`, providerID = "custom"
///
/// MX SRV auto-discovery (RFC 6186) is intentionally NOT implemented
/// here — it requires async DNS resolution which pulls in Network.framework
/// complexity for marginal real-world gain given how few ISP-hosted IMAP
/// servers parents actually use. If a user hits a provider that needs
/// custom config, they can set it manually (future Settings feature).
enum IMAPProviderResolver {

    /// Return the server preset for `email`, or `nil` if the email is
    /// not in a valid `user@host.tld` shape.
    /// Domain matching is case-insensitive.
    static func resolve(email: String) -> IMAPServerConfig.Preset? {
        guard let domain = extractDomain(from: email) else { return nil }
        let lowered = domain.lowercased()

        if let match = knownProviders.first(where: { $0.domains.contains(lowered) }) {
            return IMAPServerConfig.Preset(
                host: match.host,
                port: match.port,
                providerID: match.providerID
            )
        }

        // Generic fallback — best effort for self-hosted or small ISPs.
        // Many providers expose IMAPS on imap.{domain} by convention.
        return IMAPServerConfig.Preset(
            host: "imap.\(lowered)",
            port: 993,
            providerID: "custom"
        )
    }

    // MARK: - Known providers

    private struct KnownProvider {
        let domains: Set<String>   // lowercased
        let host: String
        let port: Int
        let providerID: String
    }

    private static let knownProviders: [KnownProvider] = [
        KnownProvider(
            domains: ["gmail.com", "googlemail.com"],
            host: "imap.gmail.com",
            port: 993,
            providerID: "gmail"
        ),
        KnownProvider(
            domains: ["outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.fr", "hotmail.fr", "live.fr"],
            host: "outlook.office365.com",
            port: 993,
            providerID: "outlook"
        ),
        KnownProvider(
            domains: ["icloud.com", "me.com", "mac.com"],
            host: "imap.mail.me.com",
            port: 993,
            providerID: "icloud"
        ),
        KnownProvider(
            domains: ["monlycee.net"],
            host: "imaps.monlycee.net",
            port: 993,
            providerID: "monlycee"
        ),
    ]

    // MARK: - Helpers

    /// Returns the domain portion of a `user@domain` string, or nil if
    /// the input is not a syntactically plausible email.
    private static func extractDomain(from email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return nil }
        let domain = trimmed[trimmed.index(after: atIndex)...]
        // Must look like a domain (at least one dot, no spaces, non-empty
        // local part).
        guard !domain.isEmpty,
              domain.contains("."),
              atIndex != trimmed.startIndex else { return nil }
        return String(domain)
    }
}
