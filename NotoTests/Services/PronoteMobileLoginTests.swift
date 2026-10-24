import Testing
import Foundation
@testable import Noto

/// The ENT entry builds Pronote's `bydlg` mobile URL from whatever the
/// parent typed or the ENT linked, and reads the token document the page
/// renders. Both are pure; the web view only glues them together.
@Suite("PronoteMobileLogin")
struct PronoteMobileLoginTests {

    @Test("instance URL: scheme added, page / query / trailing slash dropped")
    func instanceNormalization() {
        let expected = URL(string: "https://0750000a.index-education.net/pronote")
        #expect(PronoteMobileLogin.instanceURL(from: "0750000a.index-education.net/pronote/") == expected)
        #expect(PronoteMobileLogin.instanceURL(from: "https://0750000a.index-education.net/pronote/mobile.parent.html?fd=1") == expected)
        #expect(PronoteMobileLogin.instanceURL(from: "http://0750000a.index-education.net/pronote/parent.html#x") == expected)
        #expect(PronoteMobileLogin.instanceURL(from: "  ") == nil)
        #expect(PronoteMobileLogin.instanceURL(from: "https://") == nil)
    }

    @Test("login page carries fd, bydlg and login=true for the right space")
    func loginPage() throws {
        let instance = try #require(URL(string: "https://p.example.net/pronote"))
        let url = try #require(PronoteMobileLogin.loginPageURL(instance: instance, kind: .parent))
        #expect(url.path == "/pronote/mobile.parent.html")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "fd", value: "1")))
        #expect(items.contains(URLQueryItem(name: "bydlg", value: PronoteMobileLogin.applicationIdentifier)))
        #expect(items.contains(URLQueryItem(name: "login", value: "true")))
        let student = try #require(PronoteMobileLogin.loginPageURL(instance: instance, kind: .student))
        #expect(student.path == "/pronote/mobile.eleve.html")
    }

    @Test("mobile page detection ignores the CAS host and the desktop page")
    func mobilePage() throws {
        let instance = try #require(URL(string: "https://p.example.net/pronote"))
        #expect(PronoteMobileLogin.isMobilePage(URL(string: "https://p.example.net/pronote/mobile.parent.html?fd=1")!, of: instance))
        #expect(PronoteMobileLogin.isMobilePage(URL(string: "https://P.EXAMPLE.NET/pronote/mobile.eleve.html")!, of: instance))
        #expect(!PronoteMobileLogin.isMobilePage(URL(string: "https://auth.monlycee.net/realms/x")!, of: instance))
        #expect(!PronoteMobileLogin.isMobilePage(URL(string: "https://p.example.net/pronote/parent.html")!, of: instance))
    }

    @Test("token payload: plain, wrapped in text, and invalid")
    func tokenPayload() throws {
        let plain = #"{"login":"PARENT1","mdp":"abc123","navigateur":"x"}"#
        #expect(PronoteMobileLogin.parseTokenPayload(bodyText: plain) == .init(login: "PARENT1", token: "abc123"))
        let wrapped = "\n  Résultat : {\"login\":\"PARENT1\",\"mdp\":\"abc123\"} \n"
        #expect(PronoteMobileLogin.parseTokenPayload(bodyText: wrapped)?.token == "abc123")
        #expect(PronoteMobileLogin.parseTokenPayload(bodyText: "<html>Identification</html>") == nil)
        #expect(PronoteMobileLogin.parseTokenPayload(bodyText: #"{"login":"","mdp":"abc"}"#) == nil)
        #expect(PronoteMobileLogin.parseTokenPayload(bodyText: #"{"login":"u"}"#) == nil)
    }

    @Test("payload becomes a stored token on the instance URL, parent kind")
    func refreshToken() throws {
        let instance = try #require(URL(string: "https://p.example.net/pronote"))
        let token = PronoteMobileLogin.TokenPayload(login: "PARENT1", token: "abc").refreshToken(instance: instance, kind: .parent)
        #expect(token == PronoteRefreshToken(url: "https://p.example.net/pronote", token: "abc", username: "PARENT1", kind: .parent))
    }

    @Test("hook script escapes the device id and defines the Pronote hook")
    func hook() {
        let script = PronoteMobileLogin.hookScript(deviceUUID: "a'b")
        #expect(script.contains("window.hookAccesDepuisAppli"))
        #expect(script.contains("passerEnModeValidationAppliMobile('', 'a\\'b')"))
    }
}
