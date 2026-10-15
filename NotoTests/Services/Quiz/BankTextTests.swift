import Testing
@testable import Noto

@Suite("BankText — inline Markdown from the quiz bank")
struct BankTextTests {
    @Test("emphasis markers are interpreted, not shown")
    func emphasis() {
        #expect(BankText.plain("Quel auteur latin a écrit *Les Métamorphoses* ?") == "Quel auteur latin a écrit Les Métamorphoses ?")
        #expect(BankText.plain("Le roman **Germinal** de Zola") == "Le roman Germinal de Zola")
    }

    @Test("plain text and maths symbols are untouched")
    func plainUntouched() {
        #expect(BankText.plain("Combien font 3 × 4 ?") == "Combien font 3 × 4 ?")
        #expect(BankText.plain("x² - 3 = 0") == "x² - 3 = 0")
    }

    @Test("every bundled question, choice and explanation renders without stray asterisks pairs")
    func bundledBankClean() throws {
        for grade in ["6e", "2nde"] {
            let page = try #require(try BundledQuizBank.load(grade: grade))
            for item in page.items {
                for raw in [item.question, item.explanation ?? ""] + item.choices {
                    let plain = BankText.plain(raw)
                    #expect(!plain.contains("**"), "\(grade): \(raw)")
                }
            }
        }
    }
}
