import Testing
import Foundation
@testable import Noto

/// The stored Pronote token must round-trip the account kind and the
/// navigator identifier pawnote hands back, and still decode the payloads
/// earlier builds wrote (no `navigatorIdentifier` key).
@Suite("PronoteRefreshToken")
struct PronoteRefreshTokenTests {

    @Test("legacy payload without navigatorIdentifier decodes, kind kept")
    func legacyDecodes() throws {
        let json = #"{"url":"https://x.index-education.net/pronote","token":"t","username":"u","kind":6}"#
        let token = try JSONDecoder().decode(PronoteRefreshToken.self, from: Data(json.utf8))
        #expect(token.kind == .student)
        #expect(token.navigatorIdentifier == nil)
        #expect(token.username == "u")
    }

    @Test("round-trips navigatorIdentifier")
    func roundTrip() throws {
        let token = PronoteRefreshToken(url: "https://p", token: "t", username: "u", kind: .parent, navigatorIdentifier: "nav-1")
        let data = try JSONEncoder().encode(token)
        let back = try JSONDecoder().decode(PronoteRefreshToken.self, from: data)
        #expect(back == token)
    }

    @Test("pawnote login result keeps the student kind and the navigator id")
    @MainActor
    func parsesLoginResult() {
        let dict: [String: Any] = [
            "url": "https://p", "token": "t", "username": "u",
            "kind": 6, "navigatorIdentifier": "nav-2",
        ]
        let token = PawnoteBridge.refreshToken(from: dict)
        #expect(token.kind == .student)
        #expect(token.navigatorIdentifier == "nav-2")
    }

    @Test("unknown kind and empty navigator fall back to parent / nil")
    @MainActor
    func parsesFallbacks() {
        let dict: [String: Any] = ["url": "https://p", "token": "t", "username": "u", "kind": 0, "navigatorIdentifier": ""]
        let token = PawnoteBridge.refreshToken(from: dict)
        #expect(token.kind == .parent)
        #expect(token.navigatorIdentifier == nil)
    }

    @Test("JS double-auth marker maps to the typed error")
    @MainActor
    func mapsDoubleAuth() {
        let error = PawnoteBridge.error(fromJSMessage: "DOUBLE_AUTH_REQUIRED: You're asked to custom your security methods")
        guard case .doubleAuthRequired = error else {
            Issue.record("expected doubleAuthRequired, got \(error)")
            return
        }
        let message = PronoteAutoConnect.userMessage(for: error)
        #expect(message.contains("double authentification"))
    }

    @Test("other JS errors stay invalidResponse with a generic reconnect message")
    @MainActor
    func mapsOther() {
        let error = PawnoteBridge.error(fromJSMessage: "Unexpected token")
        guard case .invalidResponse = error else {
            Issue.record("expected invalidResponse, got \(error)")
            return
        }
        #expect(PronoteAutoConnect.userMessage(for: error).contains("QR"))
    }
}
