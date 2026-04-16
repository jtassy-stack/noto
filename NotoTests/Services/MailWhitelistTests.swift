import Testing
import Foundation
@testable import Noto

/// Coverage for `MailWhitelist` — auto-detection of school domain
/// from Pronote URLs + teacher email extraction + dedup across
/// sources.
@Suite("MailWhitelist")
struct MailWhitelistTests {

    // MARK: - School domain extraction

    @Test("Pronote URL yields registrable domain")
    func schoolDomainFromPronoteURL() {
        let domain = MailWhitelist.schoolDomain(
            from: "https://XXXXX.index-education.net/pronote"
        )
        #expect(domain == "index-education.net")
    }

    @Test("Bare domain string is returned as-is (lowercased)")
    func schoolDomainFromBareString() {
        let domain = MailWhitelist.schoolDomain(from: "Monlycee.NET")
        #expect(domain == "monlycee.net")
    }

    @Test("Free-form label with spaces returns nil")
    func schoolDomainFromFreeForm() {
        #expect(MailWhitelist.schoolDomain(from: "Collège Victor Hugo") == nil)
    }

    @Test("Subdomain is reduced to registrable domain")
    func schoolDomainReducesSubdomain() {
        let domain = MailWhitelist.schoolDomain(from: "https://sub.ent.iledefrance.fr/")
        #expect(domain == "iledefrance.fr")
    }

    // MARK: - Email extraction from sender

    @Test("RFC 5322 \"Name\" <email> yields email")
    func extractEmailFromRFC5322() {
        let email = MailWhitelist.extractEmail(
            from: "\"Mme Dupont\" <dupont@monlycee.net>"
        )
        #expect(email == "dupont@monlycee.net")
    }

    @Test("Name <email> (no quotes) yields email")
    func extractEmailFromNoQuotes() {
        let email = MailWhitelist.extractEmail(from: "M. Martin <martin@ecole.fr>")
        #expect(email == "martin@ecole.fr")
    }

    @Test("Bare email is returned lowercased")
    func extractBareEmail() {
        let email = MailWhitelist.extractEmail(from: "Admin@MonLycee.Net")
        #expect(email == "admin@monlycee.net")
    }

    @Test("Display-name only returns nil")
    func extractEmailFromDisplayNameOnly() {
        #expect(MailWhitelist.extractEmail(from: "Mme Dupont") == nil)
    }

    @Test("System identifier (no @) returns nil")
    func extractEmailFromSystemID() {
        #expect(MailWhitelist.extractEmail(from: "system-alert") == nil)
    }

    // MARK: - Entry normalisation

    @Test("Pattern is lowercased on init")
    func patternLowercased() {
        let entry = MailWhitelistEntry(pattern: "MonLycee.NET", source: .schoolDomain)
        #expect(entry.pattern == "monlycee.net")
    }

    @Test("isDomainPattern distinguishes domain vs email")
    func isDomainPatternDetection() {
        let domain = MailWhitelistEntry(pattern: "monlycee.net", source: .schoolDomain)
        let email = MailWhitelistEntry(pattern: "prof@monlycee.net", source: .teacherFromPronote)
        #expect(domain.isDomainPattern)
        #expect(!email.isDomainPattern)
    }

    // MARK: - Manual entry validation

    @Test("addManual rejects pattern without a dot")
    func addManualRejectsInvalidPattern() {
        #expect(throws: MailWhitelistError.self) {
            try MailWhitelist.addManual("notadomain")
        }
    }

    @Test("addManual rejects empty pattern")
    func addManualRejectsEmpty() {
        #expect(throws: MailWhitelistError.self) {
            try MailWhitelist.addManual("   ")
        }
    }
}
