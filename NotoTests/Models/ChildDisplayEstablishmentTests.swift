import Testing
@testable import Noto

/// Regression guard for the Pronote URL leak fix (PR #6 → PR #7).
///
/// `Child.establishment` is populated from the Pronote refresh-token URL
/// when the parent logs in via QR code, so the raw server hostname
/// (e.g. `https://0752546k.index-education.net/pronote/...`) ends up
/// stored on the model. `displayEstablishment` must mask any URL-shaped
/// value so a parent-facing label never exposes that hostname.
@Suite("Child.displayEstablishment")
struct ChildDisplayEstablishmentTests {

    @Test("Pronote URL is masked as 'Pronote'")
    func pronoteURL() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "https://0752546k.index-education.net/pronote/mobile.parent.html"
        )
        #expect(child.displayEstablishment == "Pronote")
    }

    @Test("Any index-education subdomain is masked")
    func indexEducationVariant() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "https://demo.index-education.net/pronote/"
        )
        #expect(child.displayEstablishment == "Pronote")
    }

    @Test("Uppercase HTTPS scheme is still masked (RFC 3986 case-insensitive)")
    func uppercaseScheme() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "HTTPS://0752546k.index-education.net/pronote/"
        )
        #expect(child.displayEstablishment == "Pronote")
    }

    @Test("Uppercase host is still masked")
    func uppercaseHost() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "https://0752546K.INDEX-EDUCATION.NET/pronote/"
        )
        #expect(child.displayEstablishment == "Pronote")
    }

    @Test("Pronote URL with explicit port is masked")
    func pronoteURLWithPort() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "https://0752546k.index-education.net:443/pronote/"
        )
        #expect(child.displayEstablishment == "Pronote")
    }

    @Test("PCN ENT URL falls back to provider name")
    func entPCNURL() {
        let child = makeChild(
            schoolType: .ent,
            establishment: "https://ent.parisclassenumerique.fr/timeline/"
        )
        child.entProvider = .pcn
        #expect(child.displayEstablishment == "Paris Classe Numérique")
    }

    @Test("ENT URL without provider falls back to 'ENT'")
    func entURLNoProvider() {
        let child = makeChild(
            schoolType: .ent,
            establishment: "https://some-school.fr"
        )
        // No entProvider set → generic "ENT" label (still masks the hostname)
        #expect(child.displayEstablishment == "ENT")
    }

    @Test("Pronote schoolType with non-Pronote URL falls back to 'École'")
    func pronoteTypeWithUnknownURL() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "https://random-host.example.com"
        )
        #expect(child.displayEstablishment == "École")
    }

    @Test("Friendly establishment name passes through unchanged")
    func friendlyName() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: "Collège Jean Moulin"
        )
        #expect(child.displayEstablishment == "Collège Jean Moulin")
    }

    @Test("Empty string passes through unchanged")
    func emptyString() {
        let child = makeChild(
            schoolType: .pronote,
            establishment: ""
        )
        #expect(child.displayEstablishment == "")
    }

    @Test("Malformed http:// with no host masks via generic fallback")
    func malformedNoHost() {
        // Anything URL-shaped must never pass through to the parent-facing label —
        // even a host-less http:// is treated as a leak vector and replaced.
        let child = makeChild(
            schoolType: .pronote,
            establishment: "http://"
        )
        #expect(child.displayEstablishment == "École")
    }

    // MARK: - Helpers

    private func makeChild(schoolType: SchoolType, establishment: String) -> Child {
        Child(
            firstName: "Test",
            level: .college,
            grade: "3e",
            schoolType: schoolType,
            establishment: establishment
        )
    }
}
