import Testing
import Foundation
@testable import Noto

// MARK: - URLProtocol stub

/// Intercepts every request sent through a `URLSession` configured with
/// this protocol and answers from a per-test handler. Lets us drive
/// `DirectoryAPIClient` end-to-end — covering path construction, query
/// encoding, status-code mapping, and decoding — without ever hitting
/// the network.
final class DirectoryStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        Self.capturedRequests = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        Self.handler = nil
        Self.capturedRequests = []
    }

    static func lastRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return Self.capturedRequests.last
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Builds a `DirectoryAPIClient` whose session routes every request
/// through `DirectoryStubProtocol`.
private func stubbedClient() -> DirectoryAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DirectoryStubProtocol.self]
    let session = URLSession(configuration: config)
    return DirectoryAPIClient(session: session)
}

// MARK: - Decoder fixtures (drive through the client)

/// Coverage for `DirectoryAPIClient` decoders. Every test drives the
/// client end-to-end through `DirectoryStubProtocol` so that renaming
/// the private `ENTsResponse` / `SchoolsSearchResponse` envelopes on
/// the server (or in the client) would actually break these tests.
///
/// Serialized because the stub protocol uses a shared static handler.
@Suite("DirectoryAPIClient — decoders", .serialized)
struct DirectoryAPIClientDecoderTests {

    @Test("GET /ents — decodes envelope + reused DirectoryENTProvider shape")
    func decodesENTs() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"""
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
            """#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        let ents = try await stubbedClient().fetchENTs()
        #expect(ents.count == 1)
        #expect(ents[0].id == "monlycee")
        #expect(ents[0].domains.contains("ent.iledefrance.fr"))
        #expect(ents[0].imapPort == 993)
    }

    @Test("GET /schools/:rne — decodes nested commune + ent + services + mailDomains")
    func decodesSchool() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"""
            {
              "rne": "0930122Y",
              "name": "Collège Jean Jaurès",
              "kind": "college",
              "academy": "Créteil",
              "holidayZone": "C",
              "website": null,
              "commune": { "insee": "93070", "name": "Saint-Denis", "dept": "93", "region": "Île-de-France" },
              "ent": { "id": "monlycee", "name": "MonLycée.net", "domains": ["monlycee.net"] },
              "services": [{ "kind": "cantine", "providerName": "Arpège", "domain": "arpege.fr", "confidence": "high" }],
              "mailDomains": ["monlycee.net", "ac-creteil.fr", "arpege.fr"]
            }
            """#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        let school = try await stubbedClient().fetchSchool(rne: "0930122Y")
        #expect(school.rne == "0930122Y")
        #expect(school.commune?.dept == "93")
        #expect(school.ent?.id == "monlycee")
        #expect(school.services.first?.kind == "cantine")
        #expect(school.mailDomains.contains("ac-creteil.fr"))
    }

    @Test("GET /schools/:rne — null commune + ent round-trip cleanly")
    func decodesSchoolWithNullRefs() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"""
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
            """#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        let school = try await stubbedClient().fetchSchool(rne: "0000000X")
        #expect(school.commune == nil)
        #expect(school.ent == nil)
        #expect(school.services.isEmpty)
    }

    @Test("GET /schools/search — decodes envelope with optional fields")
    func decodesSchoolSearch() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"""
            {
              "schools": [
                { "rne": "0930122Y", "name": "Collège Jean Jaurès", "kind": "college", "communeInsee": "93070", "academy": "Créteil" },
                { "rne": "0751234X", "name": "Collège Condorcet", "kind": "college", "communeInsee": null, "academy": null }
              ]
            }
            """#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        let results = try await stubbedClient().searchSchools(q: "Condorcet")
        #expect(results.count == 2)
        #expect(results[0].rne == "0930122Y")
        #expect(results[1].communeInsee == nil)
    }

    @Test("GET /communes/:insee/services — decodes commune + services")
    func decodesCommune() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"""
            {
              "insee": "93070",
              "name": "Saint-Denis",
              "dept": "93",
              "region": "Île-de-France",
              "services": [
                { "kind": "periscolaire", "providerName": "Portail Famille", "domain": "portail-famille.saintdenis.fr", "confidence": "medium" }
              ]
            }
            """#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        let commune = try await stubbedClient().fetchCommune(insee: "93070")
        #expect(commune.insee == "93070")
        #expect(commune.services.first?.providerName == "Portail Famille")
    }
}

// MARK: - HTTP status + URL construction

/// Pins the client's error-mapping contract: every branch of the HTTP
/// switch, every transformation on outbound URLs. These are the tests
/// that prevent silent regressions like "404 now surfaces as `.httpError(404, nil)`
/// instead of `.notFound`" or "rne is no longer uppercased".
@Suite("DirectoryAPIClient — HTTP + URL", .serialized)
struct DirectoryAPIClientHTTPTests {

    @Test("404 → .notFound (no body attached)")
    func notFoundMapping() async {
        DirectoryStubProtocol.install { _ in
            .init(status: 404, body: Data(#"{"error":"School not found"}"#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        do {
            _ = try await stubbedClient().fetchSchool(rne: "MISSING")
            Issue.record("expected throw")
        } catch let DirectoryAPIError.notFound {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("500 → .httpError(500, body) with body snippet attached")
    func serverErrorIncludesBody() async {
        DirectoryStubProtocol.install { _ in
            .init(status: 500, body: Data(#"{"error":"db down"}"#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        do {
            _ = try await stubbedClient().fetchENTs()
            Issue.record("expected throw")
        } catch let DirectoryAPIError.httpError(code, body) {
            #expect(code == 500)
            #expect(body?.contains("db down") == true)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("200 with malformed JSON → .decoding")
    func malformedJSONMapsToDecoding() async {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data("not json at all".utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        do {
            _ = try await stubbedClient().fetchENTs()
            Issue.record("expected throw")
        } catch DirectoryAPIError.decoding {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("fetchSchool uppercases RNE in request path")
    func fetchSchoolUppercasesRNE() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 404, body: Data())  // early abort after path capture
        }
        defer { DirectoryStubProtocol.reset() }

        _ = try? await stubbedClient().fetchSchool(rne: "0930122y")
        let path = DirectoryStubProtocol.lastRequest()?.url?.path ?? ""
        #expect(path.hasSuffix("/schools/0930122Y"))
    }

    @Test("searchSchools omits q when empty or nil — no ?q= in URL")
    func searchSchoolsOmitsEmptyQ() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"{"schools":[]}"#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        _ = try await stubbedClient().searchSchools(q: "", insee: "93070")
        let url = DirectoryStubProtocol.lastRequest()?.url?.absoluteString ?? ""
        #expect(!url.contains("q="))
        #expect(url.contains("insee=93070"))
    }

    @Test("searchSchools encodes diacritics in q")
    func searchSchoolsEncodesDiacritics() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"{"schools":[]}"#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        _ = try await stubbedClient().searchSchools(q: "Jaurès")
        let url = DirectoryStubProtocol.lastRequest()?.url?.absoluteString ?? ""
        // URLComponents percent-encodes "è" as %C3%A8 (UTF-8).
        #expect(url.contains("q=Jaur%C3%A8s"))
    }

    @Test("every request carries the x-api-key header")
    func apiKeyHeaderAttached() async throws {
        DirectoryStubProtocol.install { _ in
            .init(status: 200, body: Data(#"{"version":1,"ents":[]}"#.utf8))
        }
        defer { DirectoryStubProtocol.reset() }

        _ = try await stubbedClient().fetchENTs()
        let header = DirectoryStubProtocol.lastRequest()?.value(forHTTPHeaderField: "x-api-key")
        #expect(header != nil && !header!.isEmpty)
    }
}

// MARK: - Live smoke (opt-in)

/// Single end-to-end assertion against production celyn. Runs only when
/// `NOTO_RUN_LIVE_API=1`. Pins a concrete fact (MonLycée is in the
/// curated registry) rather than a count — count-based assertions drift
/// with future curation changes.
@Suite("DirectoryAPIClient — live", .enabled(if: ProcessInfo.processInfo.environment["NOTO_RUN_LIVE_API"] == "1"))
struct DirectoryAPIClientLiveTests {
    let client = DirectoryAPIClient()

    @Test("GET /ents includes the curated MonLycée entry")
    func liveFetchENTs() async throws {
        let ents = try await client.fetchENTs()
        #expect(ents.contains { $0.id == "monlycee" })
    }
}
