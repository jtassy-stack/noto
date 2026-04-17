import Testing
import Foundation
@testable import Noto

/// Coverage for `IMAPService.decodeConfig` — the Phase-7 migration
/// path that hydrates legacy `imap_credentials_monlycee` Keychain
/// blobs into an `IMAPServerConfig` on first read.
///
/// If this drifts, every existing MonLycée user silently loses their
/// mailbox setup on app upgrade and has to re-authenticate. This is
/// the one path that can't be manually re-triggered — tests gate it.
@Suite("IMAPService.decodeConfig")
struct IMAPServiceDecodeTests {

    // MARK: - Primary v2 path

    @Test("Primary v2 data decodes to IMAPServerConfig directly")
    func primaryDecodes() throws {
        let config = IMAPServerConfig(
            host: "imap.gmail.com",
            port: 993,
            username: "parent@gmail.com",
            password: "secret",
            providerID: "gmail"
        )
        let data = try JSONEncoder().encode(config)

        let result = IMAPService.decodeConfig(primaryData: data, legacyData: nil)
        #expect(result?.host == "imap.gmail.com")
        #expect(result?.port == 993)
        #expect(result?.username == "parent@gmail.com")
        #expect(result?.password == "secret")
        #expect(result?.providerID == "gmail")
    }

    @Test("Primary wins over legacy when both present")
    func primaryTrumpsLegacy() throws {
        let primary = IMAPServerConfig(
            host: "imap.gmail.com",
            port: 993,
            username: "new@gmail.com",
            password: "new-pw",
            providerID: "gmail"
        )
        let legacy = LegacyMonLyceeCredentials(
            email: "old@monlycee.net",
            password: "old-pw"
        )
        let primaryData = try JSONEncoder().encode(primary)
        let legacyData = try JSONEncoder().encode(legacy)

        let result = IMAPService.decodeConfig(
            primaryData: primaryData,
            legacyData: legacyData
        )
        #expect(result?.username == "new@gmail.com")
        #expect(result?.providerID == "gmail")
    }

    // MARK: - Legacy MonLycée hydration (the critical migration path)

    @Test("Legacy MonLycée blob hydrates to imaps.monlycee.net:993")
    func legacyHydratesHost() throws {
        let legacy = LegacyMonLyceeCredentials(
            email: "prof@monlycee.net",
            password: "legacy-pw"
        )
        let data = try JSONEncoder().encode(legacy)

        let result = IMAPService.decodeConfig(primaryData: nil, legacyData: data)
        #expect(result?.host == "imaps.monlycee.net")
        #expect(result?.port == 993)
    }

    @Test("Legacy MonLycée blob hydrates providerID to 'monlycee'")
    func legacyHydratesProviderID() throws {
        let legacy = LegacyMonLyceeCredentials(
            email: "prof@monlycee.net",
            password: "legacy-pw"
        )
        let data = try JSONEncoder().encode(legacy)

        let result = IMAPService.decodeConfig(primaryData: nil, legacyData: data)
        #expect(result?.providerID == "monlycee")
    }

    @Test("Legacy MonLycée blob preserves credentials exactly")
    func legacyPreservesCredentials() throws {
        let legacy = LegacyMonLyceeCredentials(
            email: "prof.dupont@monlycee.net",
            password: "P@ssw0rd!"
        )
        let data = try JSONEncoder().encode(legacy)

        let result = IMAPService.decodeConfig(primaryData: nil, legacyData: data)
        #expect(result?.username == "prof.dupont@monlycee.net")
        #expect(result?.password == "P@ssw0rd!")
    }

    // MARK: - Miss paths

    @Test("Both nil returns nil")
    func bothNil() {
        #expect(IMAPService.decodeConfig(primaryData: nil, legacyData: nil) == nil)
    }

    @Test("Corrupted primary falls back to legacy")
    func corruptedPrimaryFallsBack() throws {
        let legacy = LegacyMonLyceeCredentials(
            email: "prof@monlycee.net",
            password: "pw"
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let garbage = Data("not json".utf8)

        let result = IMAPService.decodeConfig(primaryData: garbage, legacyData: legacyData)
        #expect(result?.providerID == "monlycee")
    }

    @Test("Corrupted primary + no legacy returns nil")
    func corruptedPrimaryNoLegacyReturnsNil() {
        let garbage = Data("not json".utf8)
        let result = IMAPService.decodeConfig(primaryData: garbage, legacyData: nil)
        #expect(result == nil)
    }

    @Test("Corrupted legacy + no primary returns nil")
    func corruptedLegacyNoPrimaryReturnsNil() {
        let garbage = Data("not json".utf8)
        let result = IMAPService.decodeConfig(primaryData: nil, legacyData: garbage)
        #expect(result == nil)
    }

    // MARK: - Multi-account UUID migration

    @Test("v2 blob without 'id' key decodes successfully with a fresh UUID")
    func v2BlobWithoutIdDecodesSuccessfully() throws {
        // Hand-craft a JSON payload matching the pre-multi-account schema (no 'id' key).
        // If this test fails after a Codable change, every upgrade from v2 loses mailbox access.
        let json = """
        {"host":"imap.gmail.com","port":993,"username":"parent@gmail.com",\
        "password":"secret","providerID":"gmail"}
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(IMAPServerConfig.self, from: data)
        #expect(config.host == "imap.gmail.com")
        #expect(config.username == "parent@gmail.com")
        #expect(config.providerID == "gmail")
        // id was synthesised — verify the field exists and is usable (UUID is non-optional)
        _ = config.id
    }

    @Test("Two decodes of the same v2 blob produce different UUIDs — caller must persist immediately")
    func v2BlobTwoDecodesDifferentUUIDs() throws {
        let json = """
        {"host":"imap.gmail.com","port":993,"username":"u@example.com",\
        "password":"pw","providerID":"gmail"}
        """
        let data = Data(json.utf8)
        let a = try JSONDecoder().decode(IMAPServerConfig.self, from: data)
        let b = try JSONDecoder().decode(IMAPServerConfig.self, from: data)
        // Each decode without a stored id creates a fresh UUID — this is expected
        // and the reason loadConfigs() must persist the migrated config immediately.
        #expect(a.id != b.id)
    }

    // MARK: - Password redaction

    @Test("Description redacts password — no accidental logging")
    func descriptionRedactsPassword() {
        let config = IMAPServerConfig(
            host: "imap.gmail.com",
            port: 993,
            username: "parent@gmail.com",
            password: "super-secret-password-123",
            providerID: "gmail"
        )
        let str = String(describing: config)
        #expect(!str.contains("super-secret-password-123"))
        #expect(str.contains("<redacted>"))
        // Non-sensitive fields still visible for diagnostics.
        #expect(str.contains("parent@gmail.com"))
        #expect(str.contains("imap.gmail.com"))
    }
}
