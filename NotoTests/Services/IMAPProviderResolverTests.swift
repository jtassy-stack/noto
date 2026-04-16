import Testing
import Foundation
@testable import Noto

/// Truth table for `IMAPProviderResolver`. The resolver is the only
/// bridge from "user's email" to "server config" — if it drifts,
/// onboarding silently sends credentials to the wrong host.
@Suite("IMAPProviderResolver")
struct IMAPProviderResolverTests {

    // MARK: - Known providers

    @Test("gmail.com resolves to imap.gmail.com:993")
    func resolveGmail() {
        let preset = IMAPProviderResolver.resolve(email: "parent@gmail.com")
        #expect(preset?.host == "imap.gmail.com")
        #expect(preset?.port == 993)
        #expect(preset?.providerID == "gmail")
    }

    @Test("googlemail.com (alias) also resolves to imap.gmail.com")
    func resolveGooglemailAlias() {
        let preset = IMAPProviderResolver.resolve(email: "parent@googlemail.com")
        #expect(preset?.host == "imap.gmail.com")
        #expect(preset?.providerID == "gmail")
    }

    @Test("outlook.com resolves to outlook.office365.com")
    func resolveOutlook() {
        let preset = IMAPProviderResolver.resolve(email: "parent@outlook.com")
        #expect(preset?.host == "outlook.office365.com")
        #expect(preset?.port == 993)
        #expect(preset?.providerID == "outlook")
    }

    @Test("hotmail.fr resolves as outlook provider")
    func resolveHotmailFR() {
        let preset = IMAPProviderResolver.resolve(email: "parent@hotmail.fr")
        #expect(preset?.host == "outlook.office365.com")
        #expect(preset?.providerID == "outlook")
    }

    @Test("icloud.com resolves to imap.mail.me.com")
    func resolveICloud() {
        let preset = IMAPProviderResolver.resolve(email: "parent@icloud.com")
        #expect(preset?.host == "imap.mail.me.com")
        #expect(preset?.port == 993)
        #expect(preset?.providerID == "icloud")
    }

    @Test("monlycee.net resolves to imaps.monlycee.net — pins legacy behaviour")
    func resolveMonLycee() {
        let preset = IMAPProviderResolver.resolve(email: "prof@monlycee.net")
        #expect(preset?.host == "imaps.monlycee.net")
        #expect(preset?.port == 993)
        #expect(preset?.providerID == "monlycee")
    }

    // MARK: - Case insensitivity

    @Test("Domain match is case-insensitive")
    func caseInsensitiveDomain() {
        let preset = IMAPProviderResolver.resolve(email: "USER@Gmail.COM")
        #expect(preset?.host == "imap.gmail.com")
    }

    // MARK: - Fallback

    @Test("Unknown domain falls back to imap.{domain} with providerID=custom")
    func resolveUnknownFallback() {
        let preset = IMAPProviderResolver.resolve(email: "user@custom-school.org")
        #expect(preset?.host == "imap.custom-school.org")
        #expect(preset?.port == 993)
        #expect(preset?.providerID == "custom")
    }

    // MARK: - Invalid inputs

    @Test("Not-an-email returns nil")
    func notAnEmailReturnsNil() {
        #expect(IMAPProviderResolver.resolve(email: "not-an-email") == nil)
    }

    @Test("Missing @ returns nil")
    func missingAtReturnsNil() {
        #expect(IMAPProviderResolver.resolve(email: "userexample.com") == nil)
    }

    @Test("Missing local part returns nil")
    func missingLocalPartReturnsNil() {
        #expect(IMAPProviderResolver.resolve(email: "@gmail.com") == nil)
    }

    @Test("Missing TLD returns nil")
    func missingTLDReturnsNil() {
        #expect(IMAPProviderResolver.resolve(email: "user@localhost") == nil)
    }

    // MARK: - Whitespace

    @Test("Whitespace is trimmed")
    func trimsWhitespace() {
        let preset = IMAPProviderResolver.resolve(email: "  parent@gmail.com  ")
        #expect(preset?.host == "imap.gmail.com")
    }
}
