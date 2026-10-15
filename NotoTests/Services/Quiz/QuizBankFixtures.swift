import Testing
import Foundation
@testable import Noto

/// Parent of every suite that drives `QuizStubProtocol`. Its handler is
/// static and Swift Testing runs sibling suites in parallel; `.serialized`
/// on the parent serializes every nested suite and test.
@Suite("Quiz bank (celyn v2)", .serialized)
enum QuizBankSuites {}

/// The `QuizAPIError` thrown by `body`, or nil (no error / another type).
/// Runs on the caller's actor (`#isolation`) so a closure capturing
/// main-actor state can be passed without crossing isolation (Swift 6.4).
func quizError(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Void
) async -> QuizAPIError? {
    do {
        try await body()
        return nil
    } catch let error as QuizAPIError {
        return error
    } catch {
        return nil
    }
}

// MARK: - URLProtocol stub

/// Request-capturing stub for the quiz v2 bank suites. Its own class (not
/// `DirectoryStubProtocol`, whose suites run in parallel with these); every
/// user is nested in `QuizBankSuites`. Nothing here reaches the network.
final class QuizStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// When set, the request fails at the transport level (offline).
        var transportError: URLError? = nil

        static func json(_ string: String, status: Int = 200) -> Stub {
            Stub(status: status, body: Data(string.utf8))
        }

        static func offline() -> Stub {
            Stub(status: 0, body: Data(), transportError: URLError(.notConnectedToInternet))
        }
    }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        Self.captured = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        Self.handler = nil
        Self.captured = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream before the protocol sees it.
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
        }
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        if let error = stub.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

extension URLRequest {
    /// Query items of the request URL as a name → value map.
    var queryMap: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

/// Client whose session routes through `QuizStubProtocol`, with an explicit
/// test key (never `Config.xcconfig` / Info.plist).
func stubbedQuizClient() -> QuizAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QuizStubProtocol.self]
    return QuizAPIClient(apiKey: "noto_test_key", session: URLSession(configuration: config))
}

// MARK: - Contract fixtures

enum QuizBankFixtures {
    static let id1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let id2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let oeuvre = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    /// One `BankQuizDto` as JSON, every contract key present.
    static func item(
        id: UUID = id1,
        grade: String = "6e",
        question: String = "Quel héros de l'Odyssée est le roi d'Ithaque ?",
        choices: [String] = ["Ulysse", "Achille", "Hector", "Énée"],
        answerIndex: Int = 0,
        difficulty: Int = 1,
        notion: String? = "Ulysse",
        reviewMethod: String? = "jev",
        reviewConfidence: Double = 0.95,
        updatedAt: String = "2026-10-15T10:00:00.000Z",
        oeuvreId: UUID? = oeuvre
    ) -> String {
        let choicesJSON = choices.map { "\"\($0)\"" }.joined(separator: ", ")
        func str(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        return """
        {
          "id": "\(id.uuidString.lowercased())",
          "questionKey": "\(QuizKey.make(question: question, choices: choices))",
          "grade": "\(grade)",
          "subject": "Français",
          "theme": "Récits de création ; création poétique",
          "notion": \(str(notion)),
          "kind": "programme",
          "domain": "scolaire",
          "difficulty": \(difficulty),
          "tone": "histoire",
          "question": "\(question)",
          "choices": [\(choicesJSON)],
          "answerIndex": \(answerIndex),
          "explanation": "Ulysse est le roi d'Ithaque dans l'Odyssée d'Homère.",
          "oeuvreId": \(str(oeuvreId?.uuidString.lowercased())),
          "oeuvreTitle": "L'Odyssée",
          "imageUrl": null,
          "reviewMethod": \(str(reviewMethod)),
          "reviewConfidence": \(reviewConfidence),
          "updatedAt": "\(updatedAt)"
        }
        """
    }

    /// One `removed` entry as JSON (`{id, questionKey, updatedAt}`).
    static func removedEntry(
        id: UUID = id1,
        questionKey: String = "removed-key",
        updatedAt: String = "2026-10-16T09:00:00.000Z"
    ) -> String {
        #"{"id": "\#(id.uuidString.lowercased())", "questionKey": "\#(questionKey)", "updatedAt": "\#(updatedAt)"}"#
    }

    static func page(grade: String = "6e", items: [String], removed: [String] = [], next: String? = nil) -> String {
        """
        {
          "app": "noto",
          "grade": "\(grade)",
          "count": \(items.count),
          "items": [\(items.joined(separator: ",\n"))],
          "removed": [\(removed.joined(separator: ",\n"))],
          "nextUpdatedSince": \(next.map { "\"\($0)\"" } ?? "null")
        }
        """
    }

    /// The contract sample: two items, last page.
    static let contractSample = page(items: [
        item(),
        item(id: id2, question: "Qui a écrit l'Odyssée ?", choices: ["Homère", "Virgile", "Ovide", "Sophocle"],
             difficulty: 2, notion: nil, reviewMethod: "llm", reviewConfidence: 0.7,
             updatedAt: "2026-10-15T12:00:00.000Z", oeuvreId: nil),
    ])

    /// Amended contract sample (incremental page): one item, one removal,
    /// short (count 1 < limit) yet non-final.
    static let amendedSample = page(
        items: [item(id: id2, question: "Qui a écrit l'Odyssée ?", choices: ["Homère", "Virgile", "Ovide", "Sophocle"],
                     updatedAt: "2026-10-16T08:00:00.000Z")],
        removed: [removedEntry(id: id1, questionKey: "k-removed", updatedAt: "2026-10-16T09:00:00.000Z")],
        next: "2026-10-16T09:00:00.000Z"
    )
}
