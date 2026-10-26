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

    @Test("instance URL: Pronote carried in an ENT connector or CAS query")
    func instanceFromENTLink() {
        let expected = URL(string: "https://0750000a.index-education.net/pronote")
        #expect(PronoteMobileLogin.instanceURL(from: "https://ent.example.fr/cas/login?service=https%3A%2F%2F0750000a.index-education.net%2Fpronote%2F") == expected)
        #expect(PronoteMobileLogin.instanceURL(from: "https://ent.example.fr/connecteur?url=https://0750000a.index-education.net/pronote/parent.html") == expected)
        // A query without a Pronote URL keeps the link's own host.
        #expect(PronoteMobileLogin.instanceURL(from: "https://ent.example.fr/pronote?service=x")?.host == "ent.example.fr")
    }

    @Test("login page: fd + bydlg, login=true only for a direct login")
    func loginPage() throws {
        let instance = try #require(URL(string: "https://p.example.net/pronote"))
        let url = try #require(PronoteMobileLogin.loginPageURL(instance: instance, kind: .parent))
        #expect(url.path == "/pronote/mobile.parent.html")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "fd", value: "1")))
        #expect(items.contains(URLQueryItem(name: "bydlg", value: PronoteMobileLogin.applicationIdentifier)))
        #expect(!items.contains { $0.name == "login" })
        let direct = try #require(PronoteMobileLogin.loginPageURL(instance: instance, kind: .parent, directLogin: true))
        let directItems = URLComponents(url: direct, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(directItems.contains(URLQueryItem(name: "login", value: "true")))
        // The ENT entry carries no bydlg: that switch turns Pronote's CAS
        // delegation off (real MonLycée instance, 2026-10-25).
        let entry = try #require(PronoteMobileLogin.casEntryURL(instance: instance, kind: .parent))
        #expect(entry.path == "/pronote/mobile.parent.html")
        #expect(URLComponents(url: entry, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "fd", value: "1")])
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

    @Test("log label keeps host and path, never the query")
    func logLabel() {
        let url = URL(string: "https://cas.example.fr/cas/login?ticket=ST-secret#frag")
        #expect(PronoteMobileLogin.logLabel(url) == "cas.example.fr/cas/login")
        #expect(PronoteMobileLogin.logLabel(nil) == "nil")
    }

    @Test("trigger script calls the page's application handshake, escaped")
    func trigger() {
        let script = PronoteMobileLogin.triggerScript(deviceUUID: "a'b")
        #expect(script.contains("GInterface"))
        #expect(script.contains("GApplication"))
        #expect(script.contains("passerEnModeValidationAppliMobile"))
        #expect(script.contains("o[name]('', 'a\\'b')"))
        #expect(script.contains("'no-method'"))
    }

    @Test("hook script escapes the device id and defines the Pronote hook")
    func hook() {
        let script = PronoteMobileLogin.hookScript(deviceUUID: "a'b")
        #expect(script.contains("window.hookAccesDepuisAppli"))
        #expect(script.contains("passerEnModeValidationAppliMobile('', 'a\\'b')"))
    }

    @Test("infoMobileApp URL and detection on the instance host")
    func infoMobileApp() throws {
        let instance = try #require(URL(string: "https://0000000a.index-education.net/pronote"))
        let url = try #require(PronoteMobileLogin.infoMobileAppURL(instance: instance))
        #expect(url.absoluteString == "https://0000000a.index-education.net/pronote/infoMobileApp.json?id=0D264427-EEFC-4810-A9E9-346942A862A4")
        #expect(PronoteMobileLogin.isInfoMobileApp(url, of: instance))
        let other = try #require(URL(string: "https://auth.monlycee.net/infoMobileApp.json"))
        #expect(!PronoteMobileLogin.isInfoMobileApp(other, of: instance))
    }

    @Test("app cookie script sets the three cookies and goes to the plain page")
    func appModeCookies() throws {
        let next = try #require(URL(string: "https://x.index-education.net/pronote/mobile.parent.html?fd=1"))
        let script = PronoteMobileLogin.appModeCookieScript(deviceUUID: "a'b", next: next)
        #expect(script.contains("validationAppliMobile="))
        #expect(script.contains("jetonCAS"))
        #expect(script.contains("'uuidAppliMobile=' + 'a\\'b'"))
        #expect(script.contains("ielang=1036"))
        #expect(script.contains("window.location.assign('https://x.index-education.net/pronote/mobile.parent.html?fd=1')"))
        #expect(!script.contains("bydlg"))
    }
}
