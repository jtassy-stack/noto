import Testing
import Foundation
@testable import Noto

/// `QuizAPIClient` end-to-end through `QuizStubProtocol`: path, query, headers,
/// status mapping, strict decoding. The POST report is mocked (CLAUDE.md:
/// tests never POST to a live API).
extension QuizBankSuites {
@Suite("QuizAPIClient")
struct QuizAPIClientTests {

    // MARK: Decoding

    @Test("decodes the contract sample")
    func decodesContractSample() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.contractSample) }
        defer { QuizStubProtocol.reset() }

        let page = try await stubbedQuizClient().bank(grade: "6e")
        #expect(page.app == "noto")
        #expect(page.grade == "6e")
        #expect(page.count == 2)
        #expect(page.nextUpdatedSince == nil)
        #expect(page.items.count == 2)
        #expect(page.removed.isEmpty)

        let first = page.items[0]
        #expect(first.id == QuizBankFixtures.id1)
        #expect(first.subject == "Français")
        #expect(first.theme == "Récits de création ; création poétique")
        #expect(first.notion == "Ulysse")
        #expect(first.kind == "programme")
        #expect(first.domain == "scolaire")
        #expect(first.tone == "histoire")
        #expect(first.choices.count == 4)
        #expect(first.answerIndex == 0)
        #expect(first.oeuvreId == QuizBankFixtures.oeuvre)
        #expect(first.oeuvreTitle == "L'Odyssée")
        #expect(first.imageUrl == nil)
        #expect(first.reviewMethod == "jev")
        #expect(first.reviewConfidence == 0.95)
        // Raw string, fractional seconds kept for the next `updatedSince`.
        #expect(first.updatedAt == "2026-10-15T10:00:00.000Z")
        #expect(page.items[1].notion == nil)
        #expect(page.items[1].oeuvreId == nil)
    }

    @Test("decodes a non-null nextUpdatedSince verbatim")
    func decodesCursor() async throws {
        QuizStubProtocol.install { _ in
            .json(QuizBankFixtures.page(items: [QuizBankFixtures.item()], next: "2026-10-15T10:00:00.000Z"))
        }
        defer { QuizStubProtocol.reset() }
        let page = try await stubbedQuizClient().bank(grade: "6e")
        #expect(page.nextUpdatedSince == "2026-10-15T10:00:00.000Z")
    }

    @Test("decodes the amended contract sample: removed list, short non-final page")
    func decodesAmendedSample() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.amendedSample) }
        defer { QuizStubProtocol.reset() }

        let page = try await stubbedQuizClient().bank(grade: "6e", updatedSince: "2026-10-15T12:00:00.000Z")
        #expect(page.app == "noto")
        #expect(page.grade == "6e")
        #expect(page.count == 1)
        #expect(page.items.map(\.id) == [QuizBankFixtures.id2])
        #expect(page.items[0].updatedAt == "2026-10-16T08:00:00.000Z")
        #expect(page.removed == [
            BankRemovedDto(id: QuizBankFixtures.id1, questionKey: "k-removed", updatedAt: "2026-10-16T09:00:00.000Z"),
        ])
        // count (1) < limit (50) yet a cursor: only the cursor ends the feed.
        #expect(page.nextUpdatedSince == "2026-10-16T09:00:00.000Z")
    }

    @Test("missing envelope removed fails decoding (required key)")
    func missingRemovedFails() async throws {
        QuizStubProtocol.install { _ in
            .json(#"{"app":"noto","grade":"6e","count":0,"items":[],"nextUpdatedSince":null}"#)
        }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    @Test("a removed entry missing a field fails decoding", arguments: ["id", "questionKey", "updatedAt"])
    func removedEntryMissingFieldFails(field: String) async throws {
        var entry: [String: String] = [
            "id": QuizBankFixtures.id1.uuidString.lowercased(),
            "questionKey": "k",
            "updatedAt": "2026-10-16T09:00:00.000Z",
        ]
        entry[field] = nil
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [], removed: [json])) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    @Test("unknown keys are ignored (additive server changes)")
    func ignoresUnknownKeys() async throws {
        let item = QuizBankFixtures.item().replacingOccurrences(of: "\"kind\":", with: "\"futureField\": 1, \"kind\":")
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [item])) }
        defer { QuizStubProtocol.reset() }
        let page = try await stubbedQuizClient().bank(grade: "6e")
        #expect(page.items.count == 1)
    }

    /// Strict: a missing key fails the page, nullable keys included (the
    /// synthesized decoder would silently accept a missing `notion`).
    @Test("missing field fails decoding", arguments: [
        "questionKey", "notion", "explanation", "oeuvreId", "imageUrl", "reviewMethod",
        "reviewConfidence", "updatedAt", "answerIndex",
    ])
    func missingFieldFails(field: String) async throws {
        let stripped = QuizBankFixtures.item()
            .split(separator: "\n")
            .filter { !$0.contains("\"\(field)\":") }
            .joined(separator: "\n")
        // Re-close the object if the last line (no trailing comma) was removed.
        let json = stripped.replacingOccurrences(of: ",\n}", with: "\n}")
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [json])) }
        defer { QuizStubProtocol.reset() }

        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    @Test("missing envelope nextUpdatedSince fails decoding")
    func missingCursorFails() async throws {
        QuizStubProtocol.install { _ in .json(#"{"app":"noto","grade":"6e","count":0,"items":[]}"#) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    // MARK: Request shape (privacy)

    @Test("GET /api/quiz/v2/bank sends only app, grade, subject, theme, limit, updatedSince")
    func queryParams() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        defer { QuizStubProtocol.reset() }

        _ = try await stubbedQuizClient().bank(grade: "4e", subject: "Mathématiques",
                                               theme: "Théorème de Pythagore", limit: 120,
                                               updatedSince: "2026-10-15T12:00:00.000Z")
        let request = try #require(QuizStubProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "celyn.io")
        #expect(request.url?.path == "/api/quiz/v2/bank")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "noto_test_key")
        #expect(request.value(forHTTPHeaderField: "x-device-id") == nil)
        #expect(request.queryMap == [
            "app": "noto", "grade": "4e", "subject": "Mathématiques",
            "theme": "Théorème de Pythagore", "limit": "120",
            "updatedSince": "2026-10-15T12:00:00.000Z",
        ])
    }

    @Test("minimal request: app + grade + default limit, nothing else")
    func minimalQuery() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        defer { QuizStubProtocol.reset() }
        _ = try await stubbedQuizClient().bank(grade: "Tle")
        let request = try #require(QuizStubProtocol.requests.last)
        #expect(request.queryMap == ["app": "noto", "grade": "Tle", "limit": "50"])
    }

    @Test("theme without subject is dropped (server would 400); limit is clamped")
    func themeRequiresSubject() async throws {
        QuizStubProtocol.install { _ in .json(QuizBankFixtures.page(items: [])) }
        defer { QuizStubProtocol.reset() }
        _ = try await stubbedQuizClient().bank(grade: "6e", theme: "Le monde antique", limit: 999)
        let request = try #require(QuizStubProtocol.requests.last)
        #expect(request.queryMap == ["app": "noto", "grade": "6e", "limit": "200"])
    }

    // MARK: Errors

    @Test("400 → badRequest with the server message")
    func badRequest() async {
        QuizStubProtocol.install { _ in .json(#"{"error":"bad grade"}"#, status: 400) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .badRequest(let body) = error else {
            Issue.record("expected .badRequest, got \(String(describing: error))")
            return
        }
        #expect(body?.contains("bad grade") == true)
    }

    @Test("401 → unauthorized")
    func unauthorized() async {
        QuizStubProtocol.install { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .unauthorized = error else {
            Issue.record("expected .unauthorized, got \(String(describing: error))")
            return
        }
    }

    @Test("429 → rateLimited with Retry-After")
    func rateLimited() async {
        QuizStubProtocol.install { _ in .init(status: 429, body: Data(), headers: ["Retry-After": "30"]) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .rateLimited(let retry) = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retry == 30)
    }

    @Test("5xx → httpError; offline → transport")
    func serverAndTransport() async {
        defer { QuizStubProtocol.reset() }

        QuizStubProtocol.install { _ in .json("oops", status: 503) }
        let server = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .httpError(503, _) = server else {
            Issue.record("expected .httpError(503), got \(String(describing: server))")
            return
        }

        QuizStubProtocol.install { _ in .offline() }
        let offline = await quizError { _ = try await stubbedQuizClient().bank(grade: "6e") }
        guard case .transport = offline else {
            Issue.record("expected .transport, got \(String(describing: offline))")
            return
        }
    }

    // MARK: Report (POST, mocked)

    @Test("report POSTs {reason} (trimmed, ≤ 500) with x-device-id and accepts 202")
    func reportMocked() async throws {
        QuizStubProtocol.install { _ in .json(#"{"ok":true}"#, status: 202) }
        defer { QuizStubProtocol.reset() }

        let long = String(repeating: "a", count: 600)
        try await stubbedQuizClient().report(quizId: QuizBankFixtures.id1, reason: "  \(long)  ",
                                             deviceID: "install-uuid")
        let request = try #require(QuizStubProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/quiz/v2/quiz/\(QuizBankFixtures.id1.uuidString.lowercased())/report")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "noto_test_key")
        #expect(request.value(forHTTPHeaderField: "x-device-id") == "install-uuid")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body.keys.sorted() == ["reason"])
        #expect(body["reason"] == String(repeating: "a", count: QuizAPIClient.maxReportReasonLength))
    }

    @Test("report reason is capped in UTF-16 units (celyn zod .max), never splitting a Character")
    func reportReasonUTF16Cap() async throws {
        QuizStubProtocol.install { _ in .json(#"{"ok":true}"#, status: 202) }
        defer { QuizStubProtocol.reset() }

        // 500 Characters, 1 000 UTF-16 units (each emoji is a surrogate pair).
        let emoji = String(repeating: "😀", count: QuizAPIClient.maxReportReasonLength)
        try await stubbedQuizClient().report(quizId: QuizBankFixtures.id1, reason: emoji)
        let request = try #require(QuizStubProtocol.requests.last)
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        let reason = try #require(body["reason"])
        #expect(reason.utf16.count <= QuizAPIClient.maxReportReasonLength)
        #expect(reason == String(repeating: "😀", count: QuizAPIClient.maxReportReasonLength / 2))

        // Odd budget: a 2-unit Character that would straddle the limit is dropped whole.
        let mixed = "a" + emoji
        #expect(QuizAPIClient.truncatedReason(mixed).utf16.count == QuizAPIClient.maxReportReasonLength - 1)
        #expect(QuizAPIClient.truncatedReason("court") == "court")
    }

    @Test("report without reason sends {} and no device header; 404 is typed")
    func reportNoReason() async throws {
        QuizStubProtocol.install { _ in .json(#"{"ok":true}"#, status: 202) }
        defer { QuizStubProtocol.reset() }
        try await stubbedQuizClient().report(quizId: QuizBankFixtures.id2)
        let request = try #require(QuizStubProtocol.requests.last)
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "x-device-id") == nil)

        QuizStubProtocol.install { _ in .json(#"{"error":"not found"}"#, status: 404) }
        let error = await quizError { try await stubbedQuizClient().report(quizId: QuizBankFixtures.id2) }
        guard case .notFound = error else {
            Issue.record("expected .notFound, got \(String(describing: error))")
            return
        }
    }
}
}
