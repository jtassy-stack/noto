import Testing
import Foundation
@testable import Noto

/// Guards the `isDedicatedSchoolChannel` rule — the single source of
/// truth that drives whitelist bypass in `IMAPSyncService` and the
/// dedicated-channel UI framing in `MailDomainsView` / setup / feed
/// badge.
///
/// If a future edit accidentally widens or narrows the rule, several
/// invariants break at once:
///   - Gmail users suddenly skip filtering (personal mail leaks).
///   - MonLycée users get `.emptyWhitelist` thrown (no mail synced).
///   - Feed badge mislabels the source.
/// This suite is cheap insurance against all three.
@Suite("IMAPServerConfig.isDedicatedSchoolChannel")
struct IMAPServerConfigTests {

    // MARK: - Rule: only "monlycee" is a dedicated school channel

    @Test("monlycee providerID is a dedicated school channel")
    func monLyceeIsDedicated() {
        #expect(IMAPServerConfig.isDedicatedSchoolChannel(providerID: "monlycee"))
    }

    @Test("gmail providerID is NOT a dedicated school channel")
    func gmailIsNotDedicated() {
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "gmail"))
    }

    @Test("outlook providerID is NOT a dedicated school channel")
    func outlookIsNotDedicated() {
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "outlook"))
    }

    @Test("icloud providerID is NOT a dedicated school channel")
    func iCloudIsNotDedicated() {
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "icloud"))
    }

    @Test("custom providerID is NOT a dedicated school channel")
    func customIsNotDedicated() {
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "custom"))
    }

    // MARK: - Instance property delegates to the static rule

    @Test("config built from monlycee preset reports dedicated channel")
    func configPropertyFromPreset() {
        let preset = IMAPServerConfig.Preset(
            host: "imaps.monlycee.net",
            port: 993,
            providerID: "monlycee"
        )
        let config = IMAPServerConfig(preset: preset, username: "x@monlycee.net", password: "x")
        #expect(config.isDedicatedSchoolChannel)
        #expect(preset.isDedicatedSchoolChannel)
    }

    @Test("config built from gmail preset does NOT report dedicated channel")
    func gmailConfigProperty() {
        let preset = IMAPServerConfig.Preset(
            host: "imap.gmail.com",
            port: 993,
            providerID: "gmail"
        )
        let config = IMAPServerConfig(preset: preset, username: "x@gmail.com", password: "x")
        #expect(!config.isDedicatedSchoolChannel)
        #expect(!preset.isDedicatedSchoolChannel)
    }

    // MARK: - Case sensitivity guard

    @Test("providerID match is case-sensitive — stays in sync with resolver")
    func providerIDIsCaseSensitive() {
        // The resolver stores lowercase IDs by construction. If a future
        // edit introduces a capitalised form (e.g. "MonLycee"), catching
        // it here prevents a silent filter-bypass regression for
        // non-monlycée users or an over-filter for monlycée users.
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "MonLycee"))
        #expect(!IMAPServerConfig.isDedicatedSchoolChannel(providerID: "MONLYCEE"))
    }
}
