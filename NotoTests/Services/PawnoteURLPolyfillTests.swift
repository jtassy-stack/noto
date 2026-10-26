import Testing
import Foundation
import JavaScriptCore
@testable import Noto

/// pawnote builds Pronote page URLs with `searchParams.set(...)`. The
/// JavaScriptCore polyfill used to freeze `href` at construction, so `fd=1`,
/// `bydlg` and `login` never reached the request and Pronote 2026.2.7 served
/// « Votre navigateur est incompatible » to the MonLycée → Pronote login.
@Suite("Pawnote URL polyfill")
struct PawnoteURLPolyfillTests {

    private func evaluate(_ script: String) -> String? {
        let context = JSContext()!
        // Exercise the polyfill even if a JavaScriptCore build ships URL.
        context.evaluateScript("delete globalThis.URL; delete globalThis.URLSearchParams;")
        context.evaluateScript(PawnoteBridge.urlPolyfillJS)
        return context.evaluateScript(script)?.toString()
    }

    @Test("searchParams.set reaches href and toString")
    func setReachesHref() {
        let href = evaluate("""
            (() => {
                const u = new URL("https://0000000x.index-education.net/pronote/mobile.parent.html");
                u.searchParams.set("fd", "1");
                u.searchParams.set("bydlg", "A6ABB224-12DD-4E31-AD3E-8A39A1C2C335");
                u.searchParams.set("login", "true");
                return u.toString() === u.href ? u.href : "mismatch";
            })()
            """)
        #expect(href == "https://0000000x.index-education.net/pronote/mobile.parent.html?fd=1&bydlg=A6ABB224-12DD-4E31-AD3E-8A39A1C2C335&login=true")
    }

    @Test("an existing query is kept and can be overwritten")
    func existingQuery() {
        let href = evaluate("""
            (() => {
                const u = new URL("https://p.example/pronote/mobile.eleve.html?fd=1&a=b#top");
                u.searchParams.set("a", "c d");
                return u.href;
            })()
            """)
        #expect(href == "https://p.example/pronote/mobile.eleve.html?fd=1&a=c%20d#top")
    }

    @Test("no query keeps the bare URL")
    func bareURL() {
        let href = evaluate(#"new URL("https://p.example/pronote/").href"#)
        #expect(href == "https://p.example/pronote/")
    }
}
