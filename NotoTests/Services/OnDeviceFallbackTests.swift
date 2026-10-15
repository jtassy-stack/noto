import Testing
import Foundation
@testable import Noto

/// Pure checks around the FoundationModels paths of `TextSummarizer` and
/// `MeetingExtractionService` (the model itself cannot run in unit tests):
/// the briefing tone gate and the meeting-fact parser. On the simulator the
/// model is unavailable, so `summarize` / `extract` take their existing
/// rule-based paths.
@Suite("On-device model fallbacks")
struct OnDeviceFallbackTests {
    @Test("briefing output must address the parent and stay short")
    func briefingGate() {
        #expect(TextSummarizer.isAcceptableBriefing("Votre enfant a 5 cours aujourd'hui et un contrôle demain."))
        #expect(!TextSummarizer.isAcceptableBriefing("Tu as 5 cours aujourd'hui."))
        #expect(!TextSummarizer.isAcceptableBriefing("N'oublie pas ton cahier."))
        #expect(!TextSummarizer.isAcceptableBriefing(""))
        #expect(!TextSummarizer.isAcceptableBriefing(String(repeating: "a", count: TextSummarizer.maxBriefingLength + 1)))
    }

    @Test("empty items keep the template text")
    func emptySummary() async {
        #expect(await TextSummarizer.summarize(briefingItems: []) == "Rien de particulier à signaler aujourd'hui.")
    }

    @Test("meeting facts: kinds, family names, dates for agenda only")
    func parseFacts() throws {
        let drafts = [
            MeetingFactDraft(kind: "agenda", childName: "lea", title: "Sortie au musée",
                             detail: "Prévoir un pique-nique", dueDate: "2026-11-20"),
            MeetingFactDraft(kind: "Contact", childName: "Paul", title: "Mme Martin, CPE",
                             detail: "", dueDate: "2026-11-20"),
            MeetingFactDraft(kind: "rumeur", childName: "", title: "Ignoré", detail: "", dueDate: ""),
            MeetingFactDraft(kind: "policy", childName: "", title: "   ", detail: "", dueDate: ""),
            MeetingFactDraft(kind: "agenda", childName: "", title: String(repeating: "x", count: 120),
                             detail: "", dueDate: "20 novembre"),
        ]
        let items = MeetingExtractionService.parseFacts(drafts, childNames: ["Léa"])
        #expect(items.count == 3)

        let agenda = items[0]
        #expect(agenda.kind == .agenda)
        #expect(agenda.childName == "Léa")
        #expect(agenda.detail == "Prévoir un pique-nique")
        let due = try #require(agenda.dueDate)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: due)
        #expect(day.year == 2026 && day.month == 11 && day.day == 20)
        #expect(agenda.confirmedByUser == false)
        #expect(agenda.confidence == MeetingExtractionService.modelConfidence)

        let contact = items[1]
        #expect(contact.kind == .contact)
        #expect(contact.childName == nil)     // not a child of this family
        #expect(contact.dueDate == nil)       // dates only on agenda items
        #expect(contact.detail == nil)

        #expect(items[2].title.count == 80)
        #expect(items[2].dueDate == nil)      // unparseable date dropped, item kept
    }
}
