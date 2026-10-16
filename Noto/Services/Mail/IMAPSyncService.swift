import Foundation
import SwiftData

/// Syncs IMAP inbox messages into SwiftData Message objects.
///
/// Invariants:
///   - New inserts carry `source == .imap` and stamp `imapProvider`
///     with the active config's providerID.
///   - Dedupe primarily on `imapUID`, with a composite fallback on
///     `(sender, subject, day)` scoped to `.imap` / `.conversation` only
///     so Pronote and ENT messages can never be absorbed or re-sourced.
///   - Generic IMAP configs (Gmail, Outlook, …) filter inbound mail
///     through `MailFilter` against the whitelist — personal mail must
///     never land in the DB.
///   - Configs that report `isDedicatedSchoolChannel` (ENT-provisioned
///     mailboxes) skip the whitelist entirely: their inbox is by
///     construction a school-parent channel, and filtering would
///     silently drop legitimate senders outside the known school
///     domain.
///   - Each account's `MailboxAssignment` decides where its mail lands
///     (`MailboxRouting.target`): every child, one child, or the parent
///     lane (`Family.messages`, whitelist = union of the family's schools).
///
/// Threading contract
/// ------------------
/// `syncAccounts` runs on the main actor but hops the expensive network
/// I/O (`fetch`, `IMAPService.fetchInbox` in production) off it; only the
/// SwiftData writes in `process` touch the main actor.
struct IMAPSyncService {
    let modelContext: ModelContext

    /// Outcome of a multi-account sync. Errors carry the account username
    /// (the parent's own address, shown back to them) — never a child name.
    struct AccountsResult {
        var anySuccess = false
        var errors: [(account: String, detail: String)] = []
    }

    /// Fetches every account ONCE and replays it against the targets its
    /// assignment resolves to.
    ///
    /// - Parameters:
    ///   - children: every child of the family (explicit assignments are
    ///     matched here, regardless of school type).
    ///   - defaultChildren: who receives an `.allChildren` account; `nil`
    ///     means `children`.
    ///   - family: parent lane owner; parent-assigned accounts are skipped
    ///     when nil.
    ///   - fetch: injectable for tests — production uses `IMAPService.fetchInbox`.
    @MainActor
    func syncAccounts(
        _ configs: [IMAPServerConfig],
        children: [Child],
        defaultChildren: [Child]? = nil,
        family: Family?,
        directorySchools: [String: DirectorySchool] = [:],
        fetch: @escaping @Sendable (IMAPServerConfig) async throws -> [IMAPMessageInfo] = { config in
            try await Task.detached(priority: .userInitiated) {
                try await IMAPService.fetchInbox(config: config)
            }.value
        }
    ) async -> AccountsResult {
        var result = AccountsResult()

        for config in configs {
            let target = MailboxRouting.target(
                for: config.assignment,
                children: children,
                defaultChildren: defaultChildren,
                key: MailboxRouting.childKey
            )
            // Nothing to replay against — don't open a connection.
            if case .children(let kids) = target, kids.isEmpty { continue }
            if case .parent = target, family == nil { continue }

            let fetched: [IMAPMessageInfo]
            do {
                fetched = try await fetch(config)
            } catch {
                NSLog("[noto][error] IMAP fetch failed (provider=%@): %@",
                      config.providerID, error.localizedDescription)
                result.errors.append((config.username, error.localizedDescription))
                continue
            }

            switch target {
            case .children(let kids):
                for child in kids {
                    do {
                        try process(child: child, config: config, fetched: fetched, directorySchools: directorySchools)
                        result.anySuccess = true
                    } catch {
                        result.errors.append((config.username, error.localizedDescription))
                    }
                }
            case .parent:
                guard let family else { continue }
                do {
                    try process(family: family, config: config, fetched: fetched, directorySchools: directorySchools)
                    result.anySuccess = true
                } catch {
                    result.errors.append((config.username, error.localizedDescription))
                }
            }
        }
        return result
    }

    /// Pure processing step for one child — takes an already-fetched batch
    /// and applies whitelist filtering (or bypass), dedupe, and insert.
    ///
    /// - Parameter directorySchools: optional pre-fetched map of
    ///   `Child.rneCode` → `DirectorySchool`. When present, the
    ///   whitelist builder uses each school's authoritative
    ///   `mailDomains` (ENT + académie + commune services) rather
    ///   than inferring from the establishment string. Populate via
    ///   `DirectorySchoolCache.schools(for:)` in the caller.
    @MainActor
    func process(
        child: Child,
        config: IMAPServerConfig,
        fetched: [IMAPMessageInfo],
        directorySchools: [String: DirectorySchool] = [:]
    ) throws {
        try process(
            existing: child.messages,
            whitelistChildren: [child],
            attach: { $0.child = child },
            config: config,
            fetched: fetched,
            directorySchools: directorySchools
        )
    }

    /// Parent lane: same pipeline, rows attached to `family.messages`.
    /// The whitelist is the union of every child's school domains (plus
    /// manual entries) — a parent-assigned Gmail still only keeps school mail.
    @MainActor
    func process(
        family: Family,
        config: IMAPServerConfig,
        fetched: [IMAPMessageInfo],
        directorySchools: [String: DirectorySchool] = [:]
    ) throws {
        try process(
            existing: family.messages,
            whitelistChildren: family.children,
            attach: { $0.family = family },
            config: config,
            fetched: fetched,
            directorySchools: directorySchools
        )
    }

    @MainActor
    private func process(
        existing: [Message],
        whitelistChildren: [Child],
        attach: (Message) -> Void,
        config: IMAPServerConfig,
        fetched: [IMAPMessageInfo],
        directorySchools: [String: DirectorySchool]
    ) throws {
        // Dedicated school channels bypass filtering entirely. The guard
        // runs BEFORE whitelist construction so a monlycée-only user with
        // no Pronote child and no manual entries doesn't hit
        // `emptyWhitelist`.
        let bypassFilter = config.isDedicatedSchoolChannel

        // Build whitelist once per sync for performance.
        // If it is empty (and we're not on a dedicated channel), throw
        // rather than let personal mail into SwiftData — the onboarding
        // copy promises "only school mail is synced".
        let whitelist: [MailWhitelistEntry]
        if bypassFilter {
            whitelist = []
        } else {
            whitelist = MailWhitelist.build(from: whitelistChildren, directorySchools: directorySchools)
            guard !whitelist.isEmpty else {
                NSLog("[noto][warn] IMAP sync aborted — empty whitelist (provider=%@)", config.providerID)
                throw IMAPSyncError.emptyWhitelist
            }
        }

        var keptCount = 0
        var droppedCount = 0

        for info in fetched {
            if !bypassFilter && !MailFilter.shouldKeep(
                senderAddress: info.from,
                subject: info.subject,
                whitelist: whitelist
            ) {
                droppedCount += 1
                continue
            }

            // Primary dedupe: exact UID match scoped by provider.
            // IMAP UIDs are only unique per-mailbox, so "42" from Gmail
            // must not match "42" from MonLycée for the same child.
            if let uid = info.uid.map(String.init),
               let match = existing.first(where: {
                   $0.imapUID == uid && $0.imapProvider == config.providerID
               }) {
                updateIfNeeded(existing: match, with: info, config: config)
                continue
            }

            // Fallback dedupe: legacy rows without UID — composite match
            // on (sender, subject, same calendar day), scoped by provider.
            if let match = Self.legacyMatch(in: existing, info: info, providerID: config.providerID) {
                // Backfill the UID so the next sync resolves via the
                // primary path.
                if let uid = info.uid.map(String.init), match.imapUID == nil {
                    match.imapUID = uid
                }
                updateIfNeeded(existing: match, with: info, config: config)
                continue
            }

            // Cross-channel dedupe: the same monlycee.net inbox may already
            // have been imported through the ENT SSO channel
            // (`MonLyceeMailService`, source `.monlycee`) before the parent
            // connected it over IMAP. Webmail ids and IMAP UIDs differ, so
            // only the composite match can tell.
            if Self.ssoMatch(in: existing, info: info, providerID: config.providerID) != nil {
                continue
            }

            let msg = Message(
                sender: info.from,
                subject: info.subject,
                body: info.body,
                date: info.date,
                source: .imap,
                kind: .conversation,
                link: nil,
                imapUID: info.uid.map(String.init),
                imapProvider: config.providerID
            )
            msg.read = info.isRead
            attach(msg)
            modelContext.insert(msg)
            keptCount += 1
        }

        // Provider + assignment kind + counts only. The child's first name
        // is deliberately absent here — combining "lycée Y ↔ child name" in
        // the unified log (even across two lines, since timestamps are
        // microsecond-precise) is indirectly identifying under RGPD.
        NSLog("[noto] IMAP sync: provider=%@ assignment=%@ fetched=%d kept=%d dropped=%d",
              config.providerID, config.assignment.kind, fetched.count, keptCount, droppedCount)
    }

    // MARK: - Dedupe helpers

    /// Fallback dedupe for legacy IMAP-sourced rows without UID.
    /// Strictly scoped to `source == .imap` so authentic ENT
    /// conversations (which may legitimately collide on sender+subject+day
    /// when the school forwards ENT messages to parent email) are
    /// never absorbed or source-upgraded into IMAP.
    @MainActor
    func findLegacyMatch(child: Child, info: IMAPMessageInfo, providerID: String? = nil) -> Message? {
        Self.legacyMatch(in: child.messages, info: info, providerID: providerID)
    }

    @MainActor
    private static func legacyMatch(in messages: [Message], info: IMAPMessageInfo, providerID: String?) -> Message? {
        let cal = Calendar.current
        return messages.first { msg in
            guard msg.source == .imap else { return false }
            guard msg.kind == .conversation else { return false }
            // Scope to the same provider when known — prevents cross-account
            // collision when two mailboxes forward the same message.
            if let providerID, let msgProvider = msg.imapProvider {
                guard msgProvider == providerID else { return false }
            }
            guard msg.subject == info.subject else { return false }
            guard msg.sender == info.from else { return false }
            return cal.isDate(msg.date, inSameDayAs: info.date)
        }
    }

    /// A `.monlycee` row (ENT SSO webmail channel) holding the same mail as
    /// `info`, fetched through the monlycee.net IMAP preset. Mirror of
    /// `MonLyceeMailService.isDuplicate`'s IMAP branch: same normalisation,
    /// (sender, subject, same day). Other IMAP providers never match — a
    /// Gmail mail is not a monlycee.net one.
    @MainActor
    func findSSOMatch(child: Child, info: IMAPMessageInfo, providerID: String) -> Message? {
        Self.ssoMatch(in: child.messages, info: info, providerID: providerID)
    }

    @MainActor
    private static func ssoMatch(in messages: [Message], info: IMAPMessageInfo, providerID: String) -> Message? {
        guard providerID == MonLyceeMailService.imapProviderID else { return nil }
        let cal = Calendar.current
        let sender = MonLyceeMailService.normalized(info.from)
        let subject = MonLyceeMailService.normalized(info.subject)
        return messages.first { msg in
            msg.source == .monlycee
                && msg.kind == .conversation
                && MonLyceeMailService.normalized(msg.sender) == sender
                && MonLyceeMailService.normalized(msg.subject) == subject
                && cal.isDate(msg.date, inSameDayAs: info.date)
        }
    }

    @MainActor
    func updateIfNeeded(existing: Message, with info: IMAPMessageInfo, config: IMAPServerConfig) {
        // Clean up sender format if previously stored as full RFC 5322.
        if existing.sender.contains("<") {
            existing.sender = info.from
        }
        // Update body if previously empty.
        let effectivelyEmpty = existing.body
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if effectivelyEmpty && !info.body.isEmpty {
            existing.body = info.body
        }
        // Backfill imapProvider for legacy rows inserted before the
        // field existed. Without this, any message predating this PR
        // stays `imapProvider == nil` and `SourceBadge` renders "IMAP"
        // even for a reconnected MonLycée inbox — exactly the stale
        // live-state bug this PR was supposed to eliminate.
        if existing.imapProvider == nil {
            existing.imapProvider = config.providerID
        }
    }
}

enum IMAPSyncError: LocalizedError {
    case noCredentials
    case emptyWhitelist

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Messagerie non configurée"
        case .emptyWhitelist:
            return "Aucun domaine scolaire détecté. Ouvrez Réglages → Boîte mail → Domaines autorisés pour en ajouter un."
        }
    }
}
