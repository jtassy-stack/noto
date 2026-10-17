import Testing
import Foundation
import SwiftData
@testable import Noto

/// A quiz on one subject or one theme (`QuizFocus`), and what the result
/// reports about notions and badges. In-memory `NotoSchemaV1` container,
/// `QuizCurriculumFixtures` (4e), no network.
@MainActor
@Suite("QuizSession focus")
struct QuizFocusTests {
    let context: ModelContext
    let clock = QuizTestClock(QuizClock.now)

    static let moliere = ("Français", "Molière et le théâtre classique")
    static let amour = ("Français", "Dire l'amour")
    static let fantastique = ("Français", "Le récit fantastique")
    static let pythagore = ("Mathématiques", "Théorème de Pythagore")
    static let revolution = ("Histoire", "La Révolution française")

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func makeChild() -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: "4ème", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func addItems(_ subjectTheme: (String, String), count: Int) {
        for n in 0..<count {
            let question = "Question \(n) sur \(subjectTheme.1) ?"
            let choices = ["Choix A\(n)", "Choix B\(n)", "Choix C\(n)", "Choix D\(n)"]
            let key = QuizKey.make(question: question, choices: choices)
            context.insert(QuizItem(id: QuizKey.deterministicID(for: key + "4e"), questionKey: key, kind: "programme",
                                    question: question, choices: choices, answerIndex: 1,
                                    explanation: "Parce que.", domain: "programme", difficulty: 1,
                                    level: "4e", subject: subjectTheme.0, theme: subjectTheme.1,
                                    source: .celyn, sourceRef: "celyn/bank/4e", reviewed: true,
                                    fetchedAt: QuizClock.now))
        }
    }

    private func makeSession(_ child: Child, focus: QuizFocus?) -> QuizSession {
        let clock = self.clock
        return QuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                           config: .default, calendar: QuizClock.calendar, seed: 7, now: { clock.now },
                           focus: focus)
    }

    private func playAllRight(_ session: QuizSession) {
        for index in session.questions.indices {
            session.answer(session.questions[index].answerIndex)
            if index < session.questions.count - 1 { session.advance() }
        }
        clock.now = QuizClock.now.addingTimeInterval(90)
        session.advance()
    }

    @Test("a subject quiz only draws that subject")
    func subjectFocus() throws {
        let child = makeChild()
        addItems(Self.moliere, count: 3)
        addItems(Self.amour, count: 3)
        addItems(Self.pythagore, count: 3)
        addItems(Self.revolution, count: 3)
        try context.save()

        let session = makeSession(child, focus: QuizFocus(subject: "Français"))
        #expect(session.questions.count == QuizSession.questionCount)
        #expect(session.questions.allSatisfy { $0.subject == "Français" })
    }

    @Test("a subject quiz accepts the Pronote label")
    func subjectAlias() throws {
        let child = makeChild()
        addItems(Self.pythagore, count: 5)
        addItems(Self.moliere, count: 5)
        try context.save()

        let session = makeSession(child, focus: QuizFocus(subject: "MATHEMATIQUES"))
        #expect(!session.questions.isEmpty)
        #expect(session.questions.allSatisfy { $0.subject == "Mathématiques" })
    }

    @Test("a theme quiz only draws that theme, even one not reached by the calendar yet")
    func themeFocus() throws {
        let child = makeChild()
        // « Le récit fantastique » is T2: never in the quiz of the day in November.
        addItems(Self.fantastique, count: 5)
        addItems(Self.moliere, count: 5)
        try context.save()

        let session = makeSession(child, focus: QuizFocus(subject: "Français", theme: Self.fantastique.1))
        #expect(session.questions.count == QuizSession.questionCount)
        #expect(session.questions.allSatisfy { $0.theme == Self.fantastique.1 })
    }

    @Test("a focus with no question opens empty")
    func emptyFocus() throws {
        let child = makeChild()
        addItems(Self.moliere, count: 5)
        try context.save()

        #expect(makeSession(child, focus: QuizFocus(subject: "Histoire")).phase == .empty)
        #expect(QuizSession.availableCount(for: child, in: context, now: QuizClock.now,
                                           focus: QuizFocus(subject: "Histoire")) == 0)
        #expect(QuizSession.availableCounts(for: child, in: context, now: QuizClock.now,
                                            focuses: [QuizFocus(subject: "Français"),
                                                      QuizFocus(subject: "Français", theme: Self.moliere.1),
                                                      QuizFocus(subject: "Histoire")]) == [5, 5, 0])
    }

    @Test("the result lists the notions played and the badge unlocked")
    func resultNotionsAndBadges() throws {
        let child = makeChild()
        addItems(Self.moliere, count: 5)
        try context.save()

        let session = makeSession(child, focus: QuizFocus(subject: "Français", theme: Self.moliere.1))
        playAllRight(session)
        let result = try #require(session.result)
        #expect(result.notions.map(\.theme) == [Self.moliere.1])
        #expect(result.notions.first?.correct == true)
        #expect(result.newBadges.contains { $0.kind == .firstQuiz })
    }
}

@MainActor
@Suite("Résultat : tes notions")
struct NotionStatusCopyTests {
    private let paris = QuizClock.calendar

    private func outcome(box: Int, correct: Bool, reviewInDays days: Int) -> NotionOutcome {
        NotionOutcome(notionKey: "k", theme: "Thème", box: box, correct: correct,
                      nextReview: QuizClock.date(day: days, hour: 6))
    }

    @Test func wording() {
        let now = QuizClock.date(day: 0, hour: 18)
        #expect(QuizResultView.notionStatus(outcome(box: 4, correct: true, reviewInDays: 8), now: now,
                                            calendar: paris) == "maîtrisée")
        #expect(QuizResultView.notionStatus(outcome(box: 2, correct: true, reviewInDays: 2), now: now,
                                            calendar: paris) == "en progrès")
        #expect(QuizResultView.notionStatus(outcome(box: 1, correct: false, reviewInDays: 1), now: now,
                                            calendar: paris) == "revient demain")
        #expect(QuizResultView.notionStatus(outcome(box: 1, correct: false, reviewInDays: 3), now: now,
                                            calendar: paris) == "revient dans 3 jours")
    }

    @Test func metThemesAreSeenOrPlayed() {
        let subject = SubjectProgress(subject: "Français", themes: [
            ThemeProgress(theme: "Molière et le théâtre classique", box: 2),
            ThemeProgress(theme: "Le récit fantastique", box: 0),
        ])
        let met = SubjectPathView.metThemes(of: subject, inClass: [], position: .empty)
        #expect(met.map(\.theme) == ["Molière et le théâtre classique"])
    }
}
