import Testing
@testable import Noto

/// The "Connecter MonLycée.net" prompt must not push a parent towards the
/// monlycee.net IMAP preset when the ENT SSO channel already delivers that
/// inbox — the two channels would then import the same mail twice.
@Suite("ActualitesView MonLycée prompt")
@MainActor
struct ActualitesMonLyceePromptTests {

    @Test func shownWithoutIMAPNorMonLyceeChild() {
        #expect(ActualitesView.showsMonLyceePrompt(imapConfigured: false, childProviders: [nil, .pcn]))
    }

    @Test func hiddenWhenAChildUsesMonLyceeSSO() {
        #expect(!ActualitesView.showsMonLyceePrompt(imapConfigured: false, childProviders: [nil, .monlycee]))
    }

    @Test func hiddenWhenIMAPConfigured() {
        #expect(!ActualitesView.showsMonLyceePrompt(imapConfigured: true, childProviders: []))
    }
}
