import Testing
import Foundation
@testable import Noto

/// Coverage for `MailFilter.shouldKeep` — the gate that keeps the
/// parent's personal mail (Amazon receipts, newsletters, etc.) out
/// of nōto's SwiftData store while letting school comms through.
@Suite("MailFilter")
struct MailFilterTests {

    private func domainEntry(_ pattern: String) -> MailWhitelistEntry {
        MailWhitelistEntry(pattern: pattern, source: .schoolDomain)
    }

    private func emailEntry(_ pattern: String) -> MailWhitelistEntry {
        MailWhitelistEntry(pattern: pattern, source: .teacherFromPronote)
    }

    // MARK: - Domain matching

    @Test("Exact domain match passes")
    func keepsExactDomain() {
        let wl = [domainEntry("monlycee.net")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "admin@monlycee.net",
            subject: "Réunion",
            whitelist: wl
        ))
    }

    @Test("Subdomain passes when whitelist has the registrable domain")
    func keepsSubdomain() {
        let wl = [domainEntry("index-education.net")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "noreply@xxxxx.index-education.net",
            subject: "Notification",
            whitelist: wl
        ))
    }

    @Test("Personal Gmail is dropped when not in whitelist")
    func rejectsPersonalGmail() {
        let wl = [domainEntry("monlycee.net")]
        #expect(!MailFilter.shouldKeep(
            senderAddress: "friend@gmail.com",
            subject: "Hello",
            whitelist: wl
        ))
    }

    @Test("Amazon newsletter is dropped")
    func rejectsAmazon() {
        let wl = [domainEntry("monlycee.net"), domainEntry("ecole.fr")]
        #expect(!MailFilter.shouldKeep(
            senderAddress: "marketing@amazon.fr",
            subject: "Vos offres",
            whitelist: wl
        ))
    }

    // MARK: - Exact email matching

    @Test("Exact teacher email match passes")
    func keepsExactTeacherEmail() {
        let wl = [emailEntry("dupont@monlycee.net")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "dupont@monlycee.net",
            subject: "Devoir",
            whitelist: wl
        ))
    }

    @Test("Different email on same domain is dropped when only exact email is whitelisted")
    func rejectsOtherEmailOnSameDomain() {
        // Only exact email whitelisted, not the whole domain
        let wl = [emailEntry("dupont@monlycee.net")]
        #expect(!MailFilter.shouldKeep(
            senderAddress: "martin@monlycee.net",
            subject: "Test",
            whitelist: wl
        ))
    }

    // MARK: - Case insensitivity

    @Test("Sender domain is matched case-insensitively")
    func caseInsensitiveDomain() {
        let wl = [domainEntry("monlycee.net")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "Admin@MonLycee.NET",
            subject: "Test",
            whitelist: wl
        ))
    }

    // MARK: - RFC 5322 sender parsing

    @Test("\"Name\" <email@domain> format is parsed")
    func parsesRFC5322() {
        let wl = [domainEntry("monlycee.net")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "\"Mme Dupont\" <dupont@monlycee.net>",
            subject: "Réunion",
            whitelist: wl
        ))
    }

    @Test("Name <email@domain> format (no quotes) is parsed")
    func parsesRFC5322NoQuotes() {
        let wl = [domainEntry("ecole.fr")]
        #expect(MailFilter.shouldKeep(
            senderAddress: "M. Martin <martin@ecole.fr>",
            subject: "Hello",
            whitelist: wl
        ))
    }

    // MARK: - Edge cases

    @Test("Empty whitelist rejects everything")
    func emptyWhitelistRejectsAll() {
        #expect(!MailFilter.shouldKeep(
            senderAddress: "anyone@anywhere.com",
            subject: "Test",
            whitelist: []
        ))
    }

    @Test("Non-email sender is dropped")
    func rejectsNonEmailSender() {
        let wl = [domainEntry("monlycee.net")]
        #expect(!MailFilter.shouldKeep(
            senderAddress: "system-notification",
            subject: "Test",
            whitelist: wl
        ))
    }

    @Test("Both domain and email match → kept")
    func multipleMatchTypes() {
        let wl = [
            domainEntry("monlycee.net"),
            emailEntry("dupont@monlycee.net")
        ]
        #expect(MailFilter.shouldKeep(
            senderAddress: "dupont@monlycee.net",
            subject: "Test",
            whitelist: wl
        ))
    }
}
