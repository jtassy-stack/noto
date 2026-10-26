import Testing
import Foundation
@testable import Noto

/// Cookies copied from the MonLycée login web view for `loginENT`.
@Suite("Pawnote cookie transfer")
struct PawnoteCookieTransferTests {
    @Test("Pronote host, ENT and CAS only")
    func cookieDomains() {
        let host = "0000000a.index-education.net"
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: host, pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: ".index-education.net", pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: "auth.monlycee.net", pronoteHost: host))
        #expect(PawnoteBridge.shouldTransfer(cookieDomain: ".monlycee.net", pronoteHost: nil))
        #expect(!PawnoteBridge.shouldTransfer(cookieDomain: ".google.com", pronoteHost: host))
        #expect(!PawnoteBridge.shouldTransfer(cookieDomain: "", pronoteHost: host))
    }
}
