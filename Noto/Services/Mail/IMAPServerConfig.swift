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

    /// Who this mailbox's mail belongs to — all children (default, the
    /// pre-assignment behaviour), one child, or the parent. Stored inside
    /// the same Keychain blob as the credentials; never leaves the device.
    /// `var` so Réglages > Boîte mail can re-assign an existing account.
    var assignment: MailboxAssignment

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
    init(
        preset: Preset,
        username: String,
        password: String,
        assignment: MailboxAssignment = .allChildren,
        id: UUID = UUID()
    ) {
        self.id = id
        self.host = preset.host
        self.port = preset.port
        self.providerID = preset.providerID
        self.username = username
        self.password = password
        self.assignment = assignment
    }

    init(
        host: String,
        port: Int,
        username: String,
        password: String,
        providerID: String,
        assignment: MailboxAssignment = .allChildren,
        id: UUID = UUID()
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.providerID = providerID
        self.assignment = assignment
    }

    // MARK: - Codable (backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, host, port, username, password, providerID, assignment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` returns nil only when the key is absent (legacy blob) —
        // unlike `try?` it would still throw on a malformed UUID value.
        id         = (try c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        host       = try c.decode(String.self, forKey: .host)
        port       = try c.decode(Int.self, forKey: .port)
        username   = try c.decode(String.self, forKey: .username)
        password   = try c.decode(String.self, forKey: .password)
        providerID = try c.decode(String.self, forKey: .providerID)
        // Blobs written before per-account assignment have no key → the
        // historical behaviour ("every child"). An unreadable value also
        // falls back rather than dropping the whole account (and its
        // password) from the Keychain list.
        assignment = (try? c.decodeIfPresent(MailboxAssignment.self, forKey: .assignment)) ?? .allChildren
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
        "IMAPServerConfig(host: \(host), port: \(port), username: \(username), password: <redacted>, providerID: \(providerID), assignment: \(assignment.kind))"
    }
}

// MARK: - Mailbox assignment

/// Who an IMAP account's mail belongs to (TestFlight feedback, build 230:
/// "décider à qui elle se rapporte (quel enfant, parent)").
///
/// - `allChildren`: historical behaviour — the inbox is replayed against
///   every child, each keeping what its own whitelist matches.
/// - `child(id:)`: only that child receives the mail. `id` is the string
///   form of the child's SwiftData `PersistentIdentifier` (`"\(child.id)"`),
///   the convention already used to persist a child reference
///   (`ScreenTimeEventStore.storeLinkedChildID`, `BriefingEngine`).
///   A dangling id (child deleted, store reset) resolves to `allChildren`.
/// - `parent`: mail addressed to the parent, not tied to one child. Stored
///   on `Family.messages` and shown in Actualités / Messages with a
///   "Parent" tag. Still filtered by the family-wide whitelist.
enum MailboxAssignment: Sendable, Hashable {
    case allChildren
    case child(id: String)
    case parent

    /// Log-safe discriminator — never the child id or name.
    var kind: String {
        switch self {
        case .allChildren: return "all"
        case .child: return "child"
        case .parent: return "parent"
        }
    }

    /// The assignment as it applies today: a `.child` whose id matches
    /// none of `childIDs` falls back to `.allChildren`.
    func resolved(childIDs: [String]) -> MailboxAssignment {
        if case .child(let id) = self, !childIDs.contains(id) {
            return .allChildren
        }
        return self
    }
}

extension MailboxAssignment: Codable {
    private enum CodingKeys: String, CodingKey { case kind, childID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "child":
            self = .child(id: try c.decode(String.self, forKey: .childID))
        case "parent":
            self = .parent
        default:
            // "all", and any kind a future build might add.
            self = .allChildren
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if case .child(let id) = self {
            try c.encode(id, forKey: .childID)
        }
    }
}
