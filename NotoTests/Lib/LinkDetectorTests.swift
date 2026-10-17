import Testing
import Foundation
@testable import Noto

/// Retour TestFlight build 230 (16/10) : « Il faut pouvoir cliquer sur les
/// liens. » Ces tests figent la détection (NSDataDetector → AttributedString)
/// et la liste blanche http/https/mailto.
@Suite("LinkDetector")
struct LinkDetectorTests {

    private func linkedRuns(_ text: String) -> [(String, URL)] {
        let attributed = LinkDetector.attributed(text)
        return attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed[run.range].characters), url)
        }
    }

    @Test func detectsHttpsURLFromTestFlightCapture() {
        let text = "EPS : préparez votre échauffement sur https://timely-bunny-f47685.netlify.app/ avant jeudi."
        let links = LinkDetector.links(in: text)
        #expect(links.count == 1)
        #expect(links.first?.url.absoluteString == "https://timely-bunny-f47685.netlify.app/")
        #expect(links.first.map { String(text[$0.range]) } == "https://timely-bunny-f47685.netlify.app/")
    }

    @Test func bareWwwBecomesHttp() {
        let links = LinkDetector.links(in: "Voir www.lumni.fr pour réviser")
        #expect(links.count == 1)
        #expect(links.first?.url.scheme == "http")
        #expect(links.first?.url.host == "www.lumni.fr")
    }

    @Test func trailingPunctuationIsExcluded() {
        let runs = linkedRuns("Le sujet (https://exemple.fr/sujet).")
        #expect(runs.count == 1)
        #expect(runs.first?.0 == "https://exemple.fr/sujet")
    }

    @Test func emailBecomesMailto() {
        let links = LinkDetector.links(in: "Écrire à prof.martin@college-exemple.fr si besoin")
        #expect(links.count == 1)
        #expect(links.first?.url.scheme == "mailto")
        #expect(links.first?.url.absoluteString.contains("prof.martin@college-exemple.fr") == true)
    }

    @Test func multipleLinksInOrder() {
        let text = "Cours : https://a.fr/1 puis http://b.fr/2 et contact@ecole.fr"
        let urls = LinkDetector.links(in: text).map(\.url.absoluteString)
        #expect(urls.count == 3)
        guard urls.count == 3 else { return }
        #expect(urls[0] == "https://a.fr/1")
        #expect(urls[1] == "http://b.fr/2")
        #expect(urls[2].hasPrefix("mailto:"))
    }

    @Test func disallowedSchemesAreDropped() {
        #expect(LinkDetector.links(in: "Fichier : ftp://serveur.fr/devoir.pdf").isEmpty)
        #expect(LinkDetector.links(in: "Appeler le 01 23 45 67 89").isEmpty)
    }

    @Test(arguments: [
        ("https://a.fr", true),
        ("HTTPS://A.FR", true),
        ("http://a.fr", true),
        ("mailto:a@b.fr", true),
        ("javascript:alert(1)", false),
        ("data:text/html,hello", false),
        ("tel:0123456789", false),
        ("ftp://a.fr", false),
        ("pronote://login", false),
    ])
    func allowlist(raw: String, allowed: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkDetector.isAllowed(url) == allowed)
    }

    @Test func urlWithoutSchemeIsNotAllowed() throws {
        let url = try #require(URL(string: "exemple.fr/page"))
        #expect(LinkDetector.isAllowed(url) == false)
    }

    @Test func emptyAndPlainTextHaveNoLinks() {
        #expect(LinkDetector.links(in: "").isEmpty)
        #expect(LinkDetector.links(in: "Exercices 3 et 4 page 52, Ex. 5. Moyenne 3.14").isEmpty)
        #expect(linkedRuns("Apprendre la leçon").isEmpty)
    }

    @Test func textIsNeverMutated() {
        let text = "Lien 🎉 : https://exemple.fr — et mail@ecole.fr.\nFin"
        #expect(String(LinkDetector.attributed(text).characters) == text)
    }

    @Test func offsetsSurviveEmojiAndAccentsBeforeURL() {
        let text = "Élèves 👩🏽‍🏫🎉 : révisez https://exemple.fr/eval ici"
        let runs = linkedRuns(text)
        #expect(runs.count == 1)
        #expect(runs.first?.0 == "https://exemple.fr/eval")
        #expect(runs.first?.1.absoluteString == "https://exemple.fr/eval")
    }

    @Test func onlyLinkRunsCarryALink() {
        let attributed = LinkDetector.attributed("Voir https://exemple.fr demain")
        let runs = Array(attributed.runs)
        #expect(runs.count == 3)
        #expect(runs.filter { $0.link != nil }.count == 1)
    }
}
