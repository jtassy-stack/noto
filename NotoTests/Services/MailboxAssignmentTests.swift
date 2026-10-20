import Testing
import Foundation
import SwiftData
@testable import Noto

/// Per-account mailbox assignment (TestFlight feedback, build 230):
/// Codable back-compat of the Keychain blob, pure routing rules, the
/// deleted-child fallback, the SSO-channel gate, and the multi-account
/// fan-out with a canned fetch (no network, no live IMAP server).
@Suite("MailboxAssignment")
@MainActor
struct MailboxAssignmentTests {

    // MARK: - Codable

    @Test("legacy blob without `assignment` decodes as Tous les enfants")
    func legacyBlobDefaultsToAllChildren() throws {
        let json = """
        [{"id":"9C1F7E6A-6C5B-4F3A-9E1D-2B7A0C4D5E6F","host":"imap.gmail.com","port":993,
          "username":"parent@gmail.com","password":"secret","providerID":"gmail"}]
        """
        let configs = try JSONDecoder().decode([IMAPServerConfig].self, from: Data(json.utf8))
        #expect(configs.count == 1)
        #expect(configs[0].assignment == .allChildren)
        #expect(configs[0].password == "secret")
    }

    @Test("every assignment round-trips through the Keychain JSON shape",
          arguments: [MailboxAssignment.allChildren, .child(id: "child-42"), .parent])
    func roundTrip(_ assignment: MailboxAssignment) throws {
        let config = IMAPServerConfig(
            host: "imap.gmail.com", port: 993, username: "p@gmail.com",
            password: "x", providerID: "gmail", assignment: assignment
        )
        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([IMAPServerConfig].self, from: data)
        #expect(decoded == [config])
        #expect(decoded[0].assignment == assignment)
    }

    @Test("unknown or malformed assignment falls back to Tous without losing the account")
    func unknownAssignmentFallsBack() throws {
        let json = """
        [{"host":"imap.gmail.com","port":993,"username":"p@gmail.com","password":"x",
          "providerID":"gmail","assignment":{"kind":"grandparent"}},
         {"host":"imap.gmail.com","port":993,"username":"q@gmail.com","password":"y",
          "providerID":"gmail","assignment":{"kind":"child"}}]
        """
        let configs = try JSONDecoder().decode([IMAPServerConfig].self, from: Data(json.utf8))
        #expect(configs.map(\.assignment) == [.allChildren, .allChildren])
        #expect(configs.map(\.username) == ["p@gmail.com", "q@gmail.com"])
    }

    @Test("description logs the assignment kind only, never the child id or password")
    func descriptionIsLogSafe() {
        let config = IMAPServerConfig(
            host: "imap.gmail.com", port: 993, username: "p@gmail.com",
            password: "hunter2", providerID: "gmail", assignment: .child(id: "secret-child-ref")
        )
        #expect(config.description.contains("assignment: child"))
        #expect(!config.description.contains("secret-child-ref"))
        #expect(!config.description.contains("hunter2"))
    }

    // MARK: - Routing (pure)

    private let ids = ["gaston", "joseph"]

    private func routed(
        _ assignment: MailboxAssignment,
        defaultChildren: [String]? = nil
    ) -> [String]? {
        switch MailboxRouting.target(for: assignment, children: ids, defaultChildren: defaultChildren, key: { $0 }) {
        case .children(let kids): return kids
        case .parent: return nil
        }
    }

    @Test("Tous les enfants → every child (current behaviour)")
    func allChildrenTargetsEveryone() {
        #expect(routed(.allChildren) == ["gaston", "joseph"])
    }

    @Test("Tous les enfants honours the caller's default pool")
    func allChildrenUsesDefaultPool() {
        #expect(routed(.allChildren, defaultChildren: ["gaston"]) == ["gaston"])
    }

    @Test("an explicit child is targeted alone, even outside the default pool")
    func explicitChildWins() {
        #expect(routed(.child(id: "joseph")) == ["joseph"])
        #expect(routed(.child(id: "joseph"), defaultChildren: ["gaston"]) == ["joseph"])
    }

    @Test("a deleted child falls back to Tous les enfants")
    func danglingChildFallsBack() {
        #expect(routed(.child(id: "removed")) == ["gaston", "joseph"])
        #expect(MailboxAssignment.child(id: "removed").resolved(childIDs: ids) == .allChildren)
    }

    @Test("Parent → parent lane, no child")
    func parentTargetsParentLane() {
        #expect(routed(.parent) == nil)
    }

    @Test("repairingOrphans only rewrites accounts that pointed at the removed child")
    func repairingOrphans() {
        let a = IMAPServerConfig(host: "h", port: 993, username: "a", password: "x", providerID: "gmail",
                                 assignment: .child(id: "gaston"))
        let b = IMAPServerConfig(host: "h", port: 993, username: "b", password: "x", providerID: "gmail",
                                 assignment: .child(id: "joseph"))
        let c = IMAPServerConfig(host: "h", port: 993, username: "c", password: "x", providerID: "gmail",
                                 assignment: .parent)
        let repaired = MailboxRouting.repairingOrphans([a, b, c], removedChildID: "gaston")
        #expect(repaired.map(\.assignment) == [.allChildren, .child(id: "joseph"), .parent])
        #expect(repaired.map(\.id) == [a.id, b.id, c.id])
        #expect(repaired.map(\.password) == ["x", "x", "x"])
    }

    @Test("labels read Tous les enfants / prénom / Parent, dangling → Tous")
    func labels() {
        let kids = [(id: "gaston", firstName: "Gaston"), (id: "joseph", firstName: "Joseph")]
        #expect(MailboxRouting.label(for: .allChildren, children: kids) == "Tous les enfants")
        #expect(MailboxRouting.label(for: .child(id: "joseph"), children: kids) == "Joseph")
        #expect(MailboxRouting.label(for: .parent, children: kids) == "Parent")
        #expect(MailboxRouting.label(for: .child(id: "removed"), children: kids) == "Tous les enfants")
    }

    // MARK: - SSO channel gate

    private func monlycee(_ assignment: MailboxAssignment) -> IMAPServerConfig {
        IMAPServerConfig(host: "imaps.monlycee.net", port: 993, username: "p@monlycee.net",
                         password: "x", providerID: "monlycee", assignment: assignment)
    }

    private func covers(_ childID: String, _ configs: [IMAPServerConfig]) -> Bool {
        MailboxRouting.imapCoversMonLyceeInbox(
            forChildID: childID, allChildIDs: ids, configs: configs, monLyceeProviderID: "monlycee"
        )
    }

    @Test("a monlycée box assigned to Gaston no longer silences Joseph's SSO mail")
    func ssoGateIsPerChild() {
        let configs = [monlycee(.child(id: "gaston"))]
        #expect(covers("gaston", configs))
        #expect(!covers("joseph", configs))
    }

    @Test("Tous / Parent / dangling monlycée box still covers every child (one inbox, one fetcher)")
    func ssoGateCoversAllOtherwise() {
        for assignment in [MailboxAssignment.allChildren, .parent, .child(id: "removed")] {
            #expect(covers("joseph", [monlycee(assignment)]))
        }
    }

    @Test("non-monlycée accounts never gate the SSO channel")
    func ssoGateIgnoresOtherProviders() {
        let gmail = IMAPServerConfig(host: "imap.gmail.com", port: 993, username: "p@gmail.com",
                                     password: "x", providerID: "gmail")
        #expect(!covers("joseph", [gmail]))
    }

    // MARK: - Fan-out (in-memory SwiftData, canned fetch)

    private struct Fixture {
        let ctx: ModelContext
        let family: Family
        let gaston: Child
        let joseph: Child
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema([Family.self, Child.self, Message.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = ModelContext(container)
        let family = Family(parentName: "Parent")
        ctx.insert(family)
        let gaston = Child(firstName: "Gaston", level: .college, grade: "4e", schoolType: .pronote, establishment: "Collège Test")
        let joseph = Child(firstName: "Joseph", level: .lycee, grade: "2nde", schoolType: .pronote, establishment: "Lycée Test")
        for child in [gaston, joseph] {
            ctx.insert(child)
            child.family = family
        }
        // Permanent identifiers before any `childKey` is computed.
        try ctx.save()
        return Fixture(ctx: ctx, family: family, gaston: gaston, joseph: joseph)
    }

    /// monlycee.net preset → dedicated school channel, whitelist bypassed,
    /// so these tests isolate routing from domain filtering.
    private func account(_ assignment: MailboxAssignment, username: String = "p@monlycee.net") -> IMAPServerConfig {
        IMAPServerConfig(host: "imaps.monlycee.net", port: 993, username: username,
                         password: "x", providerID: "monlycee", assignment: assignment)
    }

    private let batch = [
        IMAPMessageInfo(uid: 1, subject: "Conseil de classe", from: "vie-scolaire@lycee.fr",
                        date: .now, body: "Bonjour", isRead: false),
    ]

    private func imapCount(_ child: Child) -> Int {
        child.messages.filter { $0.source == .imap }.count
    }

    @Test("an account assigned to Joseph only lands in Joseph's messages")
    func assignedChildOnly() async throws {
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        let result = await service.syncAccounts(
            [account(.child(id: MailboxRouting.childKey(f.joseph)))],
            children: [f.gaston, f.joseph],
            family: f.family,
            fetch: { [batch] _ in batch }
        )
        #expect(result.anySuccess)
        #expect(result.errors.isEmpty)
        #expect(imapCount(f.joseph) == 1)
        #expect(imapCount(f.gaston) == 0)
        #expect(f.family.messages.isEmpty)
    }

    @Test("Tous les enfants keeps today's behaviour: every child gets the mail")
    func allChildrenFanOut() async throws {
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        _ = await service.syncAccounts(
            [account(.allChildren)],
            children: [f.gaston, f.joseph],
            family: f.family,
            fetch: { [batch] _ in batch }
        )
        #expect(imapCount(f.gaston) == 1)
        #expect(imapCount(f.joseph) == 1)
    }

    @Test("Parent lands in Family.messages, not in any child, and dedupes on resync")
    func parentLane() async throws {
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        for _ in 0..<2 {
            _ = await service.syncAccounts(
                [account(.parent)],
                children: [f.gaston, f.joseph],
                family: f.family,
                fetch: { [batch] _ in batch }
            )
        }
        #expect(f.family.messages.count == 1)
        #expect(f.family.messages.first?.child == nil)
        #expect(f.family.messages.first?.imapProvider == "monlycee")
        #expect(imapCount(f.gaston) == 0)
        #expect(imapCount(f.joseph) == 0)
    }

    @Test("Parent lane with a generic box still filters through the family whitelist")
    func parentLaneFilters() async throws {
        try? MailWhitelist.saveManual([])
        let f = try makeFixture()
        // Seed a school sender on Gaston: the parent lane's whitelist is the
        // union of every child's sources.
        let seed = Message(sender: "Mme Dupont <dupont@ecoleabc.fr>", subject: "Sortie",
                           body: "", date: .now, source: .pronote)
        seed.child = f.gaston
        f.ctx.insert(seed)

        let gmail = IMAPServerConfig(host: "imap.gmail.com", port: 993, username: "p@gmail.com",
                                     password: "x", providerID: "gmail", assignment: .parent)
        let fetched = [
            IMAPMessageInfo(uid: 1, subject: "Réunion", from: "Mme Dupont <dupont@ecoleabc.fr>",
                            date: .now, body: "", isRead: false),
            IMAPMessageInfo(uid: 2, subject: "Promo", from: "deals@shop.example",
                            date: .now, body: "", isRead: false),
        ]
        let service = IMAPSyncService(modelContext: f.ctx)
        _ = await service.syncAccounts([gmail], children: [f.gaston, f.joseph], family: f.family,
                                       fetch: { _ in fetched })
        #expect(f.family.messages.map(\.subject) == ["Réunion"])
    }

    @Test("an account pointing at a deleted child syncs to every child")
    func danglingAssignmentSyncsToAll() async throws {
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        _ = await service.syncAccounts(
            [account(.child(id: "child-that-was-deleted"))],
            children: [f.gaston, f.joseph],
            family: f.family,
            fetch: { [batch] _ in batch }
        )
        #expect(imapCount(f.gaston) == 1)
        #expect(imapCount(f.joseph) == 1)
    }

    @Test("no target → the mailbox is not even fetched")
    func noTargetSkipsFetch() async throws {
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        let result = await service.syncAccounts(
            [account(.allChildren)],
            children: [f.gaston, f.joseph],
            defaultChildren: [],
            family: f.family,
            fetch: { _ in
                Issue.record("fetch must not run without a target")
                return []
            }
        )
        #expect(!result.anySuccess)
        #expect(result.errors.isEmpty)
    }

    @Test("a failing account is reported by username and does not block the others")
    func failingAccountIsolated() async throws {
        struct Boom: Error {}
        let f = try makeFixture()
        let service = IMAPSyncService(modelContext: f.ctx)
        let broken = account(.allChildren, username: "broken@monlycee.net")
        let fine = account(.child(id: MailboxRouting.childKey(f.gaston)), username: "fine@monlycee.net")
        let result = await service.syncAccounts(
            [broken, fine],
            children: [f.gaston, f.joseph],
            family: f.family,
            fetch: { [batch] config in
                if config.username == "broken@monlycee.net" { throw Boom() }
                return batch
            }
        )
        #expect(result.errors.map(\.account) == ["broken@monlycee.net"])
        #expect(imapCount(f.gaston) == 1)
        #expect(imapCount(f.joseph) == 0)
    }

    // MARK: - Reassignment (TestFlight: « Tous » → « Parent » duplicated every mail)

    @Test("laneAccepts: Tous = any child, one child = that child, Parent = parent lane only")
    func laneAcceptsRules() {
        let all = ids
        #expect(MailboxRouting.laneAccepts(.allChildren, childID: "joseph", allChildIDs: all))
        #expect(!MailboxRouting.laneAccepts(.allChildren, childID: nil, allChildIDs: all))
        #expect(MailboxRouting.laneAccepts(.child(id: "joseph"), childID: "joseph", allChildIDs: all))
        #expect(!MailboxRouting.laneAccepts(.child(id: "joseph"), childID: "gaston", allChildIDs: all))
        #expect(!MailboxRouting.laneAccepts(.child(id: "joseph"), childID: nil, allChildIDs: all))
        #expect(MailboxRouting.laneAccepts(.parent, childID: nil, allChildIDs: all))
        #expect(!MailboxRouting.laneAccepts(.parent, childID: "gaston", allChildIDs: all))
        // Dangling child id resolves to Tous.
        #expect(MailboxRouting.laneAccepts(.child(id: "removed"), childID: "gaston", allChildIDs: all))
    }

    @Test("canReconcile only when the provider identifies a single account")
    func canReconcileRule() {
        let a = account(.allChildren, username: "a@monlycee.net")
        let b = account(.parent, username: "b@monlycee.net")
        let gmail = IMAPServerConfig(host: "imap.gmail.com", port: 993, username: "p@gmail.com",
                                     password: "x", providerID: "gmail")
        #expect(MailboxRouting.canReconcile(providerID: "monlycee", configs: [a, gmail]))
        #expect(!MailboxRouting.canReconcile(providerID: "monlycee", configs: [a, b, gmail]))
    }

    @Test("isSameMail: UID when both carry one, composite otherwise, never across providers")
    func isSameMailRule() {
        func row(_ uid: String?, provider: String? = "monlycee", subject: String = "S") -> Message {
            Message(sender: "a@lycee.fr", subject: subject, body: "", date: .now, source: .imap,
                    imapUID: uid, imapProvider: provider)
        }
        #expect(IMAPSyncService.isSameMail(row("1"), row("1")))
        #expect(!IMAPSyncService.isSameMail(row("1"), row("2")))
        #expect(!IMAPSyncService.isSameMail(row("1"), row("1", provider: "gmail")))
        #expect(IMAPSyncService.isSameMail(row(nil), row("1")))
        #expect(!IMAPSyncService.isSameMail(row(nil), row("1", subject: "Autre")))
    }

    private func sync(_ f: Fixture, _ configs: [IMAPServerConfig],
                      defaultChildren: [Child]? = nil,
                      fetched: [IMAPMessageInfo]? = nil) async {
        let service = IMAPSyncService(modelContext: f.ctx)
        let rows = fetched ?? batch
        _ = await service.syncAccounts(configs, children: [f.gaston, f.joseph],
                                       defaultChildren: defaultChildren, family: f.family,
                                       fetch: { _ in rows })
    }

    @Test("Tous → Parent: mail moves to the parent lane once, read state kept, no child copy left")
    func allChildrenToParentMoves() async throws {
        let f = try makeFixture()
        var config = account(.allChildren)
        await sync(f, [config])
        #expect(imapCount(f.gaston) == 1 && imapCount(f.joseph) == 1)
        f.gaston.messages.first { $0.source == .imap }?.read = true

        config.assignment = .parent
        await sync(f, [config])
        #expect(f.family.messages.count == 1)
        #expect(f.family.messages.first?.read == true)
        #expect(imapCount(f.gaston) == 0)
        #expect(imapCount(f.joseph) == 0)
        try f.ctx.save()
        let all = try f.ctx.fetch(FetchDescriptor<Message>())
        #expect(all.count == 1)
    }

    @Test("Tous → one child: the sibling's stale copy is removed, no reinsert")
    func allChildrenToOneChild() async throws {
        let f = try makeFixture()
        var config = account(.allChildren)
        await sync(f, [config])
        config.assignment = .child(id: MailboxRouting.childKey(f.joseph))
        await sync(f, [config])
        #expect(imapCount(f.joseph) == 1)
        #expect(imapCount(f.gaston) == 0)
        #expect(f.family.messages.isEmpty)
    }

    @Test("Parent → Tous: the parent row moves to a child, the others get theirs")
    func parentToAllChildren() async throws {
        let f = try makeFixture()
        var config = account(.parent)
        await sync(f, [config])
        config.assignment = .allChildren
        await sync(f, [config])
        #expect(f.family.messages.isEmpty)
        #expect(imapCount(f.gaston) == 1)
        #expect(imapCount(f.joseph) == 1)
    }

    @Test("rows outside the fetched page also follow the new assignment")
    func reconcileCoversOlderRows() async throws {
        let f = try makeFixture()
        var config = account(.allChildren)
        await sync(f, [config])
        config.assignment = .parent
        await sync(f, [config], fetched: [])
        #expect(f.family.messages.count == 1)
        #expect(imapCount(f.gaston) == 0 && imapCount(f.joseph) == 0)
    }

    @Test("Tous with a narrower default pool never evicts the other children's rows")
    func allChildrenDoesNotPingPong() async throws {
        let f = try makeFixture()
        let config = account(.allChildren)
        await sync(f, [config])                                   // École: every child
        await sync(f, [config], defaultChildren: [f.gaston])      // Actualités: Pronote pool
        #expect(imapCount(f.gaston) == 1)
        #expect(imapCount(f.joseph) == 1)
    }

    @Test("Pronote / SSO rows and other providers are never moved")
    func reconcileScope() async throws {
        let f = try makeFixture()
        let pronote = Message(sender: "prof@lycee.fr", subject: "Devoir", body: "", date: .now, source: .pronote)
        pronote.child = f.gaston
        f.ctx.insert(pronote)
        let gmailRow = Message(sender: "a@lycee.fr", subject: "G", body: "", date: .now, source: .imap,
                               imapUID: "9", imapProvider: "gmail")
        gmailRow.child = f.gaston
        f.ctx.insert(gmailRow)

        await sync(f, [account(.parent)])
        #expect(f.gaston.messages.contains { $0 === pronote })
        #expect(f.gaston.messages.contains { $0 === gmailRow })
        #expect(f.family.messages.count == 1)
    }

    @Test("two accounts on the same provider: no reconciliation, the sibling box is untouched")
    func ambiguousProviderSkipsReconcile() async throws {
        let f = try makeFixture()
        let a = account(.child(id: MailboxRouting.childKey(f.gaston)), username: "a@monlycee.net")
        let b = account(.parent, username: "b@monlycee.net")
        let service = IMAPSyncService(modelContext: f.ctx)
        // Twice: the second pass is where an unguarded reconcile would move
        // each box's rows into the other's lane.
        for _ in 0..<2 {
            _ = await service.syncAccounts(
                [a, b], children: [f.gaston, f.joseph], family: f.family,
                fetch: { config in
                    [IMAPMessageInfo(uid: config.username == "a@monlycee.net" ? 1 : 2,
                                     subject: config.username, from: "x@lycee.fr",
                                     date: .now, body: "", isRead: false)]
                }
            )
        }
        #expect(f.gaston.messages.first?.subject == "a@monlycee.net")
        #expect(f.family.messages.first?.subject == "b@monlycee.net")
        #expect(imapCount(f.gaston) == 1)
        #expect(f.family.messages.count == 1)
    }

    // MARK: - Parent lane vs. SSO channel

    @Test("a monlycée box set to Parent skips mail the SSO channel stored on a child")
    func parentLaneSkipsSSORowsOnChildren() async throws {
        let f = try makeFixture()
        let info = batch[0]
        let sso = Message(sender: info.from, subject: info.subject, body: "", date: info.date,
                          source: .monlycee, imapUID: "777", imapProvider: MonLyceeMailService.providerTag)
        sso.child = f.joseph
        f.ctx.insert(sso)

        await sync(f, [account(.parent)])
        #expect(f.family.messages.isEmpty)
        #expect(f.joseph.messages.count == 1)
    }
}
