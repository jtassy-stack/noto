import Foundation
import SwiftData

/// Syncs IMAP inbox messages into SwiftData Message objects for a given child.
@MainActor
struct IMAPSyncService {
    let modelContext: ModelContext

    func sync(for child: Child) async throws {
        guard let credentials = IMAPService.loadCredentials() else {
            throw IMAPSyncError.noCredentials
        }

        let fetched = try await IMAPService.fetchInbox(credentials: credentials)

        for info in fetched {
            // Match on subject (UIDs aren't stored; subjects are unique enough for school mailboxes)
            if let existing = child.messages.first(where: {
                $0.source == .ent && $0.subject == info.subject
            }) {
                // Update sender to display name format if previously stored as full RFC 5322
                if existing.sender.contains("<") {
                    existing.sender = info.from
                }
                // Update body if previously stored with only invisible/whitespace chars
                let effectivelyEmpty = existing.body
                    .replacingOccurrences(of: "\u{200C}", with: "")
                    .replacingOccurrences(of: "\u{200D}", with: "")
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                if effectivelyEmpty && !info.body.isEmpty {
                    existing.body = info.body
                }
                continue
            }

            let msg = Message(
                sender: info.from,
                subject: info.subject,
                body: info.body,
                date: info.date,
                source: .ent,
                kind: .conversation
            )
            msg.read = info.isRead
            msg.child = child
            modelContext.insert(msg)
        }

        #if DEBUG
        NSLog("[noto] IMAP sync: \(fetched.count) fetched for \(child.firstName)")
        #endif
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
