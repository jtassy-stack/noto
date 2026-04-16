import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for the MailWhitelist × DirectoryAPI integration (Phase 8.5):
/// when a child has an `rneCode` and the caller has pre-fetched the
/// matching `DirectorySchool`, its authoritative `mailDomains` supersede
/// the bundled ENTRegistry inference.
///
/// The builder stays sync on purpose — callers fetch + cache the
/// `DirectorySchool` map, then hand it in. This keeps IMAP sync off the
/// network on every message.
@Suite("MailWhitelist + DirectoryAPI")
@MainActor
struct MailWhitelistWithDirectoryTests {

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(
        rne: String?,
        establishment: String,
        in ctx: ModelContext
    ) -> Child {
        let c = Child(
            firstName: "Test",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: establishment,
            rneCode: rne
        )
        ctx.insert(c)
        return c
    }

    private func makeSchool(
        rne: String,
        mailDomains: [String],
        entID: String? = nil
    ) -> DirectorySchool {
        DirectorySchool(
            rne: rne,
            name: "Test School",
            kind: "college",
            academy: "Créteil",
            holidayZone: "C",
            website: nil,
            commune: nil,
            ent: entID.map { DirectoryENTRef(id: $0, name: "Test ENT", domains: []) },
            services: [],
            mailDomains: mailDomains
        )
    }

    // MARK: - Directory path

    @Test("Child with matching RNE → directory mailDomains are added as .directoryAPI")
    func directoryMatchAddsMailDomains() throws {
        let ctx = try makeContext()
        let child = makeChild(
            rne: "0930122Y",
            establishment: "https://xxxxx.index-education.net/pronote",
            in: ctx
        )
        let school = makeSchool(
            rne: "0930122Y",
            mailDomains: ["monlycee.net", "ac-creteil.fr", "portail-famille.saintdenis.fr"]
        )

        let entries = MailWhitelist.build(
            from: [child],
            directorySchools: ["0930122Y": school]
        )

        let directory = entries.filter { $0.source == .directoryAPI }.map(\.pattern)
        #expect(directory.contains("monlycee.net"))
        #expect(directory.contains("ac-creteil.fr"))
        #expect(directory.contains("portail-famille.saintdenis.fr"))
    }

    @Test("Directory match replaces ENT registry inference (no double-add from both sources)")
    func directoryWinsOverENTRegistry() throws {
        let ctx = try makeContext()
        // Establishment would normally match ENTRegistry for Pronote.
        // With a matching directory school, we expect NO .entProvider entries.
        let child = makeChild(
            rne: "0930122Y",
            establishment: "https://xxxxx.index-education.net/pronote",
            in: ctx
        )
        let school = makeSchool(rne: "0930122Y", mailDomains: ["monlycee.net"])

        let entries = MailWhitelist.build(
            from: [child],
            directorySchools: ["0930122Y": school]
        )

        #expect(!entries.contains { $0.source == .entProvider })
    }

    @Test("Child without RNE → falls back to ENTRegistry (pre-8.6 behaviour preserved)")
    func noRneFallsBackToENTRegistry() throws {
        let ctx = try makeContext()
        let child = makeChild(
            rne: nil,
            establishment: "https://ent.monlycee.net",
            in: ctx
        )
        let entries = MailWhitelist.build(from: [child], directorySchools: [:])

        #expect(entries.contains { $0.source == .entProvider })
    }

    @Test("Child with RNE but no directory entry → still falls back to ENTRegistry")
    func unresolvedRneFallsBack() throws {
        let ctx = try makeContext()
        let child = makeChild(
            rne: "0930122Y",
            establishment: "https://ent.monlycee.net",
            in: ctx
        )
        // Map is empty — the caller didn't fetch this school (cache miss).
        let entries = MailWhitelist.build(from: [child], directorySchools: [:])

        #expect(entries.contains { $0.source == .entProvider })
    }

    @Test("Directory match does NOT short-circuit teacher-email extraction")
    func directoryDoesNotBlockTeacherEmails() throws {
        // Load-bearing invariant: a child with an RNE + directory match
        // must STILL have its message senders added to the whitelist.
        // If someone refactors the branch into an `if/else { return }`,
        // this test fails before IMAP sync silently drops teacher replies.
        let ctx = try makeContext()
        let child = makeChild(
            rne: "0930122Y",
            establishment: "https://xxxxx.index-education.net/pronote",
            in: ctx
        )
        let message = Message(
            sender: "\"Mme Dupont\" <dupont@col.fr>",
            subject: "Réunion parents",
            body: "",
            date: .now,
            source: .imap
        )
        ctx.insert(message)
        child.messages = [message]

        let school = makeSchool(rne: "0930122Y", mailDomains: ["monlycee.net"])
        let entries = MailWhitelist.build(
            from: [child],
            directorySchools: ["0930122Y": school]
        )

        #expect(entries.contains { $0.source == .directoryAPI && $0.pattern == "monlycee.net" })
        #expect(entries.contains { $0.source == .teacherFromPronote && $0.pattern == "dupont@col.fr" })
    }

    @Test("Dedup — directory and schoolDomain both producing 'monlycee.net' appears once")
    func directoryDedupesWithSchoolDomain() throws {
        let ctx = try makeContext()
        let child = makeChild(
            rne: "0930122Y",
            establishment: "https://ent.monlycee.net",
            in: ctx
        )
        let school = makeSchool(rne: "0930122Y", mailDomains: ["monlycee.net", "ac-creteil.fr"])

        let entries = MailWhitelist.build(
            from: [child],
            directorySchools: ["0930122Y": school]
        )

        let count = entries.filter { $0.pattern == "monlycee.net" }.count
        #expect(count == 1)
    }

    @Test("Backward compat — build(from:) without directorySchools stays sync + works as before")
    func defaultParamPreservesOldBehaviour() throws {
        let ctx = try makeContext()
        let child = makeChild(
            rne: nil,
            establishment: "https://ent.monlycee.net",
            in: ctx
        )
        let entries = MailWhitelist.build(from: [child])
        #expect(entries.contains { $0.pattern == "monlycee.net" })
    }
}
