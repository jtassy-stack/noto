import Testing
import Foundation
import SwiftData
@testable import Noto

// MARK: - URLProtocol stub

/// Own stub class (not `DirectoryStubProtocol`): the handler is a process-wide
/// static, so sharing it with another suite running in parallel would cross
/// wires. The suites using it are `.serialized`.
final class MonLyceeStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int = 200
        var body: Data = Data()
        /// Lets a test simulate a redirect to another host.
        var responseURL: URL?
        /// When set, the request fails at the transport level instead.
        var transportError: URLError.Code?
    }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest, Data) -> Stub)?
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping @Sendable (URLRequest, Data) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        Self.captured = []
    }

    static func requests() -> [(request: URLRequest, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return captured.map { ($0.0, String(decoding: $0.1, as: UTF8.self)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands URLProtocol the body as a stream, not `httpBody`.
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        Self.lock.lock()
        Self.captured.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let stub = handler(request, body)
        if let code = stub.transportError {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: stub.responseURL ?? request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Helpers

/// Ephemeral session: its own in-memory cookie jar, never the device's
/// `HTTPCookieStorage.shared`, and every request answered by the stub.
private func stubbedClient(csrfToken: String? = "tok+123") -> MonLyceeWebmailClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MonLyceeStubProtocol.self]
    let session = URLSession(configuration: config)
    if let csrfToken {
        setCSRFCookie(csrfToken, in: session)
    }
    return MonLyceeWebmailClient(session: session)
}

private func setCSRFCookie(_ value: String, in session: URLSession, domain: String = ".monlycee.net") {
    let cookie = HTTPCookie(properties: [
        .name: MonLyceeWebmailClient.csrfCookieName, .value: value,
        .domain: domain, .path: "/",
    ])!
    session.configuration.httpCookieStorage?.setCookie(cookie)
}

private func formFields(_ body: String) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        fields[parts[0]] = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    return fields
}

/// Routes `getMailHeaderList.json` / `getMail.json` to fixtures.
private func webmailHandler(
    bodyStatus: Int = 200,
    body: Data = MonLyceeMailFixtures.mail,
    bodyTransportError: URLError.Code? = nil
) -> @Sendable (URLRequest, Data) -> MonLyceeStubProtocol.Stub {
    { request, _ in
        switch request.url?.lastPathComponent {
        case "getMailHeaderList.json":
            return .init(body: MonLyceeMailFixtures.headerList)
        case "getMail.json":
            return .init(status: bodyStatus, body: body, transportError: bodyTransportError)
        default:
            return .init(status: 404)
        }
    }
}

// MARK: - Client

/// Single serialized parent: both child suites share `MonLyceeStubProtocol`'s
/// static handler, so they must not run in parallel with each other either.
@Suite("MonLycée webmail (stubbed URLSession)", .serialized)
struct MonLyceeWebmailStubbedTests {}

extension MonLyceeWebmailStubbedTests {
@Suite("MonLyceeWebmailClient")
struct ClientTests {

    @Test func headerListRequestCarriesTokenAndWebmailHeaders() async throws {
        MonLyceeStubProtocol.install(webmailHandler())
        let client = stubbedClient()

        let headers = try await client.fetchHeaders(csrfToken: "tok+123", pageSize: 20)

        #expect(headers.count == 3)
        let (request, body) = try #require(MonLyceeStubProtocol.requests().last)
        #expect(request.url?.host == "apis-mail.monlycee.net")
        #expect(request.url?.path == "/webmail/xml/getMailHeaderList.json")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://web-mail.monlycee.net/main.html")
        let fields = formFields(body)
        #expect(fields["tok"] == "tok+123")
        #expect(fields["FOLDER"] == "SF_INBOX")
        #expect(fields["NBDISPLAYMSG"] == "20")
        #expect(fields["END"] == "19")
    }

    @Test func bodyRequestTargetsMessageId() async throws {
        MonLyceeStubProtocol.install(webmailHandler())
        let body = try await stubbedClient().fetchBody(msgId: 1042, csrfToken: "t")
        #expect(body.hasPrefix("Bonjour,"))
        let fields = formFields(try #require(MonLyceeStubProtocol.requests().last).body)
        #expect(fields["IDMSG"] == "1042")
    }

    @Test func storedCSRFCookieIsUsedWithoutBootstrap() async throws {
        MonLyceeStubProtocol.install { _, _ in .init(status: 500) }
        let token = try await stubbedClient(csrfToken: "abc").resolveCSRFToken()
        #expect(token == "abc")
        #expect(MonLyceeStubProtocol.requests().isEmpty)
    }

    @Test func csrfCookieFromAnotherDomainIsIgnored() async {
        MonLyceeStubProtocol.install { _, _ in .init() }
        let client = stubbedClient(csrfToken: nil)
        setCSRFCookie("leaked", in: client.session, domain: "monlycee.net.evil.com")
        await #expect(throws: MonLyceeMailError.noSession) {
            try await client.resolveCSRFToken()
        }
    }

    @Test func missingCookieTriggersOneWebmailGETThatMintsIt() async throws {
        let client = stubbedClient(csrfToken: nil)
        let session = client.session
        MonLyceeStubProtocol.install { request, _ in
            // What the real webmail page does: set the CSRF cookie.
            setCSRFCookie("minted", in: session)
            return .init(body: Data("<html></html>".utf8))
        }

        let token = try await client.resolveCSRFToken()

        #expect(token == "minted")
        let requests = MonLyceeStubProtocol.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.request.httpMethod == "GET")
        #expect(requests.first?.request.url == MonLyceeWebmailClient.webmailURL)
    }

    @Test func noCookieEvenAfterBootstrapIsNoSession() async {
        MonLyceeStubProtocol.install { _, _ in .init() }
        await #expect(throws: MonLyceeMailError.noSession) {
            try await stubbedClient(csrfToken: nil).resolveCSRFToken()
        }
    }

    @Test func forbiddenIsUnauthorized() async {
        MonLyceeStubProtocol.install { _, _ in .init(status: 403) }
        await #expect(throws: MonLyceeMailError.unauthorized(status: 403)) {
            try await stubbedClient().fetchHeaders(csrfToken: "t", pageSize: 5)
        }
    }

    @Test func serverErrorIsHTTPError() async {
        MonLyceeStubProtocol.install { _, _ in .init(status: 502) }
        await #expect(throws: MonLyceeMailError.http(status: 502)) {
            try await stubbedClient().fetchHeaders(csrfToken: "t", pageSize: 5)
        }
    }

    @Test func redirectOffMonLyceeIsUnauthorized() async {
        MonLyceeStubProtocol.install { _, _ in
            .init(body: MonLyceeMailFixtures.loginPage, responseURL: URL(string: "https://cas.example.org/login")!)
        }
        await #expect(throws: MonLyceeMailError.unauthorized(status: 200)) {
            try await stubbedClient().fetchHeaders(csrfToken: "t", pageSize: 5)
        }
    }

    @Test func htmlInPlaceOfJSONIsInvalidPayload() async {
        MonLyceeStubProtocol.install { _, _ in .init(body: MonLyceeMailFixtures.loginPage) }
        await #expect(throws: MonLyceeMailError.invalidPayload) {
            try await stubbedClient().fetchHeaders(csrfToken: "t", pageSize: 5)
        }
    }
}

}

// MARK: - Sync end-to-end (stubbed network, in-memory SwiftData)

extension MonLyceeWebmailStubbedTests {
@Suite("MonLyceeMailService.sync")
@MainActor
struct SyncTests {

    private func makeContext() throws -> (ModelContext, Child) {
        let schema = Schema([Family.self, Child.self, Message.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = ModelContext(container)
        let child = Child(firstName: "Gaston", level: .lycee, grade: "2nde", schoolType: .ent, establishment: "Lycée Test")
        ctx.insert(child)
        return (ctx, child)
    }

    @Test func importsInboxOnceAndIsIdempotent() async throws {
        MonLyceeStubProtocol.install(webmailHandler())
        let (ctx, child) = try makeContext()
        let client = stubbedClient()

        let first = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: client)
        #expect(first == .success(3))
        #expect(child.messages.count == 3)
        #expect(child.messages.allSatisfy { $0.source == .monlycee && $0.body.hasPrefix("Bonjour,") })

        let second = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: client)
        #expect(second == .success(0))
        #expect(child.messages.count == 3)
    }

    @Test func skipsMailAlreadyImportedOverMonLyceeIMAP() async throws {
        MonLyceeStubProtocol.install(webmailHandler())
        let (ctx, child) = try makeContext()
        let imapCopy = Message(sender: "Mme Dupont", subject: "Conseil de classe", body: "",
                               date: Date(timeIntervalSince1970: 1_760_000_000),
                               source: .imap, imapUID: "88", imapProvider: "monlycee")
        imapCopy.child = child
        ctx.insert(imapCopy)

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .success(2))
        #expect(child.messages.filter { $0.subject == "Conseil de classe" }.count == 1)
        // Body fetched only for the two new mails.
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 2)
    }

    @Test func lostSessionStopsWithoutInserting() async throws {
        MonLyceeStubProtocol.install { _, _ in .init(status: 401) }
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .failure(.unauthorized(status: 401)))
        #expect(child.messages.isEmpty)
    }

    @Test func htmlLoginPageDuringBodiesStopsTheLoop() async throws {
        // Expired session redirected to a login page still on *.monlycee.net:
        // 200 + HTML → invalidPayload, same for every remaining body.
        MonLyceeStubProtocol.install(webmailHandler(body: Data("<html>Connexion</html>".utf8)))
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .success(0))
        #expect(child.messages.isEmpty)
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 1)
    }

    @Test func networkFailureDuringBodiesStopsTheLoop() async throws {
        MonLyceeStubProtocol.install(webmailHandler(bodyTransportError: .timedOut))
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .success(0))
        #expect(child.messages.isEmpty)
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 1)
    }

    @Test func httpErrorOnABodySkipsOnlyThatMessage() async throws {
        // A plain 500 is specific to one message: the loop goes on.
        MonLyceeStubProtocol.install(webmailHandler(bodyStatus: 500))
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .success(0))
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 3)
    }

    @Test func concurrentSyncsForTheSameChildInsertOnce() async throws {
        // Login's background sync and FullSyncService can overlap on a fresh
        // child: the second call must not re-fetch nor re-insert.
        MonLyceeStubProtocol.install(webmailHandler())
        let (ctx, child) = try makeContext()
        let client = stubbedClient()

        // Two MainActor tasks: the second starts while the first is
        // suspended on the network.
        let first = Task { @MainActor in
            await MonLyceeMailService.sync(child: child, modelContext: ctx, client: client)
        }
        let second = Task { @MainActor in
            await MonLyceeMailService.sync(child: child, modelContext: ctx, client: client)
        }
        let results = [await first.value, await second.value]

        #expect(results.contains(.success(0)))
        #expect(child.messages.count == 3)
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 3)
    }

    @Test func bodyLoopStopRule() {
        #expect(!MonLyceeMailService.shouldStopBodyLoop(after: .http(status: 500)))
        #expect(MonLyceeMailService.shouldStopBodyLoop(after: .unauthorized(status: 401)))
        #expect(MonLyceeMailService.shouldStopBodyLoop(after: .noSession))
        #expect(MonLyceeMailService.shouldStopBodyLoop(after: .invalidPayload))
        #expect(MonLyceeMailService.shouldStopBodyLoop(after: .network(.timedOut)))
    }

    @Test func requestsUseAShortTimeout() {
        let request = MonLyceeWebmailClient.formRequest(path: "getMail.json", params: [])
        #expect(request.timeoutInterval == MonLyceeWebmailClient.requestTimeout)
        #expect(MonLyceeWebmailClient.requestTimeout < 60)
    }

    @Test func expiredSessionDuringBodiesStopsTheLoop() async throws {
        MonLyceeStubProtocol.install(webmailHandler(bodyStatus: 403))
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient())

        #expect(result == .success(0))
        #expect(child.messages.isEmpty)
        let bodyCalls = MonLyceeStubProtocol.requests().filter { $0.request.url?.lastPathComponent == "getMail.json" }
        #expect(bodyCalls.count == 1)
    }

    @Test func noSessionNeverReachesTheMailAPI() async throws {
        MonLyceeStubProtocol.install { _, _ in .init() }
        let (ctx, child) = try makeContext()

        let result = await MonLyceeMailService.sync(child: child, modelContext: ctx, client: stubbedClient(csrfToken: nil))

        #expect(result == .failure(.noSession))
        #expect(MonLyceeStubProtocol.requests().allSatisfy { $0.request.url?.host == "web-mail.monlycee.net" })
    }
}
}
