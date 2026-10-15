import Testing
import Foundation
import SwiftData
@testable import Noto

/// 3.3 on-device generation, without FoundationModels (it cannot run in unit
/// tests): the pure post-validation, the per-quiz orchestration
/// (`QuizGenerator.questions`) and the `QuizSession.make` fallback path with
/// a stub `QuizGenerating`.

// MARK: - Fixtures

private enum GenFixtures {
    static let text = "Lire la nouvelle Le Horla de Maupassant et relever les marques du fantastique. Exercice 13 p. 42."

    static func request(text: String = GenFixtures.text, subject: String = "Français",
                        homeworkSubject: String = "FRANCAIS", bankAnswers: [String] = [],
                        key: String = "hw-1") -> QuizGenerationRequest {
        QuizGenerationRequest(level: "4e", subject: subject, theme: "Le récit fantastique",
                              notionKey: "4e|Français|Le récit fantastique", homeworkKey: key,
                              homeworkSubject: homeworkSubject, homeworkText: text,
                              dueDateText: "mercredi 15 novembre", bankAnswers: bankAnswers)
    }

    static func candidate(_ question: String = "Quel auteur a écrit la nouvelle que tu dois lire ?",
                          choices: [String] = ["Maupassant", "Zola", "Hugo", "Balzac"],
                          answer: Int = 0,
                          explanation: String = "Le Horla est une nouvelle de Maupassant.") -> QuizCandidate {
        QuizCandidate(question: question, choices: choices, answerIndex: answer, explanation: explanation)
    }
}

/// Records every request, then answers after `delay` (cancellable sleep).
private actor CallLog {
    private(set) var requests: [QuizGenerationRequest] = []
    func record(_ request: QuizGenerationRequest) { requests.append(request) }
}

private struct StubGenerator: QuizGenerating {
    let candidates: [QuizCandidate]?
    var delay: Duration = .zero
    let log = CallLog()

    func generate(_ request: QuizGenerationRequest) async -> [QuizCandidate]? {
        await log.record(request)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return candidates
    }
}

// MARK: - Validation

@Suite("QuizGenerationValidator")
struct QuizGenerationValidatorTests {
    typealias V = QuizGenerationValidator

    @Test("answer found in the homework text, case and accent insensitive")
    func groundedInText() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["MAUPASSANT", "Zola", "Hugo", "Balzac"]),
                            request: request) == nil)
        let accent = GenFixtures.request(text: "Revoir le théorème de Pythagore et l'hypoténuse.")
        #expect(V.isGrounded(answer: "Hypotenuse", request: accent))
        #expect(V.isGrounded(answer: "l'HYPOTÉNUSE", request: accent))
    }

    @Test("answer absent from the text and the bank is rejected")
    func notGrounded() {
        let c = GenFixtures.candidate(choices: ["Victor Hugo", "Zola", "Maupassant", "Balzac"], answer: 0)
        #expect(V.rejection(for: c, request: GenFixtures.request()) == .notGrounded)
    }

    @Test("answer equal to a bank answer of the same theme is accepted")
    func bankAnswer() {
        let c = GenFixtures.candidate("Quel auteur de récit fantastique dois-tu connaître ?",
                                      // No distractor may appear in the homework text (Maupassant does:
                                      // that would be .ambiguousDistractor, tested separately).
                                      choices: ["Théophile Gautier", "Zola", "Flaubert", "Balzac"], answer: 0,
                                      explanation: "C'est un récit fantastique de Gautier.")
        #expect(V.rejection(for: c, request: GenFixtures.request()) == .notGrounded)
        let withBank = GenFixtures.request(bankAnswers: ["theophile GAUTIER"])
        #expect(V.rejection(for: c, request: withBank) == nil)
    }

    @Test("short answers only match whole words")
    func shortAnswerWholeWord() {
        let request = GenFixtures.request()
        #expect(V.isGrounded(answer: "13", request: request))
        #expect(!V.isGrounded(answer: "3", request: request))
        #expect(V.isGrounded(answer: "la", request: request))              // a word of the text
        #expect(!V.isGrounded(answer: "ho", request: request))            // inside "Horla" only
    }

    @Test("long answers match whole words too, in the homework text only")
    func wholeWordAndNoScaffolding() {
        let romeo = GenFixtures.request(text: "Lire Roméo et Juliette, acte I.")
        #expect(!V.isGrounded(answer: "Rome", request: romeo))
        #expect(V.isGrounded(answer: "Roméo", request: romeo))
        let revolution = GenFixtures.request(text: "Réviser la révolution industrielle.")
        #expect(!V.isGrounded(answer: "volution", request: revolution))
        // « Matière : … / Pour le … » is prompt scaffolding, not homework.
        #expect(!V.isGrounded(answer: "Matière", request: GenFixtures.request()))
        #expect(!V.isGrounded(answer: "novembre", request: GenFixtures.request()))
    }

    @Test("a word of a compound subject label is trivial")
    func trivialSubjectWord() {
        let request = GenFixtures.request(text: "Réviser la géographie des métropoles.", subject: "Histoire",
                                          homeworkSubject: "HISTOIRE-GEOGRAPHIE")
        #expect(V.isTrivial(answer: "Géographie", request: request))
        #expect(V.isTrivial(answer: "histoire", request: request))
        #expect(!V.isTrivial(answer: "métropoles", request: request))
    }

    @Test("a stem naming something absent from the homework is rejected")
    func ungroundedStem() {
        let request = GenFixtures.request(text: "Lire Les Misérables de Victor Hugo.")
        let made_up = GenFixtures.candidate("Qui a écrit Germinal ?",
                                            choices: ["Victor Hugo", "Zola", "Balzac", "Sand"], answer: 0)
        #expect(V.rejection(for: made_up, request: request) == .ungroundedStem)
        let fine = GenFixtures.candidate("Qui a écrit Les Misérables ?",
                                         choices: ["Victor Hugo", "Zola", "Balzac", "Sand"], answer: 0)
        #expect(V.rejection(for: fine, request: request) == nil)
    }

    @Test("a wrong answer that is also in the homework is ambiguous")
    func ambiguousDistractor() {
        let c = GenFixtures.candidate(choices: ["Maupassant", "Horla", "Hugo", "Balzac"], answer: 0)
        #expect(V.rejection(for: c, request: GenFixtures.request()) == .ambiguousDistractor)
    }

    @Test("links of any shape are rejected")
    func links() {
        let request = GenFixtures.request()
        for text in ["Regarde https://youtu.be/abc", "Va sur www.lumni.fr", "Lis [ce texte](javascript:x)",
                     "Le cours est sur ent.college.fr", "Voir <https://x.y>"] {
            #expect(V.rejection(for: GenFixtures.candidate(explanation: text), request: request) == .link)
        }
        #expect(!V.containsLink("Exercice 13 p. 42. Relire le chapitre 3."))
    }

    @Test("the explanation shown quotes the homework, never the model")
    func quote() {
        let request = GenFixtures.request()
        let q = V.question(from: GenFixtures.candidate(explanation: "Maupassant a écrit Germinal."),
                           request: request)
        #expect(q.explanation == "D'après ton devoir : « Lire la nouvelle Le Horla de Maupassant et relever les marques du fantastique. »")
        let bank = GenFixtures.request(bankAnswers: ["Théophile Gautier"])
        let fromBank = V.question(from: GenFixtures.candidate(choices: ["Théophile Gautier", "Zola", "Hugo", "Balzac"]),
                                  request: bank)
        #expect(fromBank.explanation == nil)
        let linked = GenFixtures.request(text: "Lire Le Horla de Maupassant sur https://example.org/horla.")
        #expect(V.question(from: GenFixtures.candidate(), request: linked).explanation == nil)
    }

    @Test("choice count, empty and duplicate choices")
    func choices() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "Zola", "Hugo"]),
                            request: request) == .choiceCount)
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "Zola", "Hugo", "Balzac", "Sand"]),
                            request: request) == .choiceCount)
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "  ", "Hugo", "Balzac"]),
                            request: request) == .emptyChoice)
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "?!", "Hugo", "Balzac"]),
                            request: request) == .emptyChoice)
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "Zola", "zola ", "Balzac"]),
                            request: request) == .duplicateChoices)
        #expect(V.rejection(for: GenFixtures.candidate(choices: ["Maupassant", "Émile Zola", "emile zola", "Balzac"]),
                            request: request) == .duplicateChoices)
    }

    @Test("answer index must be 0…3")
    func answerIndex() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate(answer: 4), request: request) == .answerIndexOutOfRange)
        #expect(V.rejection(for: GenFixtures.candidate(answer: -1), request: request) == .answerIndexOutOfRange)
    }

    @Test("empty, non-question or overlong stem")
    func questionShape() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate("   "), request: request) == .emptyQuestion)
        #expect(V.rejection(for: GenFixtures.candidate("Tu dois identifier l'auteur de la nouvelle."),
                            request: request) == .notAQuestion)
        #expect(V.rejection(for: GenFixtures.candidate(String(repeating: "a", count: 400) + " ?"),
                            request: request) == .tooLong)
    }

    @Test("a choice that contains another one is ambiguous")
    func overlapping() {
        // Seen on device: the full list as one choice, one of its items as another.
        let c = GenFixtures.candidate("Qu'est-ce qui est une marque du fantastique ?",
                                      choices: ["le doute du narrateur, le journal intime", "le doute du narrateur",
                                                "le rêve", "la peur"], answer: 1)
        #expect(V.rejection(for: c, request: GenFixtures.request(text: "Relever le doute du narrateur, le journal intime.")) == .overlappingChoices)
        #expect(!V.hasOverlap(["14 juillet", "26 aout", "4 aout", "1er mai"]))
        #expect(V.hasOverlap(["14 juillet 1789", "1789", "1790", "1791"]))
    }

    @Test("assemble puts the right answer at a stable position")
    func assemble() {
        let a = QuizCandidate.assemble(question: "Quel auteur dois-tu lire ?", correctAnswer: "Maupassant",
                                       wrongAnswers: ["Zola", "Hugo", "Balzac"], explanation: "")
        let b = QuizCandidate.assemble(question: "Quel auteur dois-tu lire ?", correctAnswer: "Maupassant",
                                       wrongAnswers: ["Zola", "Hugo", "Balzac"], explanation: "")
        #expect(a == b)
        #expect(a.choices.count == 4)
        #expect(a.choices[a.answerIndex] == "Maupassant")
        #expect(Set(a.choices) == ["Maupassant", "Zola", "Hugo", "Balzac"])
        // Different questions do not all put the answer first.
        let positions = Set((0..<12).map {
            QuizCandidate.assemble(question: "Question \($0) ?", correctAnswer: "R",
                                   wrongAnswers: ["A", "B", "C"], explanation: "").answerIndex
        })
        #expect(positions.count > 1)
        // A short list from the model: still consistent, the validator rejects the count.
        let short = QuizCandidate.assemble(question: "Q ?", correctAnswer: "R", wrongAnswers: ["A"], explanation: "")
        #expect(short.choices[short.answerIndex] == "R")
    }

    @Test("parent tone (vouvoiement) is rejected, child tone accepted")
    func tone() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate("Quel auteur votre enfant doit-il lire ?"),
                            request: request) == .parentTone)
        #expect(V.rejection(for: GenFixtures.candidate(explanation: "Vous lirez Le Horla de Maupassant."),
                            request: request) == .parentTone)
        #expect(V.rejection(for: GenFixtures.candidate("Quel auteur dois-tu lire pour demain ?"),
                            request: request) == nil)
    }

    @Test("sensitive words and contact data are rejected")
    func sensitive() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate("Quelle drogue Maupassant prenait-il ?"),
                            request: request) == .sensitiveContent)
        #expect(V.rejection(for: GenFixtures.candidate(explanation: "Écris à prof@college.fr"),
                            request: request) == .sensitiveContent)
        #expect(V.rejection(for: GenFixtures.candidate(explanation: "Appelle le 06 12 34 56 78"),
                            request: request) == .sensitiveContent)
        #expect(!V.containsSensitiveContent("Exercice 13 p. 42, pour le 15 novembre 2023"))
    }

    @Test("an answer that is only the due date or the subject is trivial")
    func trivial() {
        let request = GenFixtures.request()
        #expect(V.rejection(for: GenFixtures.candidate("Pour quel jour est ton devoir ?",
                                                       choices: ["mercredi", "lundi", "jeudi", "vendredi"]),
                            request: request) == .trivial)
        #expect(V.rejection(for: GenFixtures.candidate("En quelle matière est ce devoir ?",
                                                       choices: ["Français", "Maths", "Histoire", "Anglais"]),
                            request: request) == .trivial)
    }

    @Test("at most 3 generated questions, whatever maxCount asks")
    func cap() {
        let authors = ["Maupassant", "Horla", "fantastique", "nouvelle", "marques"]
        let candidates = authors.enumerated().map { index, answer in
            GenFixtures.candidate("Question \(index) ?", choices: [answer, "Zola", "Hugo", "Balzac"])
        }
        let three = V.validate(candidates, request: GenFixtures.request(), maxCount: 10)
        #expect(three.accepted.count == 3)
        #expect(three.rejections == [.overCap, .overCap])

        let one = V.validate(candidates, request: GenFixtures.request(), maxCount: 1)
        #expect(one.accepted.count == 1)
        #expect(one.rejections.count == 4)
    }

    @Test("validate keeps reasons in order and drops exact duplicates")
    func validateMixed() {
        let good = GenFixtures.candidate()
        let result = V.validate([GenFixtures.candidate(answer: 7), good, good,
                                 GenFixtures.candidate(choices: ["Hugo", "Zola", "Sand", "Balzac"])],
                                request: GenFixtures.request())
        #expect(result.accepted == [good])
        #expect(result.rejections == [.answerIndexOutOfRange, .notGrounded])
    }

    @Test("accepted candidate maps to an ephemeral, generated QuizQuestion")
    func mapping() {
        let request = GenFixtures.request()
        let c = GenFixtures.candidate("  Quel auteur dois-tu lire ?  ",
                                      choices: [" Maupassant ", "Zola", "Hugo", "Balzac"])
        let q = V.question(from: c, request: request)
        #expect(q.isGenerated)
        #expect(q.question == "Quel auteur dois-tu lire ?")
        #expect(q.choices == ["Maupassant", "Zola", "Hugo", "Balzac"])
        #expect(q.answerIndex == 0)
        #expect(q.subject == "Français")
        #expect(q.theme == "Le récit fantastique")
        // Unreviewed output never moves the Leitner box.
        #expect(q.notionKey == nil)
        // One stable key per homework: a reworded regeneration is still a replay.
        #expect(q.questionKey == V.questionKey(homeworkKey: "hw-1"))
        let reworded = V.question(from: GenFixtures.candidate("Qui est l'auteur que tu dois lire ?"), request: request)
        #expect(reworded.questionKey == q.questionKey)
        #expect(q.difficulty == 1)
    }

    @Test("source text is subject + due date + description, cut to 1500")
    func sourceText() {
        let request = GenFixtures.request(text: String(repeating: "x", count: 3000))
        #expect(request.homeworkText.count == QuizGenerationRequest.maxHomeworkCharacters)
        #expect(request.sourceText.contains("FRANCAIS"))
        #expect(request.sourceText.contains("mercredi 15 novembre"))
    }
}

// MARK: - Orchestration

@Suite("QuizGenerator.questions")
struct QuizGeneratorOrchestrationTests {
    @Test("nil from the generator leaves the slot to the bank")
    func nilResult() async {
        let stub = StubGenerator(candidates: nil)
        let result = await QuizGenerator.questions(for: [GenFixtures.request()], using: stub)
        #expect(result.isEmpty)
        #expect(await stub.log.requests.count == 1)
    }

    @Test("one validated question per homework key")
    func accepted() async {
        let stub = StubGenerator(candidates: [GenFixtures.candidate(choices: ["Zola", "Hugo", "Balzac", "Sand"]),
                                              GenFixtures.candidate()])
        let result = await QuizGenerator.questions(for: [GenFixtures.request()], using: stub)
        #expect(result.count == 1)
        #expect(result["hw-1"]?.choices.first == "Maupassant")
        #expect(result["hw-1"]?.isGenerated == true)
    }

    @Test("timeout returns nothing, promptly")
    func timeout() async {
        let stub = StubGenerator(candidates: [GenFixtures.candidate()], delay: .seconds(30))
        let start = ContinuousClock.now
        let result = await QuizGenerator.questions(for: [GenFixtures.request()], using: stub,
                                                   timeout: .milliseconds(100))
        #expect(result.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("a timeout stops the run: no new session behind a busy model")
    func timeoutStops() async {
        let stub = StubGenerator(candidates: [GenFixtures.candidate()], delay: .seconds(30))
        let requests = (0..<3).map { GenFixtures.request(key: "hw-\($0)") }
        let result = await QuizGenerator.questions(for: requests, using: stub, timeout: .milliseconds(100))
        #expect(result.isEmpty)
        #expect(await stub.log.requests.count == 1)
    }

    @Test("never more than 3 generated questions per quiz")
    func capAcrossRequests() async {
        let stub = StubGenerator(candidates: [GenFixtures.candidate()])
        // Same candidate for every homework: only the first gets it (same
        // question key), so give each request its own text and answer.
        let requests = (0..<5).map { GenFixtures.request(key: "hw-\($0)") }
        let distinct = await QuizGenerator.questions(for: requests, using: DistinctStub())
        #expect(distinct.count == QuizGenerator.maxGeneratedPerQuiz)
        let same = await QuizGenerator.questions(for: requests, using: stub)
        #expect(same.count == 1)
    }

    @Test("a fully rejected batch gives nothing")
    func rejected() async {
        let stub = StubGenerator(candidates: [GenFixtures.candidate("Quel auteur votre enfant lit-il ?")])
        let result = await QuizGenerator.questions(for: [GenFixtures.request()], using: stub)
        #expect(result.isEmpty)
    }
}

/// A different grounded question per homework key.
private struct DistinctStub: QuizGenerating {
    func generate(_ request: QuizGenerationRequest) async -> [QuizCandidate]? {
        [GenFixtures.candidate("Question pour \(request.homeworkKey) ?")]
    }
}

// MARK: - QuizSession fallback path

@MainActor
@Suite("QuizSession.make (3.3)")
struct QuizSessionGenerationTests {
    let context: ModelContext
    let clock = QuizTestClock(QuizClock.now)

    static let moliere = ("Français", "Molière et le théâtre classique")
    static let fantastique = ("Français", "Le récit fantastique")
    static let amour = ("Français", "Dire l'amour")
    static let pythagore = ("Mathématiques", "Théorème de Pythagore")
    static let calcul = ("Mathématiques", "Calcul littéral et équations")
    static let revolution = ("Histoire", "La Révolution française")
    static let urbanisation = ("Géographie", "L'urbanisation du monde")

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

    private func addItem(_ subjectTheme: (String, String), _ n: Int = 0) {
        let question = "Question \(n) sur \(subjectTheme.1) ?"
        let choices = ["Choix A\(n)", "Choix B\(n)", "Choix C\(n)", "Choix D\(n)"]
        let key = QuizKey.make(question: question, choices: choices)
        context.insert(QuizItem(id: QuizKey.deterministicID(for: key + "4e"), questionKey: key, kind: "programme",
                                question: question, choices: choices, answerIndex: 1,
                                explanation: "Parce que.", domain: "programme", difficulty: 1,
                                level: "4e", subject: subjectTheme.0, theme: subjectTheme.1,
                                source: .bank, sourceRef: "test", reviewed: true, fetchedAt: QuizClock.now))
    }

    /// Bank with every planned theme except « Le récit fantastique ».
    private func addBankWithoutFantastique() {
        for theme in [Self.moliere, Self.pythagore, Self.revolution, Self.urbanisation, Self.amour, Self.calcul] {
            addItem(theme)
        }
    }

    /// Homework on Le Horla due tomorrow: the selector maps it to « Le récit
    /// fantastique » and puts it first.
    private func addHorlaHomework(_ child: Child) {
        let homework = Homework(subject: "FRANCAIS", description: GenFixtures.text, dueDate: QuizClock.date(day: 1))
        context.insert(homework)
        homework.child = child
    }

    private func make(_ child: Child, generator: (any QuizGenerating)?,
                      timeout: Duration = .seconds(8)) async -> QuizSession {
        let clock = self.clock
        return await QuizSession.make(child: child, modelContext: context,
                                      curriculum: QuizCurriculumFixtures.curriculum, config: .default,
                                      calendar: QuizClock.calendar, seed: 7, now: { clock.now },
                                      generator: generator, generationTimeout: timeout)
    }

    private func itemCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<QuizItem>())
    }

    @Test("no generator: same draw as the synchronous init")
    func noGenerator() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addHorlaHomework(child)
        try context.save()

        let made = await make(child, generator: nil)
        let clock = self.clock
        let plain = QuizSession(child: child, modelContext: context, curriculum: QuizCurriculumFixtures.curriculum,
                                config: .default, calendar: QuizClock.calendar, seed: 7, now: { clock.now })
        #expect(made.questions == plain.questions)
        #expect(!made.questions.contains { $0.isGenerated })
    }

    @Test("homework slot without a bank item gets the generated question first")
    func generatedFillsHomeworkSlot() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addHorlaHomework(child)
        try context.save()
        let before = try itemCount()

        let stub = StubGenerator(candidates: [GenFixtures.candidate()])
        let session = await make(child, generator: stub)

        #expect(session.phase == .inProgress)
        #expect(session.questions.count == QuizSession.questionCount)
        let first = try #require(session.questions.first)
        #expect(first.isGenerated)
        #expect(first.subject == "Français")
        #expect(first.theme == "Le récit fantastique")
        #expect(session.questions.filter(\.isGenerated).count == 1)
        // Ephemeral: nothing written to the shared bank.
        #expect(try itemCount() == before)

        let requests = await stub.log.requests
        #expect(requests.count == 1)
        #expect(requests.first?.homeworkText == GenFixtures.text)
        #expect(requests.first?.homeworkSubject == "FRANCAIS")
        #expect(requests.first?.theme == "Le récit fantastique")
    }

    @Test("rejected output falls back to the bank-only draw")
    func rejectedFallsBack() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addHorlaHomework(child)
        try context.save()

        let bankOnly = await make(child, generator: nil)
        let ungrounded = StubGenerator(candidates: [
            GenFixtures.candidate(choices: ["Victor Hugo", "Zola", "Sand", "Balzac"]),
        ])
        let session = await make(child, generator: ungrounded)
        #expect(session.questions == bankOnly.questions)
        #expect(await ungrounded.log.requests.count == 1)
    }

    @Test("timeout falls back to the bank-only draw")
    func timeoutFallsBack() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addHorlaHomework(child)
        try context.save()

        let bankOnly = await make(child, generator: nil)
        let slow = StubGenerator(candidates: [GenFixtures.candidate()], delay: .seconds(30))
        let start = ContinuousClock.now
        let session = await make(child, generator: slow, timeout: .milliseconds(100))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(session.questions == bankOnly.questions)
        #expect(session.phase == .inProgress)
    }

    @Test("homework already covered by the bank: the generator is never called")
    func bankCoversHomework() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addItem(Self.fantastique)
        addHorlaHomework(child)
        try context.save()

        let stub = StubGenerator(candidates: [GenFixtures.candidate()])
        let session = await make(child, generator: stub)
        #expect(!session.questions.contains { $0.isGenerated })
        #expect(await stub.log.requests.isEmpty)
    }

    @Test("empty bank: the quiz stays empty and nothing is generated")
    func emptyBank() async throws {
        let child = makeChild()
        addHorlaHomework(child)
        try context.save()

        let stub = StubGenerator(candidates: [GenFixtures.candidate()])
        let session = await make(child, generator: stub)
        #expect(session.phase == .empty)
        #expect(await stub.log.requests.isEmpty)
    }

    @Test("thin bank: no generation, the quiz stays too short to earn minutes")
    func thinBank() async throws {
        let child = makeChild()
        addItem(Self.moliere)
        addItem(Self.pythagore)
        addHorlaHomework(child)
        try context.save()

        let stub = StubGenerator(candidates: [GenFixtures.candidate()])
        let session = await make(child, generator: stub)
        #expect(!session.questions.contains { $0.isGenerated })
        #expect(session.questions.count == 2)
        #expect(await stub.log.requests.isEmpty)
    }

    @Test("a generated question is scored and saved like any other")
    func playedThrough() async throws {
        let child = makeChild()
        addBankWithoutFantastique()
        addHorlaHomework(child)
        try context.save()

        let session = await make(child, generator: StubGenerator(candidates: [GenFixtures.candidate()]))
        let generatedKey = try #require(session.questions.first(where: \.isGenerated)?.questionKey)
        for index in session.questions.indices {
            #expect(session.answer(session.questions[index].answerIndex) == true)
            if index < session.questions.count - 1 { session.advance() }
        }
        clock.now = QuizClock.now.addingTimeInterval(120)
        session.advance()

        #expect(session.phase == .finished)
        #expect(session.result?.correctCount == QuizSession.questionCount)
        let attempt = try #require(try context.fetch(FetchDescriptor<QuizAttempt>()).first)
        #expect(attempt.questionKeys.contains(generatedKey))
        #expect(attempt.correctCount == QuizSession.questionCount)
    }
}
