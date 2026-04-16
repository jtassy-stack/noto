import Foundation

/// Entry in the mail whitelist — matches a domain or an exact email.
struct MailWhitelistEntry: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case schoolDomain        // auto — derived from child.establishment (Pronote URL, ENT host)
        case entProvider         // auto — matched via ENTRegistry from the school's establishment
        case teacherFromPronote  // auto — derived from child.messages.map(\.sender)
        case manual              // added by parent in Settings
    }

    let id: UUID
    let pattern: String          // domain ("monlycee.net") or exact email ("prof@school.fr")
    let source: Source
    let addedAt: Date

    init(id: UUID = UUID(), pattern: String, source: Source, addedAt: Date = .now) {
        self.id = id
        self.pattern = pattern.lowercased()
        self.source = source
        self.addedAt = addedAt
    }

    var isDomainPattern: Bool { !pattern.contains("@") }
}

/// Builds a whitelist of "trusted" mail senders for a set of children.
///
/// Three input sources, merged and deduplicated by pattern:
///   1. School domain — extracted from each child's `establishment`
///      field. When the establishment is a Pronote URL
///      (`*.index-education.net`), we take the registrable domain
///      (`index-education.net`). When it's a plain string, we try to
///      find a domain-shaped token inside it.
///   2. Teacher emails — senders of `child.messages` that look like
///      email addresses. These are pinned as exact-email entries so
///      personal mail from the same domain isn't accidentally let in.
///   3. Manual entries — parent-added via Settings, persisted in
///      Keychain under `mail_whitelist_manual`.
enum MailWhitelist {

    static let manualKeychainKey = "mail_whitelist_manual"

    /// Full whitelist = auto-detected (from children) + manual entries.
    static func build(from children: [Child]) -> [MailWhitelistEntry] {
        var entries: [MailWhitelistEntry] = []
        var seen = Set<String>()

        func add(_ entry: MailWhitelistEntry) {
            guard !seen.contains(entry.pattern), !entry.pattern.isEmpty else { return }
            seen.insert(entry.pattern)
            entries.append(entry)
        }

        for child in children {
            if let domain = schoolDomain(from: child.establishment) {
                add(MailWhitelistEntry(pattern: domain, source: .schoolDomain))
            }
            // ENT registry match: if the establishment's host matches a
            // known ENT, add every domain that ENT is known to use so
            // emails routed via the platform's subdomains pass too.
            if let ent = ENTRegistry.match(domain: child.establishment) {
                for entDomain in ent.domains {
                    add(MailWhitelistEntry(pattern: entDomain, source: .entProvider))
                }
            }
            for message in child.messages {
                if let email = extractEmail(from: message.sender) {
                    add(MailWhitelistEntry(pattern: email, source: .teacherFromPronote))
                }
            }
        }

        for manual in loadManual() {
            add(manual)
        }

        return entries
    }

    // MARK: - Manual entries (Keychain persistence)

    static func loadManual() -> [MailWhitelistEntry] {
        guard let data = try? KeychainService.load(key: manualKeychainKey),
              let entries = try? JSONDecoder().decode([MailWhitelistEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func saveManual(_ entries: [MailWhitelistEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try KeychainService.save(key: manualKeychainKey, data: data)
    }

    static func addManual(_ pattern: String) throws {
        let normalised = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalised.isEmpty, normalised.contains(".") else {
            throw MailWhitelistError.invalidPattern
        }
        var manual = loadManual()
        if !manual.contains(where: { $0.pattern == normalised }) {
            manual.append(MailWhitelistEntry(pattern: normalised, source: .manual))
            try saveManual(manual)
        }
    }

    static func removeManual(id: UUID) throws {
        var manual = loadManual()
        manual.removeAll { $0.id == id }
        try saveManual(manual)
    }

    // MARK: - Helpers (exposed for testing)

    /// Extract the registrable domain from an establishment string.
    /// Handles:
    ///   - Plain URL: `"https://XXXXX.index-education.net/pronote"` → `"index-education.net"`
    ///   - Bare domain: `"monlycee.net"` → `"monlycee.net"`
    ///   - Free-form label: returns nil (no domain to extract)
    static func schoolDomain(from establishment: String) -> String? {
        let trimmed = establishment.trimmingCharacters(in: .whitespaces)

        // URL case
        if let url = URL(string: trimmed), let host = url.host {
            return registrableDomain(from: host)
        }

        // Bare domain case
        let candidate = trimmed.lowercased()
        if candidate.contains("."), !candidate.contains(" ") {
            return registrableDomain(from: candidate)
        }

        return nil
    }

    /// Keep only the last two DNS labels (e.g., `foo.bar.example.com` →
    /// `example.com`). This is a best-effort approximation — the
    /// proper public-suffix-list approach is overkill for French
    /// school domains which mostly end in `.net` / `.fr`.
    private static func registrableDomain(from host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return host.lowercased() }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Extract an email address from a raw sender field.
    /// Accepts: `"Name" <email@domain>`, `Name <email@domain>`, `email@domain`.
    /// Returns nil if no email is present.
    static func extractEmail(from sender: String) -> String? {
        // RFC 5322 "Display Name" <email@domain>
        if let lt = sender.firstIndex(of: "<"),
           let gt = sender.firstIndex(of: ">"),
           lt < gt {
            let inside = sender[sender.index(after: lt)..<gt]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return inside.contains("@") && inside.contains(".") ? inside : nil
        }
        // Bare email
        let candidate = sender.trimmingCharacters(in: .whitespaces).lowercased()
        if candidate.contains("@"), candidate.contains(".") {
            return candidate
        }
        return nil
    }
}

enum MailWhitelistError: LocalizedError {
    case invalidPattern

    var errorDescription: String? {
        switch self {
        case .invalidPattern:
            return "Format invalide. Entrez un domaine (ex. ecole.fr) ou une adresse e-mail."
        }
    }
}
