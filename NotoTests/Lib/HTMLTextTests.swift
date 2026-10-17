import Testing
@testable import Noto

@Suite("HTMLText")
struct HTMLTextTests {
    @Test("Adjacent blocks never merge into one link")
    func blocksStaySeparate() {
        let text = HTMLText.plainText(fromHTML: "<p>https://example.com/a</p><p>/next</p>")
        #expect(text == "https://example.com/a\n/next")
    }

    @Test("Breaks become newlines, entities are decoded")
    func breaksAndEntities() {
        #expect(HTMLText.plainText(fromHTML: "Bonjour<br/>Voir&nbsp;: a &amp; b") == "Bonjour\nVoir : a & b")
    }

    @Test("Plain text passes through")
    func plain() {
        #expect(HTMLText.plainText(fromHTML: "  Rendez-vous lundi  ") == "Rendez-vous lundi")
    }
}
