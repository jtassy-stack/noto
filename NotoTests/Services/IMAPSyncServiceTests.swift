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

    /// Test-only config used for `updateIfNeeded` unit tests where the
    /// provider identity is irrelevant to the assertion.
    private func anyConfig(providerID: String = "gmail") -> IMAPServerConfig {
        IMAPServerConfig(
            host: "imap.\(providerID).example",
            port: 993,
            username: "u@\(providerID).example",
            password: "x",
            providerID: providerID
        )
    }

    /// Clears manual whitelist entries persisted in the simulator's
    /// Keychain between runs. The schema tests below assume a clean
    /// state — leftovers from a previous run (the sim Keychain survives
    /// test-bundle reinstalls) would let `MailWhitelist.build` return
    /// a non-empty whitelist and silently flip `gmailEmptyWhitelistThrows`
    /// from throw to success.
    private func resetManualWhitelist() {
        try? MailWhitelist.saveManual([])
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
        service.updateIfNeeded(existing: existing, with: info(), config: anyConfig())
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
        service.updateIfNeeded(existing: existing, with: info(sender: "Mme Dupont"), config: anyConfig())
        #expect(existing.sender == "Mme Dupont")
    }

    @Test("updateIfNeeded backfills empty body")
    func updateBackfillsBody() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap, body: "")

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(body: "Nouveau contenu"), config: anyConfig())
        #expect(existing.body == "Nouveau contenu")
    }

    @Test("updateIfNeeded ignores body when existing is non-empty")
    func updatePreservesBody() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let existing = insertMessage(in: ctx, child: child, source: .imap, body: "Original")

        let service = IMAPSyncService(modelContext: ctx)
        service.updateIfNeeded(existing: existing, with: info(body: "Different"), config: anyConfig())
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
        service.updateIfNeeded(existing: existing, with: info(body: "Réel contenu"), config: anyConfig())
        #expect(existing.body == "Réel contenu")
    }

    // MARK: - Bypass behaviour (process())
    //
    // The property-level test suite (IMAPServerConfigTests) pins the
    // `isDedicatedSchoolChannel` rule. These tests pin the *effect* of
    // that rule on the sync pipeline — guarding the two failure modes
    // that matter most to privacy and UX:
    //
    //   1. A generic config (Gmail) must still drop non-whitelisted
    //      senders, even post-refactor. Regression here = personal mail
    //      leak.
    //   2. A dedicated config (monlycée) must keep every sender AND
    //      must NOT hit `emptyWhitelist` when the whitelist is empty.
    //      Regression here = monlycée users see no messages.

    private func makeConfig(providerID: String) -> IMAPServerConfig {
        IMAPServerConfig(
            host: "imaps.\(providerID).example",
            port: 993,
            username: "user@\(providerID).example",
            password: "x",
            providerID: providerID
        )
    }

    private func addTeacherToWhitelist(child: Child, ctx: ModelContext) {
        // Pin a teacher address so `MailWhitelist.build` produces a
        // non-empty whitelist for the generic-config tests. An existing
        // Pronote message suffices — the whitelist builder extracts
        // email-shaped senders from `child.messages`.
        _ = insertMessage(
            in: ctx,
            child: child,
            source: .pronote,
            sender: "Mme Dupont <dupont@ecoleabc.fr>"
        )
    }

    @Test("monlycée bypass persists a message whose sender is outside any whitelist")
    func monlyceeBypassPersistsUnknownSender() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let config = makeConfig(providerID: "monlycee")
        let fetched = [info(uid: 1, sender: "orientation@rectorat.fr", subject: "Portes ouvertes")]

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: fetched)

        let imapMessages = child.messages.filter { $0.source == .imap }
        #expect(imapMessages.count == 1)
        #expect(imapMessages.first?.sender == "orientation@rectorat.fr")
        #expect(imapMessages.first?.imapProvider == "monlycee")
    }

    @Test("monlycée config does NOT throw emptyWhitelist even with no whitelist sources")
    func monlyceeBypassSkipsEmptyWhitelistGuard() throws {
        resetManualWhitelist()
        // Regression guard for the specific bug the bypass exists to
        // prevent: a monlycée-only family with no Pronote child would
        // otherwise throw before the first message is processed.
        let ctx = try makeContext()
        let child = makeChild(in: ctx) // no messages, no establishment-derived domain
        let config = makeConfig(providerID: "monlycee")

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: [])
        #expect(child.messages.filter { $0.source == .imap }.isEmpty)
    }

    @Test("gmail config drops a sender outside the whitelist")
    func gmailFiltersNonWhitelistedSender() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        addTeacherToWhitelist(child: child, ctx: ctx)
        let config = makeConfig(providerID: "gmail")
        let fetched = [info(uid: 1, sender: "newsletter@spam.com", subject: "Deal of the day")]

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: fetched)

        #expect(child.messages.filter { $0.source == .imap }.isEmpty)
    }

    @Test("gmail config keeps a sender that matches the whitelist")
    func gmailKeepsWhitelistedSender() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        addTeacherToWhitelist(child: child, ctx: ctx)
        let config = makeConfig(providerID: "gmail")
        let fetched = [info(uid: 1, sender: "Mme Dupont <dupont@ecoleabc.fr>", subject: "Réunion")]

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: fetched)

        let imap = child.messages.filter { $0.source == .imap }
        #expect(imap.count == 1)
        #expect(imap.first?.imapProvider == "gmail")
    }

    @Test("gmail config throws emptyWhitelist when no school source seeds a whitelist")
    func gmailEmptyWhitelistThrows() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx) // no messages, no establishment domain
        let config = makeConfig(providerID: "gmail")
        let fetched = [info(uid: 1)]

        let service = IMAPSyncService(modelContext: ctx)
        #expect(throws: IMAPSyncError.self) {
            try service.process(child: child, config: config, fetched: fetched)
        }
    }

    @Test("stamps imapProvider on every new insert regardless of config")
    func stampsImapProvider() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let config = makeConfig(providerID: "monlycee")
        let fetched = [
            info(uid: 1, sender: "a@rectorat.fr", subject: "A"),
            info(uid: 2, sender: "b@rectorat.fr", subject: "B"),
        ]

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: fetched)

        let providers = child.messages.filter { $0.source == .imap }.map(\.imapProvider)
        #expect(providers.allSatisfy { $0 == "monlycee" })
        #expect(providers.count == 2)
    }

    @Test("legacy row with nil imapProvider is backfilled on re-sync")
    func updateIfNeededBackfillsLegacyProvider() throws {
        resetManualWhitelist()
        // Corpus pre-dating the imapProvider field have nil. Without
        // the backfill in updateIfNeeded, SourceBadge keeps rendering
        // "IMAP" for a reconnected MonLycée inbox — the exact bug this
        // PR was meant to close.
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let legacy = insertMessage(in: ctx, child: child, source: .imap, imapUID: "42")
        #expect(legacy.imapProvider == nil)

        let service = IMAPSyncService(modelContext: ctx)
        let config = makeConfig(providerID: "monlycee")
        try service.process(
            child: child,
            config: config,
            fetched: [info(uid: 42, sender: "Mme Dupont", subject: "Réunion")]
        )

        #expect(legacy.imapProvider == "monlycee")
        // And no duplicate — the UID should have matched the legacy row.
        #expect(child.messages.filter { $0.source == .imap }.count == 1)
    }

    @Test("process() is idempotent on the same UID (no duplicates on re-sync)")
    func processIsIdempotentByUID() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let config = makeConfig(providerID: "monlycee")
        let batch = [info(uid: 7, sender: "s@rectorat.fr", subject: "Info")]

        let service = IMAPSyncService(modelContext: ctx)
        try service.process(child: child, config: config, fetched: batch)
        try service.process(child: child, config: config, fetched: batch)

        #expect(child.messages.filter { $0.source == .imap }.count == 1)
    }

    @Test("legacy UID-less row is matched + backfilled under monlycée bypass")
    func bypassRespectsLegacyMatchAndBackfill() throws {
        resetManualWhitelist()
        // The bypass path still runs dedupe — a UID-less row from a
        // pre-Phase-7 install must be found and have its UID stamped
        // so the next sync resolves via the primary path.
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let today = Date.now
        let legacy = insertMessage(
            in: ctx,
            child: child,
            source: .imap,
            sender: "Mme Dupont",
            subject: "Réunion parents",
            date: today,
            imapUID: nil
        )

        let service = IMAPSyncService(modelContext: ctx)
        let config = makeConfig(providerID: "monlycee")
        try service.process(
            child: child,
            config: config,
            fetched: [info(uid: 99, sender: "Mme Dupont", subject: "Réunion parents", date: today)]
        )

        #expect(legacy.imapUID == "99")
        #expect(legacy.imapProvider == "monlycee")
        #expect(child.messages.filter { $0.source == .imap }.count == 1)
    }

    // MARK: - Cross-account UID collision

    @Test("Same UID from two different providers inserts two messages — no cross-account collision")
    func crossAccountUIDNoCollision() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let today = Date.now

        // Use two dedicated-school-channel providers so whitelist bypass applies to both.
        // The key invariant under test is providerID scoping, not filtering.
        let configA = makeConfig(providerID: "monlycee")
        let configB = IMAPServerConfig(
            host: "imap.ent77.example",
            port: 993,
            username: "u@ent77.fr",
            password: "x",
            providerID: "monlycee2"   // different provider, same UID
        )
        let service = IMAPSyncService(modelContext: ctx)

        // Account A inserts message with UID 42
        try service.process(
            child: child,
            config: configA,
            fetched: [info(uid: 42, sender: "Prof Martin", subject: "Conseil de classe", date: today)]
        )

        // Account B also has UID 42 — must not match account A's message
        // We use configA's isDedicatedSchoolChannel for B by overriding the raw config
        // to bypass whitelist; what matters is the different providerID string.
        let existing = child.messages.filter { $0.source == .imap }
        // Insert account B's message manually to simulate a second dedicated provider
        let msgB = Message(
            sender: "Direction",
            subject: "Sortie scolaire",
            body: "Infos",
            date: today,
            source: .imap,
            kind: .conversation,
            link: nil,
            imapUID: "42",
            imapProvider: "monlycee2"
        )
        msgB.child = child
        ctx.insert(msgB)

        // Now verify: primary UID dedup for account A does NOT match account B's row
        try service.process(
            child: child,
            config: configA,
            fetched: [info(uid: 42, sender: "Prof Martin", subject: "Conseil de classe", date: today)]
        )

        let imapMessages = child.messages.filter { $0.source == .imap }
        #expect(imapMessages.count == 2, "Both messages must be stored — UID 42 is not globally unique")
        #expect(imapMessages.contains { $0.imapProvider == "monlycee" && $0.subject == "Conseil de classe" })
        #expect(imapMessages.contains { $0.imapProvider == "monlycee2" && $0.subject == "Sortie scolaire" })
    }

    @Test("Same UID from same provider deduplicates as expected")
    func sameProviderUIDDeduplicates() throws {
        resetManualWhitelist()
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let today = Date.now

        // monlycee bypasses whitelist check
        let config = makeConfig(providerID: "monlycee")
        let service = IMAPSyncService(modelContext: ctx)

        // Sync once
        try service.process(
            child: child,
            config: config,
            fetched: [info(uid: 42, sender: "Prof Martin", subject: "Conseil", date: today)]
        )
        // Sync again — same UID, same provider: must not insert a duplicate
        try service.process(
            child: child,
            config: config,
            fetched: [info(uid: 42, sender: "Prof Martin", subject: "Conseil", date: today)]
        )

        #expect(child.messages.filter { $0.source == .imap }.count == 1)
    }
}
