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
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
}
