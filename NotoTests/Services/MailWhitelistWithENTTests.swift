import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for the MailWhitelist × ENTRegistry integration added in
/// Phase 8: when a child's establishment matches a known ENT, every
/// domain that ENT is known to use is added to the whitelist as
/// `.entProvider` entries (distinct from `.schoolDomain` extraction).
@Suite("MailWhitelist + ENTRegistry")
@MainActor
struct MailWhitelistWithENTTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(establishment: String, in ctx: ModelContext) -> Child {
        let c = Child(
            firstName: "Test",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: establishment
        )
        ctx.insert(c)
        return c
    }

    // MARK: - Cases

    @Test("Pronote establishment → school domain + pronote ENT domains added")
    func pronoteEstablishmentExpands() throws {
        let ctx = try makeContext()
        let child = makeChild(
            establishment: "https://xxxxx.index-education.net/pronote",
            in: ctx
        )
        let entries = MailWhitelist.build(from: [child])

        // schoolDomain adds "index-education.net"
        #expect(entries.contains { $0.source == .schoolDomain && $0.pattern == "index-education.net" })

        // ENTRegistry match adds every pronote-known domain
        let entProviderDomains = entries.filter { $0.source == .entProvider }.map(\.pattern)
        #expect(entProviderDomains.contains("index-education.net") || entProviderDomains.contains("index-education.fr"))
    }

    @Test("MonLycée establishment widens the whitelist beyond the school domain")
    func monlyceeExpands() throws {
        let ctx = try makeContext()
        let child = makeChild(establishment: "https://ent.monlycee.net", in: ctx)
        let entries = MailWhitelist.build(from: [child])

        // `monlycee.net` gets added as schoolDomain (registrable extractor
        // wins the dedup race). The ENT match should contribute at least
        // one additional domain — the Île-de-France ENT alias.
        let allDomains = entries.map(\.pattern)
        #expect(allDomains.contains("monlycee.net"))
        #expect(allDomains.contains("ent.iledefrance.fr"))
        #expect(entries.contains { $0.source == .entProvider })
    }

    @Test("Unknown establishment yields no .entProvider entries")
    func unknownEstablishmentYieldsNoEntEntries() throws {
        let ctx = try makeContext()
        let child = makeChild(establishment: "Collège Jean Moulin", in: ctx)
        let entries = MailWhitelist.build(from: [child])

        let entDomains = entries.filter { $0.source == .entProvider }
        #expect(entDomains.isEmpty)
    }

    @Test("Dedup: domain appears once even if schoolDomain and ENT both produce it")
    func dedupAcrossSources() throws {
        let ctx = try makeContext()
        // This establishment is matched both by the bare-domain extractor
        // (schoolDomain) AND by ENTRegistry (pronote provider). The dedup
        // should ensure "index-education.net" only shows up once.
        let child = makeChild(
            establishment: "https://xxxxx.index-education.net/pronote",
            in: ctx
        )
        let entries = MailWhitelist.build(from: [child])

        let indexEducation = entries.filter { $0.pattern == "index-education.net" }
        #expect(indexEducation.count == 1)
    }
}
