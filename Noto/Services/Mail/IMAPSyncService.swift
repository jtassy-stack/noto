import Foundation
import SwiftData

/// Syncs IMAP inbox messages into SwiftData Message objects for a given child.
///
/// Phase 7 changes:
///   - Source corrected to `.imap` on new inserts (was `.ent` — tech debt)
///   - Dedupe primarily on `imapUID` (stable across refetches)
///   - Fallback dedupe composite `(sender, subject, day)` for legacy
///     rows without UID
///   - Whitelist filtering: only mails matching the configured MailFilter
///     whitelist are persisted (user's personal mail never lands in the DB)
@MainActor
struct IMAPSyncService {
    let modelContext: ModelContext

    func sync(for child: Child) async throws {
        guard let config = IMAPService.loadConfig() else {
            throw IMAPSyncError.noCredentials
        }

        let fetched = try await IMAPService.fetchInbox(config: config)

        // Build whitelist once per sync for performance. If it is empty
        // (no school domain detected yet + no manual entries), fall back
        // to permissive mode — otherwise a fresh install would drop
        // every mail until the parent re-runs QR login.
        let whitelist = MailWhitelist.build(from: [child])
        let filterEnabled = !whitelist.isEmpty

        var keptCount = 0
        var droppedCount = 0

        for info in fetched {
            if filterEnabled,
               !MailFilter.shouldKeep(
                   senderAddress: info.from,
                   subject: info.subject,
                   whitelist: whitelist
               ) {
                droppedCount += 1
                continue
            }

            // Primary dedupe: exact UID match
            if let uid = info.uid.map(String.init),
               let existing = child.messages.first(where: { $0.imapUID == uid }) {
                updateIfNeeded(existing: existing, with: info)
                continue
            }

            // Fallback dedupe: legacy rows without UID — composite match
            // on (sender display name, subject, same calendar day).
            // Scoped to imap-sourced rows (and legacy `.ent` ones that
            // were actually IMAP) to avoid colliding with Pronote
            // conversation messages that share a subject line.
            if let existing = findLegacyMatch(child: child, info: info) {
                // Backfill the UID so the next sync resolves via the
                // primary path.
                if let uid = info.uid.map(String.init), existing.imapUID == nil {
                    existing.imapUID = uid
                }
                updateIfNeeded(existing: existing, with: info)
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
                imapUID: info.uid.map(String.init)
            )
            msg.read = info.isRead
            msg.child = child
            modelContext.insert(msg)
            keptCount += 1
        }

        #if DEBUG
        NSLog("[noto] IMAP sync: fetched=\(fetched.count) kept=\(keptCount) dropped=\(droppedCount) for \(child.firstName)")
        #endif
    }

    // MARK: - Dedupe helpers

    private func findLegacyMatch(child: Child, info: IMAPMessageInfo) -> Message? {
        let cal = Calendar.current
        return child.messages.first { msg in
            // Scope to mail-sourced rows; Pronote conversations have
            // their own source and kind and shouldn't be absorbed here.
            guard msg.source == .imap || msg.source == .ent else { return false }
            guard msg.kind == .conversation else { return false }
            guard msg.subject == info.subject else { return false }
            guard msg.sender == info.from else { return false }
            return cal.isDate(msg.date, inSameDayAs: info.date)
        }
    }

    private func updateIfNeeded(existing: Message, with info: IMAPMessageInfo) {
        // Upgrade legacy `.ent` rows to `.imap` so they stop appearing
        // in the Pronote messages list incorrectly.
        if existing.source == .ent {
            existing.source = .imap
        }
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
    }
}

enum IMAPSyncError: LocalizedError {
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials: "Messagerie non configurée"
        }
    }
}
