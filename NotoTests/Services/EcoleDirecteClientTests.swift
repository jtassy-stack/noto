import Testing
import Foundation
@testable import Noto

/// École Directe client (3.8): per-day cahier de textes parsing, URL
/// building, and the read-only `verbe=get` POST through a `URLProtocol`
/// mock. No request leaves the machine; all data is made up.
@Suite("EcoleDirecteClient", .serialized)
struct EcoleDirecteClientTests {
    private let day = edParseDate("2023-11-10")!

    @Test("parseDay: base64 seance + homework, libelle fallback, empty subjects dropped")
    func parseDayFixture() throws {
        let data = try FixtureLoader.data("ed-cahierdetextes-day.json")
        let seances = EcoleDirecteClient.parseDay(data, date: day)
        #expect(seances.count == 2)

        let hg = try #require(seances.first)
        #expect(hg.id == "1001")
        #expect(hg.subject == "HISTOIRE-GEOGRAPHIE")
        #expect(hg.date == day)
        #expect(hg.seanceText == "La Révolution française : 1789, prise de la Bastille.")
        #expect(hg.homeworkText == "Apprendre la leçon sur la Révolution.")

        let maths = seances[1]
        #expect(maths.subject == "MATHEMATIQUES")                       // `matiere` empty → `libelle`
        #expect(maths.seanceText == "Théorème de Pythagore : hypoténuse") // aFaire.contenuDeSeance
        #expect(maths.homeworkText == nil)
    }

    @Test("parseDay tolerates garbage")
    func parseDayGarbage() {
        #expect(EcoleDirecteClient.parseDay(Data("not json".utf8), date: day).isEmpty)
        #expect(EcoleDirecteClient.parseDay(Data(#"{"code":200,"data":[]}"#.utf8), date: day).isEmpty)
    }

    @Test("URL: verbe=get is a real query item, never %3F in the path")
    func urlBuilder() throws {
        let url = EcoleDirecteClient.makeURL(path: "/Eleves/42/cahierdetextes/2023-11-10.awp",
                                             query: EcoleDirecteClient.readQuery)
        #expect(url.absoluteString == "https://api.ecoledirecte.com/v3/Eleves/42/cahierdetextes/2023-11-10.awp?verbe=get")
        #expect(!url.absoluteString.contains("%3F"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "verbe", value: "get")])
        #expect(components.path == "/v3/Eleves/42/cahierdetextes/2023-11-10.awp")

        let login = EcoleDirecteClient.makeURL(path: "/login.awp", query: [])
        #expect(login.absoluteString == "https://api.ecoledirecte.com/v3/login.awp")
    }

    @Test("ymd is Gregorian, Europe/Paris")
    func ymd() {
        // 2023-11-09 23:30 UTC is already the 10th in Paris.
        let lateUTC = Date(timeIntervalSince1970: 1_699_572_600)
        #expect(EcoleDirecteClient.ymd(lateUTC) == "2023-11-10")
    }

    @Test("fetchDay: POST, body data={}, verbe=get, X-Token, mocked session")
    func fetchDayMocked() async throws {
        let fixture = try FixtureLoader.data("ed-cahierdetextes-day.json")
        EDMockURLProtocol.reset(response: fixture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EDMockURLProtocol.self]
        let client = EcoleDirecteClient(accountId: "test-\(UUID().uuidString)", configuration: config)
        await client.setToken("fake-token")

        let seances = try await client.fetchDay(eleveId: 42, date: day)
        #expect(seances.count == 2)

        let request = try #require(EDMockURLProtocol.lastRequest)
        #expect(request.method == "POST")
        #expect(request.body == "data={}")
        #expect(request.token == "fake-token")
        let url = try #require(request.url)
        #expect(url.host == "api.ecoledirecte.com")
        #expect(url.path == "/v3/Eleves/42/cahierdetextes/2023-11-10.awp")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            == [URLQueryItem(name: "verbe", value: "get")])
        #expect(EDMockURLProtocol.requestCount == 1)
    }
}

/// Captures the request and answers with a canned body. Never touches the network.
final class EDMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let url: URL?
        let method: String?
        let body: String?
        let token: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Data()
    nonisolated(unsafe) private static var captured: [Captured] = []

    static func reset(response data: Data) {
        lock.withLock {
            response = data
            captured = []
        }
    }

    static var lastRequest: Captured? { lock.withLock { captured.last } }
    static var requestCount: Int { lock.withLock { captured.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: String? = {
            if let data = request.httpBody { return String(data: data, encoding: .utf8) }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return String(data: data, encoding: .utf8)
        }()
        let entry = Captured(url: request.url, method: request.httpMethod, body: body,
                             token: request.value(forHTTPHeaderField: "X-Token"))
        let data = Self.lock.withLock {
            Self.captured.append(entry)
            return Self.response
        }
        let http = HTTPURLResponse(url: request.url ?? EcoleDirecteClient.baseURL, statusCode: 200,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
