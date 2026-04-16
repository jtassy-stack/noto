import Testing
import Foundation
@testable import Noto

/// Coverage for `ENTRegistry` — the bundled offline lookup that lets
/// nōto widen the mail whitelist to every domain a given ENT is
/// known to use (e.g., if the child's school runs on MonLycée, every
/// `*.monlycee.net` sender gets through automatically).
@Suite("ENTRegistry")
struct ENTRegistryTests {

    // MARK: - Bundle load

    @Test("Bundled ents.json loads with at least 20 entries")
    func bundledLoads() {
        let count = ENTRegistry.bundledENTs.count
        // 30 curated, but be tolerant of future trims/expansions.
        #expect(count >= 20)
    }

    @Test("Every bundled entry has id + name + non-empty domains")
    func bundledEntriesAreWellFormed() {
        for ent in ENTRegistry.bundledENTs {
            #expect(!ent.id.isEmpty)
            #expect(!ent.name.isEmpty)
            #expect(!ent.domains.isEmpty)
        }
    }

    // MARK: - Domain matching

    @Test("Exact domain matches its ENT")
    func matchExactDomain() {
        let ent = ENTRegistry.match(domain: "monlycee.net")
        #expect(ent?.id == "monlycee")
    }

    @Test("Subdomain matches the registrable ENT domain")
    func matchSubdomain() {
        let ent = ENTRegistry.match(domain: "xyz.monlycee.net")
        #expect(ent?.id == "monlycee")
    }

    @Test("URL-shaped input is parsed")
    func matchURLInput() {
        let ent = ENTRegistry.match(domain: "https://xyz.monlycee.net/welcome")
        #expect(ent?.id == "monlycee")
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let ent = ENTRegistry.match(domain: "MonLycee.NET")
        #expect(ent?.id == "monlycee")
    }

    @Test("Unknown domain returns nil")
    func noMatch() {
        #expect(ENTRegistry.match(domain: "random-school.example") == nil)
    }

    @Test("Free-form label (no dot) returns nil")
    func freeFormReturnsNil() {
        #expect(ENTRegistry.match(domain: "Collège Victor Hugo") == nil)
    }

    @Test("Pronote URL matches the pronote provider")
    func matchPronote() {
        let ent = ENTRegistry.match(domain: "https://xxxxx.index-education.net/pronote")
        #expect(ent?.id == "pronote")
    }

    // MARK: - allMailDomains

    @Test("allMailDomains flattens every bundled domain")
    func allMailDomainsFlatten() {
        let total = ENTRegistry.bundledENTs.reduce(0) { $0 + $1.domains.count }
        #expect(ENTRegistry.allMailDomains.count == total)
    }

    @Test("allMailDomains entries are lowercased")
    func allMailDomainsLowercase() {
        for d in ENTRegistry.allMailDomains {
            #expect(d == d.lowercased())
        }
    }

    // MARK: - extractHost

    @Test("extractHost accepts bare domain")
    func extractHostBare() {
        #expect(ENTRegistry.extractHost(from: "monlycee.net") == "monlycee.net")
    }

    @Test("extractHost accepts URL")
    func extractHostURL() {
        #expect(ENTRegistry.extractHost(from: "https://ent.example.com/path") == "ent.example.com")
    }

    @Test("extractHost returns nil for invalid input")
    func extractHostInvalid() {
        #expect(ENTRegistry.extractHost(from: "") == nil)
        #expect(ENTRegistry.extractHost(from: "nodot") == nil)
        #expect(ENTRegistry.extractHost(from: "has spaces") == nil)
    }
}
