import Foundation
import SwiftData

/// Syncs IMAP inbox messages into SwiftData Message objects for a given child.
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
///
/// Threading contract
/// ------------------
/// `sync(for:directorySchools:)` does NOT require the caller to be on the
/// main actor.  The expensive network I/O (`IMAPService.fetchInbox`) runs
/// on whatever cooperative thread the Swift runtime assigns; only
/// `process(child:config:fetched:directorySchools:)` — which touches
/// SwiftData — must be called on the MainActor and is annotated
/// accordingly.  Callers that are already on the main actor can call
/// `sync` directly; the compiler will hop off automatically for the
/// nonisolated part.
struct IMAPSyncService {
    let modelContext: ModelContext

    /// Full sync: load config, fetch remote inbox off the main actor,
    /// then process the results back on the main actor.
    ///
    /// The network fetch (`IMAPService.fetchInbox`) is intentionally
    /// called from a nonisolated context so it never blocks the main
    /// thread while opening the TCP connection, logging in, and
    /// streaming message headers.  SwiftData writes happen only after
    /// the fetch completes and we're back on the main actor via
    /// `processOnMain`.
    ///
    /// Network + Keychain side effects live here; the pure logic is in
    /// `process(child:config:fetched:directorySchools:)` so tests can
    /// exercise the whitelist / bypass / dedupe branches without a live
    /// server.
    @MainActor
    func sync(
        for child: Child,
        directorySchools: [String: DirectorySchool] = [:]
    ) async throws {
        guard let config = IMAPService.loadConfig() else {
            throw IMAPSyncError.noCredentials
        }

        // Fetch off the main actor — this is the expensive network hop.
        let fetched = try await Task.detached(priority: .userInitiated) {
            try await IMAPService.fetchInbox(config: config)
        }.value

        // Write results back on the main actor where SwiftData lives.
        try await processOnMain(child: child, config: config, fetched: fetched, directorySchools: directorySchools)
    }

    /// Bridges the nonisolated `sync` path back onto the MainActor for
    /// SwiftData writes.  Separate from the public `process` method so
    /// the MainActor hop is explicit and unit-testable via `process`
    /// without needing an actor boundary crossing.
    @MainActor
    private func processOnMain(
        child: Child,
        config: IMAPServerConfig,
        fetched: [IMAPMessageInfo],
        directorySchools: [String: DirectorySchool]
    ) throws {
        try process(child: child, config: config, fetched: fetched, directorySchools: directorySchools)
    }

    /// Pure processing step — takes an already-fetched batch and applies
    /// whitelist filtering (or bypass), dedupe, and insert. Exposed so
    /// the bypass invariant has behavioural test coverage.
    @MainActor
    ///
    /// - Parameter directorySchools: optional pre-fetched map of
    ///   `Child.rneCode` → `DirectorySchool`. When present, the
    ///   whitelist builder uses each school's authoritative
    ///   `mailDomains` (ENT + académie + commune services) rather
    ///   than inferring from the establishment string. Populate via
    ///   `DirectorySchoolCache.schools(for:)` in the caller.
    func process(
        child: Child,
        config: IMAPServerConfig,
        fetched: [IMAPMessageInfo],
        directorySchools: [String: DirectorySchool] = [:]
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
            whitelist = MailWhitelist.build(from: [child], directorySchools: directorySchools)
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
               let existing = child.messages.first(where: {
                   $0.imapUID == uid && $0.imapProvider == config.providerID
               }) {
                updateIfNeeded(existing: existing, with: info, config: config)
                continue
            }

            // Fallback dedupe: legacy rows without UID — composite match
            // on (sender, subject, same calendar day), scoped by provider.
            if let existing = findLegacyMatch(child: child, info: info, providerID: config.providerID) {
                // Backfill the UID so the next sync resolves via the
                // primary path.
                if let uid = info.uid.map(String.init), existing.imapUID == nil {
                    existing.imapUID = uid
                }
                updateIfNeeded(existing: existing, with: info, config: config)
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
            msg.child = child
            modelContext.insert(msg)
            keptCount += 1
        }

        // Provider + counts only. The child's first name is deliberately
        // absent here — combining "lycée Y ↔ child name" in the unified
        // log (even across two lines, since timestamps are microsecond-
        // precise) is indirectly identifying under RGPD.
        NSLog("[noto] IMAP sync: provider=%@ fetched=%d kept=%d dropped=%d",
              config.providerID, fetched.count, keptCount, droppedCount)
    }

    // MARK: - Dedupe helpers

    /// Fallback dedupe for legacy IMAP-sourced rows without UID.
    /// Strictly scoped to `source == .imap` so authentic ENT
    /// conversations (which may legitimately collide on sender+subject+day
    /// when the school forwards ENT messages to parent email) are
    /// never absorbed or source-upgraded into IMAP.
    @MainActor
    func findLegacyMatch(child: Child, info: IMAPMessageInfo, providerID: String? = nil) -> Message? {
        let cal = Calendar.current
        return child.messages.first { msg in
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
