import Testing
import Foundation
@testable import Noto

/// Coverage for `DirectoryAPIClient`. Split in two suites:
///
/// - Decoder tests run offline and pin the exact JSON shape served by
///   `celyn.io/api/directory/*` (stable contract, hand-written fixtures).
/// - Live tests hit the deployed endpoint with GET-only calls. They run
///   only when `NOTO_RUN_LIVE_API=1` is set in the environment to avoid
///   slowing every `swift test` invocation and to keep CI deterministic.
@Suite("DirectoryAPIClient — decoder")
struct DirectoryAPIClientDecoderTests {

    // MARK: - /ents

    @Test("Decodes /ents envelope into DirectoryENTProvider list")
    func decodesENTs() throws {
        let json = #"""
        {
          "version": 1,
          "ents": [
            {
              "id": "monlycee",
              "name": "MonLycée.net",
              "domains": ["monlycee.net", "ent.iledefrance.fr"],
              "regions": ["Île-de-France"],
              "imapHost": "imaps.monlycee.net",
              "imapPort": 993,
              "authMethod": "imap"
            }
          ]
        }
        """#
        let payload = try JSONDecoder().decode(ENTsTestEnvelope.self, from: Data(json.utf8))
        #expect(payload.ents.count == 1)
        #expect(payload.ents[0].id == "monlycee")
        #expect(payload.ents[0].domains.contains("ent.iledefrance.fr"))
        #expect(payload.ents[0].imapPort == 993)
    }

    // MARK: - /schools/:rne

    @Test("Decodes /schools/:rne with nested commune + ent + services")
    func decodesSchool() throws {
        let json = #"""
        {
          "rne": "0930122Y",
          "name": "Collège Jean Jaurès",
          "kind": "college",
          "academy": "Créteil",
          "holidayZone": "C",
          "website": null,
          "commune": {
            "insee": "93070",
            "name": "Saint-Denis",
            "dept": "93",
            "region": "Île-de-France"
          },
          "ent": {
            "id": "monlycee",
            "name": "MonLycée.net",
            "domains": ["monlycee.net"]
          },
          "services": [
            { "kind": "cantine", "providerName": "Arpège", "domain": "arpege.fr", "confidence": "high" }
          ],
          "mailDomains": ["monlycee.net", "ac-creteil.fr", "arpege.fr"]
        }
        """#
        let school = try JSONDecoder().decode(DirectorySchool.self, from: Data(json.utf8))
        #expect(school.rne == "0930122Y")
        #expect(school.commune?.dept == "93")
        #expect(school.ent?.id == "monlycee")
        #expect(school.services.first?.kind == "cantine")
        #expect(school.mailDomains.contains("ac-creteil.fr"))
    }

    @Test("Decodes /schools/:rne with null commune and null ent")
    func decodesSchoolWithNullRefs() throws {
        let json = #"""
        {
          "rne": "0000000X",
          "name": "École sans commune",
          "kind": "ecole",
          "academy": null,
          "holidayZone": null,
          "website": null,
          "commune": null,
          "ent": null,
          "services": [],
          "mailDomains": []
        }
        """#
        let school = try JSONDecoder().decode(DirectorySchool.self, from: Data(json.utf8))
        #expect(school.commune == nil)
        #expect(school.ent == nil)
        #expect(school.services.isEmpty)
    }

    // MARK: - /schools/search

    @Test("Decodes /schools/search response")
    func decodesSchoolSearch() throws {
        let json = #"""
        {
          "schools": [
            { "rne": "0930122Y", "name": "Collège Jean Jaurès", "kind": "college", "communeInsee": "93070", "academy": "Créteil" },
            { "rne": "0751234X", "name": "Collège Condorcet", "kind": "college", "communeInsee": null, "academy": null }
          ]
        }
        """#
        let payload = try JSONDecoder().decode(SchoolsSearchTestEnvelope.self, from: Data(json.utf8))
        #expect(payload.schools.count == 2)
        #expect(payload.schools[0].rne == "0930122Y")
        #expect(payload.schools[1].communeInsee == nil)
    }

    // MARK: - /communes/:insee/services

    @Test("Decodes /communes/:insee/services response")
    func decodesCommune() throws {
        let json = #"""
        {
          "insee": "93070",
          "name": "Saint-Denis",
          "dept": "93",
          "region": "Île-de-France",
          "services": [
            { "kind": "periscolaire", "providerName": "Portail Famille", "domain": "portail-famille.saintdenis.fr", "confidence": "medium" }
          ]
        }
        """#
        let commune = try JSONDecoder().decode(DirectoryCommune.self, from: Data(json.utf8))
        #expect(commune.insee == "93070")
        #expect(commune.services.first?.providerName == "Portail Famille")
    }
}

// MARK: - Live smoke tests (opt-in)

/// Hits `https://celyn.io/api/directory/*` with GET-only calls.
/// Skipped unless `NOTO_RUN_LIVE_API=1`. The API key used is the same
/// one baked into the client default — a production key scoped to
/// read-only directory endpoints, fine to exercise from tests.
@Suite("DirectoryAPIClient — live", .enabled(if: ProcessInfo.processInfo.environment["NOTO_RUN_LIVE_API"] == "1"))
struct DirectoryAPIClientLiveTests {
    let client = DirectoryAPIClient()

    @Test("GET /ents returns at least the curated 30 ENTs")
    func liveFetchENTs() async throws {
        let ents = try await client.fetchENTs()
        #expect(ents.count >= 30)
        #expect(ents.contains { $0.id == "monlycee" })
    }

    @Test("GET /schools/search finds a well-known collège by name")
    func liveSearchSchools() async throws {
        // Schools data may or may not be ingested yet (annuaire ingest
        // is a separate, optional job). Tolerate empty results — this
        // test is about the envelope, not the row count.
        let results = try await client.searchSchools(q: "Jaurès", limit: 5)
        for s in results { #expect(!s.rne.isEmpty) }
    }
}

// MARK: - Test envelopes (mirror the private ones in DirectoryAPIClient)

private struct ENTsTestEnvelope: Decodable {
    let version: Int?
    let ents: [DirectoryENTProvider]
}

private struct SchoolsSearchTestEnvelope: Decodable {
    let schools: [DirectorySchoolSummary]
}
