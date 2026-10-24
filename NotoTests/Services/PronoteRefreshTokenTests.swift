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

    @Test("double-auth payload yields the renewed token and a PIN instruction")
    @MainActor
    func decodesDoubleAuthPayload() throws {
        let json = #"{"token":"t2","username":"u","url":"https://p","kind":6,"navigatorIdentifier":"nav","needsPIN":true,"needsChoice":false,"needsPassword":false}"#
        let error = PawnoteBridge.error(fromJSMessage: "DOUBLE_AUTH_REQUIRED:" + json)
        guard case .doubleAuthRequired(let info) = error, let info else {
            Issue.record("expected doubleAuthRequired with payload, got \(error)")
            return
        }
        let rescued = try #require(info.rescuedToken)
        #expect(rescued == PronoteRefreshToken(url: "https://p", token: "t2", username: "u", kind: .student, navigatorIdentifier: "nav"))
        #expect(info.instruction.contains("PIN"))
        #expect(PronoteAutoConnect.userMessage(for: error).contains("Réessayer"))
    }

    @Test("double-auth payload without a token rescues nothing and asks for a rescan")
    @MainActor
    func doubleAuthWithoutToken() {
        let json = #"{"token":null,"username":"u","url":"https://p","kind":7,"needsChoice":true}"#
        let error = PawnoteBridge.error(fromJSMessage: "DOUBLE_AUTH_REQUIRED:" + json)
        guard case .doubleAuthRequired(let info) = error else {
            Issue.record("expected doubleAuthRequired, got \(error)")
            return
        }
        #expect(info?.rescuedToken == nil)
        #expect(info?.instruction.contains("méthode") == true)
        #expect(PronoteAutoConnect.userMessage(for: error).contains("QR"))
    }

    @Test("pawnote's raw SecurityError wording maps to double auth too")
    @MainActor
    func mapsRawSecurityError() {
        let error = PawnoteBridge.error(fromJSMessage: "You're asked to custom your security methods")
        guard case .doubleAuthRequired(let info) = error else {
            Issue.record("expected doubleAuthRequired, got \(error)")
            return
        }
        #expect(info == nil)
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
