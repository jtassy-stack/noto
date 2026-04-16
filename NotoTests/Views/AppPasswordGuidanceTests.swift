import Testing
import Foundation
@testable import Noto

/// Coverage for `AppPasswordGuidance` — the factory that maps IMAP
/// provider IDs to user-facing app-password guidance, and the error
/// classifier that turns an IMAP failure into a parent-addressed
/// French message. A typo in a provider ID string (e.g. "gmail" → "gmai")
/// silently suppresses the help card, which is exactly the dead-end
/// this code exists to prevent — so the factory is exercised here
/// against each supported provider.
@Suite("AppPasswordGuidance")
struct AppPasswordGuidanceTests {

    // MARK: - forProviderID

    @Test("gmail returns Gmail guidance with Google app-password URL")
    func gmailGuidance() {
        let g = AppPasswordGuidance.forProviderID("gmail")
        #expect(g?.label == "Gmail")
        #expect(g?.setupURL.scheme == "https")
        #expect(g?.setupURL.host == "myaccount.google.com")
        #expect(!(g?.steps.isEmpty ?? true))
    }

    @Test("icloud returns iCloud guidance with Apple ID URL")
    func icloudGuidance() {
        let g = AppPasswordGuidance.forProviderID("icloud")
        #expect(g?.label == "iCloud")
        #expect(g?.setupURL.scheme == "https")
        #expect(g?.setupURL.host == "account.apple.com")
        #expect(!(g?.steps.isEmpty ?? true))
    }

    @Test("outlook returns Outlook guidance with Microsoft URL")
    func outlookGuidance() {
        let g = AppPasswordGuidance.forProviderID("outlook")
        #expect(g?.label == "Outlook / Hotmail")
        #expect(g?.setupURL.scheme == "https")
        #expect(g?.setupURL.host == "account.microsoft.com")
        #expect(!(g?.steps.isEmpty ?? true))
    }

    @Test("monlycee returns nil — basic auth still works there")
    func monlyceeReturnsNil() {
        #expect(AppPasswordGuidance.forProviderID("monlycee") == nil)
    }

    @Test("custom returns nil — self-hosted/ISP boxes don't enforce app passwords")
    func customReturnsNil() {
        #expect(AppPasswordGuidance.forProviderID("custom") == nil)
    }

    @Test("unknown IDs return nil", arguments: ["", "gmai", "GMAIL", "google", "foo"])
    func unknownReturnsNil(id: String) {
        #expect(AppPasswordGuidance.forProviderID(id) == nil)
    }

    // MARK: - userErrorMessage

    private func preset(_ id: String, host: String = "imap.example.com") -> IMAPServerConfig.Preset {
        IMAPServerConfig.Preset(host: host, port: 993, providerID: id)
    }

    private func error(_ description: String) -> Error {
        NSError(
            domain: "TestIMAP",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    @Test("Gmail 'Application-specific password required' → 'refuse votre mot de passe de compte'")
    func gmailSpecificPasswordRequired() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Application-specific password required"),
            preset: preset("gmail")
        )
        #expect(msg.contains("Gmail"))
        #expect(msg.contains("mot de passe de compte"))
    }

    @Test("Gmail 'Web login required' → provider-specific message")
    func gmailWebLoginRequired() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Web login required"),
            preset: preset("gmail")
        )
        #expect(msg.contains("Gmail"))
        #expect(msg.contains("mot de passe d'application"))
    }

    @Test("Outlook 'INVALIDSECONDFACTOR' → provider-specific message (third trigger)")
    func outlookInvalidSecondFactor() {
        // Locks the third `needsAppPasswordHint` substring. Drop it and
        // this test catches it — otherwise Outlook 2FA errors silently
        // regress to a generic "identifiants incorrects" message.
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("AUTHENTICATE failed: InvalidSecondFactor"),
            preset: preset("outlook")
        )
        #expect(msg.contains("Outlook"))
        #expect(msg.contains("mot de passe d'application"))
    }

    @Test("Custom provider hitting an app-password trigger string → no provider message (fallthrough)")
    func customProviderWithAppPasswordTrigger() {
        // Self-hosted / ISP server returns "web login required"-ish text
        // but has no `AppPasswordGuidance`. Must fall through to the
        // unclassified wrapper, not emit a bogus provider-less app-password
        // message. Locks the behaviour against a future refactor that
        // might accidentally coerce `guidance` to a default.
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Web login required"),
            preset: preset("custom", host: "imap.myschool.fr")
        )
        #expect(!msg.contains("mot de passe d'application"))
        #expect(!msg.contains("mot de passe de compte"))
    }

    @Test("Gmail bare AUTHENTICATIONFAILED → 'copié sans espace' typo hint, not regenerate")
    func gmailBareAuthFailed() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("AUTHENTICATIONFAILED Invalid credentials"),
            preset: preset("gmail")
        )
        #expect(msg.contains("Gmail"))
        #expect(msg.contains("sans espace"))
        // Must NOT push the user to regenerate an app password when they
        // likely just mistyped the existing one.
        #expect(!msg.contains("refuse votre mot de passe de compte"))
    }

    @Test("Regression: 'app password rate-limited' must not misroute to 'refuse main password'")
    func ratelimitedAppPasswordDoesNotFalsePositive() {
        // Before the fix, bare `msg.contains("app password")` matched this
        // and told the user "Gmail refuse votre mot de passe de compte"
        // — misleading when the real cause is rate-limiting.
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Too many app password attempts, rate-limited"),
            preset: preset("gmail")
        )
        #expect(!msg.contains("refuse votre mot de passe de compte"))
    }

    @Test("Custom provider auth failure → generic 'Identifiants incorrects', no app-password hint")
    func customAuthFailure() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("authentication failed"),
            preset: preset("custom")
        )
        #expect(msg.contains("Identifiants incorrects"))
        #expect(!msg.contains("mot de passe d'application"))
    }

    @Test("Network error for custom provider surfaces the host (aids self-hosted debugging)")
    func customNetworkErrorMentionsHost() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Connection timeout"),
            preset: preset("custom", host: "imap.myschool.fr")
        )
        #expect(msg.contains("imap.myschool.fr"))
    }

    @Test("Network error for known provider hides host (generic message)")
    func gmailNetworkErrorHidesHost() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("Network connection lost"),
            preset: preset("gmail")
        )
        #expect(!msg.contains("imap.gmail.com"))
        #expect(msg.contains("connexion"))
    }

    @Test("Unclassified error falls through with French wrapper, not bare English leak")
    func unclassifiedErrorWrappedInFrench() {
        let msg = AppPasswordGuidance.userErrorMessage(
            for: error("errSSLPeerHandshakeFail"),
            preset: preset("gmail")
        )
        #expect(msg.contains("Détail technique"))
        #expect(msg.contains("errSSLPeerHandshakeFail"))
    }
}
