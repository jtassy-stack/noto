import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for `IMAPSyncService` dedupe + legacy-match scoping.
/// These tests use an in-memory ModelContainer and stub IMAPMessageInfo
/// values — no network, no Keychain, no SwiftMail.
///
/// Critical regression targets:
///   - A Pronote `.pronote` message sharing subject/sender/day with an
///     IMAP fetch is NOT absorbed (would silently delete user data).
///   - An ENT `.ent` conversation is NOT upgraded to `.imap` on collision
///     (would make it disappear from the ENT messages tab).
///   - A legacy `.imap` row without UID IS matched via composite and
///     gets its UID backfilled so next sync resolves via primary path.
@Suite("IMAPSyncService")
@MainActor
struct IMAPSyncServiceTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(in ctx: ModelContext) -> Child {
        let child = Child(
            firstName: "Gaston",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "Collège Test"
        )
        ctx.insert(child)
        return child
    }

    private func insertMessage(
        in ctx: ModelContext,
        child: Child,
        source: MessageSource,
        kind: MessageKind = .conversation,
        sender: String = "Mme Dupont",
        subject: String = "Réunion",
        body: String = "Bonjour",
        date: Date = .now,
        imapUID: String? = nil
    ) -> Message {
        let msg = Message(
            sender: sender,
            subject: subject,
            body: body,
            date: date,
            source: source,
            kind: kind,
            link: nil,
            imapUID: imapUID
        )
        msg.child = child
        ctx.insert(msg)
        return msg
    }

    private func info(
        uid: UInt32? = nil,
        sender: String = "Mme Dupont",
        subject: String = "Réunion",
        date: Date = .now,
        body: String = "Bonjour"
    ) -> IMAPMessageInfo {
        IMAPMessageInfo(
            uid: uid,
            subject: subject,
            from: sender,
            date: date,
            body: body,
            isRead: false
        )
    }

    // MARK: - findLegacyMatch scoping (critical regression guards)

    @Test("Pronote .pronote message is NEVER matched — protects user data")
    func pronoteMessageNotMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        _ = insertMessage(in: ctx, child: child, source: .pronote)

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info())
        #expect(match == nil)
    }

    @Test("ENT .ent conversation is NEVER matched — protects ENT tab visibility")
    func entMessageNotMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        _ = insertMessage(in: ctx, child: child, source: .ent)

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info())
        #expect(match == nil)
    }

    @Test("Legacy .imap row without UID IS matched via composite")
    func imapLegacyMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap, imapUID: nil)

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info())
        #expect(match?.id == existing.id)
    }

    @Test("Different day does not match")
    func differentDayNotMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let yesterday = Date.now.addingTimeInterval(-86_400 * 2)
        _ = insertMessage(in: ctx, child: child, source: .imap, date: yesterday)

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info(date: .now))
        #expect(match == nil)
    }

    @Test("Different sender does not match")
    func differentSenderNotMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        _ = insertMessage(in: ctx, child: child, source: .imap, sender: "Mme Dupont")

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info(sender: "M. Martin"))
        #expect(match == nil)
    }

    @Test("Schoolbook kind is NEVER matched — conversation-only")
    func schoolbookKindNotMatched() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        _ = insertMessage(in: ctx, child: child, source: .imap, kind: .schoolbook)

        let service = IMAPSyncService(modelContext: ctx)
        let match = service.findLegacyMatch(child: child, info: info())
        #expect(match == nil)
    }

    // MARK: - updateIfNeeded (cleanup on refetch)

    @Test("updateIfNeeded does NOT change source (Phase-7-fix regression guard)")
    func updateDoesNotMutateSource() throws {
        // Earlier drafts silently upgraded .ent → .imap on match, which
        // made ENT conversations disappear. The scope tightening in
        // findLegacyMatch made this dead code, but guarding here too
        // so a future "re-enable legacy ENT matching" can't regress.
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap)

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info())
        #expect(existing.source == .imap)
    }

    @Test("updateIfNeeded cleans up RFC 5322 sender format")
    func updateCleansSender() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(
            in: ctx,
            child: child,
            source: .imap,
            sender: "\"Mme Dupont\" <dupont@monlycee.net>"
        )

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(sender: "Mme Dupont"))
        #expect(existing.sender == "Mme Dupont")
    }

    @Test("updateIfNeeded backfills empty body")
    func updateBackfillsBody() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap, body: "")

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(body: "Nouveau contenu"))
        #expect(existing.body == "Nouveau contenu")
    }

    @Test("updateIfNeeded ignores body when existing is non-empty")
    func updatePreservesBody() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap, body: "Original")

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(body: "Different"))
        #expect(existing.body == "Original")
    }

    @Test("updateIfNeeded treats zero-width-only body as effectively empty")
    func updateBackfillsZeroWidthBody() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(
            in: ctx,
            child: child,
            source: .imap,
            body: "\u{200C}\u{200D}\u{FEFF}  "
        )

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(body: "Réel contenu"))
        #expect(existing.body == "Réel contenu")
    }
}
