import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "ENTRegistry")

/// An ENT provider entry (bundled or fetched).
/// Shape matches `celyn.io/api/directory/ents` response so the same
/// decoder works for both paths.
struct DirectoryENTProvider: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let domains: [String]
    let regions: [String]?
    let imapHost: String?
    let imapPort: Int?
    let authMethod: String?
}

/// Bundled offline registry of French ENT platforms, loaded once at
/// first access from `Noto/Resources/directory/ents.json`.
///
/// Used to widen the mail whitelist when the child's school is known
/// to run on a specific ENT (e.g., a Paris child → add
/// `parisclassenumerique.fr` to the whitelist).
///
/// Fallback strategy: bundled stays authoritative offline; once
/// `DirectoryAPIClient` is wired to celyn, a background refresh can
/// overwrite the cache with a live copy.
enum ENTRegistry {

    // MARK: - Bundled load

    /// Cached at first access so repeated lookups don't re-read the bundle.
    static let bundledENTs: [DirectoryENTProvider] = loadBundled()

    private static func loadBundled() -> [DirectoryENTProvider] {
        guard let url = Bundle.main.url(forResource: "ents", withExtension: "json", subdirectory: "directory")
            ?? Bundle.main.url(forResource: "ents", withExtension: "json")
        else {
            logger.warning("ENTRegistry: bundled ents.json not found — whitelist augmentation disabled")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.ents
        } catch {
            logger.error("ENTRegistry: failed to decode ents.json — \(String(describing: error))")
            return []
        }
    }

    private struct Payload: Codable {
        let version: Int?
        let ents: [DirectoryENTProvider]
    }

    // MARK: - Lookup

    /// Case-insensitive match from a domain (URL or bare) to an ENT
    /// provider. Accepts "https://xxx.monlycee.net/path" or just
    /// "monlycee.net". Checks both exact domain match and registrable
    /// suffix match (e.g., "xyz.monlycee.net" matches "monlycee.net").
    static func match(domain: String) -> DirectoryENTProvider? {
        guard let needle = extractHost(from: domain)?.lowercased() else { return nil }
        for ent in bundledENTs {
            for d in ent.domains {
                let pattern = d.lowercased()
                if needle == pattern || needle.hasSuffix("." + pattern) {
                    return ent
                }
            }
        }
        return nil
    }

    /// Flattened list of every email domain across every bundled ENT.
    /// Consumed by `MailWhitelist` when building the whitelist for a
    /// child whose establishment matches a known ENT.
    static let allMailDomains: [String] = {
        bundledENTs.flatMap(\.domains).map { $0.lowercased() }
    }()

    // MARK: - Helpers

    /// Extract the hostname from a URL-shaped string or return the
    /// input trimmed if it's already a bare domain. Returns nil when
    /// the input has no recognisable domain component.
    static func extractHost(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // URL-shaped: parse host
        if let url = URL(string: trimmed), let host = url.host, host.contains(".") {
            return host
        }

        // Bare domain: must contain a dot, no spaces
        if trimmed.contains("."), !trimmed.contains(" ") {
            return trimmed
        }

        return nil
    }
}
