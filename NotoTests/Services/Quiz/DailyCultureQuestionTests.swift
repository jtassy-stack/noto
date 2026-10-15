import Testing
import Foundation
@testable import Noto

/// Keskonfé lot fixtures (contract §6 shape). Not main-actor isolated, so
/// `@Test(arguments:)` can use them.
enum CultureLotFixtures {
    static let idA = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    static let idB = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!
    static let idC = UUID(uuidString: "cccccccc-0000-4000-8000-000000000003")!

    /// One `KoiQuizV2Dto` as JSON, every contract key present.
    static func quizJSON(id: UUID, domain: String = "livres", tone: String = "histoire",
                         validUntil: String? = nil, choices: [String] = ["Jules Verne", "Victor Hugo", "Zola", "Dumas"],
                         answerIndex: Int = 0) -> String {
        let choicesJSON = choices.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "id": "\(id.uuidString.lowercased())", "domain": "\(domain)", "difficulty": 2, "kind": "catalogue",
          "question": "Qui a écrit « Vingt mille lieues sous les mers » ?", "choices": [\(choicesJSON)],
          "answerIndex": \(answerIndex), "explanation": "Jules Verne, 1869.", "storyId": null,
          "oeuvreId": null, "oeuvreTitle": null, "genres": [], "imageUrl": null, "answerOeuvreId": null,
          "tone": "\(tone)", "horizon": null, "validUntil": \(validUntil.map { "\"\($0)\"" } ?? "null"),
          "promotedFrom": null
        }
        """
    }

    static func lotJSON(date: String = "2026-10-15", quizzes: [String]) -> String {
        """
        {"date": "\(date)", "number": 412, "citation": null, "quizzes": [\(quizzes.joined(separator: ","))]}
        """
    }

    static func quiz(_ id: UUID, domain: String = "livres", tone: String? = "histoire",
                     validUntil: String? = nil,
                     choices: [String] = ["A", "B", "C", "D"], answerIndex: Int = 0) -> CultureLotQuizDto {
        CultureLotQuizDto(id: id, domain: domain, question: "Question ?", choices: choices,
                          answerIndex: answerIndex, explanation: "Parce que.", tone: tone, validUntil: validUntil)
    }
}

/// Culture question of the day: `QuizAPIClient.cultureLot()` (GET only,
/// through `QuizStubProtocol`), tolerant decoding, deterministic pick, day
/// cache, offline / 404 → no card. Nested in `QuizBankSuites` because the
/// stub handler is static.
extension QuizBankSuites {
@MainActor
@Suite("Culture question of the day")
struct DailyCultureQuestionTests {

    private let calendar = QuizClock.calendar

    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suite = "DailyCultureQuestionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    // MARK: Client

    @Test("GET /api/quiz/v2/lot with app=keskonfe only: no level, date, location or child data")
    func request() async throws {
        QuizStubProtocol.install { _ in .json(CultureLotFixtures.lotJSON(quizzes: [CultureLotFixtures.quizJSON(id: CultureLotFixtures.idA)])) }
        defer { QuizStubProtocol.reset() }

        let lot = try await stubbedQuizClient().cultureLot()
        #expect(lot.date == "2026-10-15")
        #expect(lot.number == 412)
        #expect(lot.quizzes.count == 1)
        #expect(lot.quizzes[0].id == CultureLotFixtures.idA)
        #expect(lot.quizzes[0].tone == "histoire")
        #expect(lot.quizzes[0].explanation == "Jules Verne, 1869.")

        let request = try #require(QuizStubProtocol.requests.first)
        #expect(QuizStubProtocol.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/quiz/v2/lot")
        #expect(request.queryMap == ["app": "keskonfe"])
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "noto_test_key")
        #expect(request.value(forHTTPHeaderField: "x-device-id") == nil)
        #expect(request.httpBody == nil)
    }

    @Test("tolerant decoding: an unreadable quiz is dropped, never the lot")
    func tolerant() async throws {
        let broken = #"{"id": "not-a-uuid", "domain": "films", "question": "?", "choices": [], "answerIndex": 0}"#
        let minimal = """
        {"id": "\(CultureLotFixtures.idB.uuidString.lowercased())", "domain": "films", "question": "Q ?",
         "choices": ["a", "b", "c", "d"], "answerIndex": 1}
        """
        QuizStubProtocol.install { _ in .json(CultureLotFixtures.lotJSON(quizzes: [broken, minimal, CultureLotFixtures.quizJSON(id: CultureLotFixtures.idA)])) }
        defer { QuizStubProtocol.reset() }

        let lot = try await stubbedQuizClient().cultureLot()
        #expect(lot.quizzes.map(\.id) == [CultureLotFixtures.idB, CultureLotFixtures.idA])
        #expect(lot.quizzes[0].tone == nil)
        #expect(lot.quizzes[0].difficulty == 1)
        #expect(lot.quizzes[0].explanation == nil)
    }

    @Test("404 maps to notFound")
    func notFound() async throws {
        QuizStubProtocol.install { _ in .json(#"{"error":"no lot for this date"}"#, status: 404) }
        defer { QuizStubProtocol.reset() }
        let error = await quizError { _ = try await stubbedQuizClient().cultureLot() }
        guard case .notFound = error else {
            Issue.record("expected notFound, got \(String(describing: error))")
            return
        }
    }

    // MARK: Pick

    @Test("deterministic: same lot date → same question, independent of input order")
    func deterministic() {
        let quizzes = [CultureLotFixtures.quiz(CultureLotFixtures.idA), CultureLotFixtures.quiz(CultureLotFixtures.idB), CultureLotFixtures.quiz(CultureLotFixtures.idC)]
        let lot = CultureLotResponse(date: "2026-10-15", number: 1, quizzes: quizzes)
        let shuffled = CultureLotResponse(date: "2026-10-15", number: 1, quizzes: quizzes.reversed())
        let pick = DailyCultureQuestionPicker.pick(from: lot)
        #expect(pick != nil)
        #expect(pick == DailyCultureQuestionPicker.pick(from: shuffled))
        // Spread: over a month of dates every question comes up.
        let picked = Set((1...28).compactMap { day in
            DailyCultureQuestionPicker.pick(from: CultureLotResponse(
                date: String(format: "2026-11-%02d", day), number: 1, quizzes: quizzes))?.id
        })
        #expect(picked == [CultureLotFixtures.idA, CultureLotFixtures.idB, CultureLotFixtures.idC])
    }

    @Test("FNV-1a is stable (reference vectors)")
    func fnv() {
        #expect(DailyCultureQuestionPicker.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(DailyCultureQuestionPicker.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
    }

    @Test("only playable culture questions", arguments: [
        CultureLotFixtures.quiz(CultureLotFixtures.idA, domain: "politique"),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, domain: "sport"),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, choices: ["A", "B", "C"]),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, choices: ["A", "B", "C", " "]),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, choices: ["A", "a", "C", "D"]),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, answerIndex: 4),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, answerIndex: -1),
        CultureLotFixtures.quiz(CultureLotFixtures.idA, validUntil: "2026-10-14"),
    ])
    func unplayable(quiz: CultureLotQuizDto) {
        #expect(!DailyCultureQuestionPicker.isPlayable(quiz, on: "2026-10-15"))
        #expect(DailyCultureQuestionPicker.pick(from: CultureLotResponse(date: "2026-10-15", number: 1,
                                                                          quizzes: [quiz])) == nil)
    }

    @Test("still valid on its last day; every Keskonfé domain accepted")
    func playable() {
        #expect(DailyCultureQuestionPicker.isPlayable(CultureLotFixtures.quiz(CultureLotFixtures.idA, validUntil: "2026-10-15"), on: "2026-10-15"))
        for domain in DailyCultureQuestionPicker.cultureDomains {
            #expect(DailyCultureQuestionPicker.isPlayable(CultureLotFixtures.quiz(CultureLotFixtures.idA, domain: domain), on: "2026-10-15"))
        }
    }

    @Test("evergreen tones first; an actu question only when nothing else is left")
    func tones() {
        let actu = CultureLotFixtures.quiz(CultureLotFixtures.idA, tone: "actu")
        let lot = CultureLotResponse(date: "2026-10-15", number: 1,
                                     quizzes: [actu, CultureLotFixtures.quiz(CultureLotFixtures.idB, tone: "fun"), CultureLotFixtures.quiz(CultureLotFixtures.idC, tone: nil)])
        for day in 1...20 {
            let picked = DailyCultureQuestionPicker.pick(from: CultureLotResponse(
                date: String(format: "2026-10-%02d", day), number: 1, quizzes: lot.quizzes))
            #expect(picked?.id != CultureLotFixtures.idA)
        }
        let onlyActu = CultureLotResponse(date: "2026-10-15", number: 1, quizzes: [actu])
        #expect(DailyCultureQuestionPicker.pick(from: onlyActu)?.id == CultureLotFixtures.idA)
        #expect(DailyCultureQuestionPicker.pick(from: CultureLotResponse(date: "2026-10-15", number: 1,
                                                                          quizzes: [])) == nil)
    }

    // MARK: Store

    @Test("fetched once a day, then served from the cache; a new day fetches again")
    func cache() async throws {
        try await withDefaults { defaults in
            QuizStubProtocol.install { _ in .json(CultureLotFixtures.lotJSON(quizzes: [CultureLotFixtures.quizJSON(id: CultureLotFixtures.idA)])) }
            defer { QuizStubProtocol.reset() }
            let store = DailyCultureQuestionStore(defaults: defaults)
            let client = stubbedQuizClient()

            let first = try #require(await store.questionOfTheDay(client: client, now: QuizClock.now,
                                                                 calendar: calendar))
            #expect(first.quiz.id == CultureLotFixtures.idA)
            #expect(first.dayKey == CalendarDay(QuizClock.now, calendar: calendar).key)
            #expect(first.lotDate == "2026-10-15")
            #expect(!first.isAnswered)

            // Same day, later: cache, no request; also from a fresh store
            // (relaunch).
            let later = QuizClock.date(day: 0, hour: 23, minute: 50)
            #expect(await store.questionOfTheDay(client: client, now: later, calendar: calendar) == first)
            #expect(await DailyCultureQuestionStore(defaults: defaults)
                .questionOfTheDay(client: client, now: later, calendar: calendar) == first)
            #expect(QuizStubProtocol.requests.count == 1)

            // Tomorrow: stale cache ignored, one more GET.
            let tomorrow = QuizClock.date(day: 1, hour: 8)
            #expect(store.cached(now: tomorrow, calendar: calendar) == nil)
            let next = await store.questionOfTheDay(client: client, now: tomorrow, calendar: calendar)
            #expect(next?.dayKey == CalendarDay(tomorrow, calendar: calendar).key)
            #expect(QuizStubProtocol.requests.count == 2)
        }
    }

    @Test("offline, 404, 401 or nothing playable: no card, nothing cached", arguments: [
        QuizStubProtocol.Stub.offline(),
        .json(#"{"error":"no lot for this date"}"#, status: 404),
        .json(#"{"error":"unauthorized"}"#, status: 401),
        .json("not json"),
        .json(CultureLotFixtures.lotJSON(quizzes: [CultureLotFixtures.quizJSON(id: CultureLotFixtures.idA,
                                                                               domain: "politique")])),
    ])
    func unavailable(stub: QuizStubProtocol.Stub) async throws {
        try await withDefaults { defaults in
            QuizStubProtocol.install { _ in stub }
            defer { QuizStubProtocol.reset() }
            let store = DailyCultureQuestionStore(defaults: defaults)
            #expect(await store.questionOfTheDay(client: stubbedQuizClient(), now: QuizClock.now,
                                                 calendar: calendar) == nil)
            #expect(store.cached(now: QuizClock.now, calendar: calendar) == nil)
        }
    }

    @Test("the first answer is kept (feedback survives a relaunch); later taps are ignored")
    func answer() async throws {
        try await withDefaults { defaults in
            let store = DailyCultureQuestionStore(defaults: defaults)
            // Nothing cached: ignored.
            #expect(store.recordAnswer(0, now: QuizClock.now, calendar: calendar) == nil)

            store.save(DailyCultureQuestion(dayKey: CalendarDay(QuizClock.now, calendar: calendar).key,
                                            lotDate: "2026-10-15", quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA, answerIndex: 2)))
            #expect(store.recordAnswer(7, now: QuizClock.now, calendar: calendar) == nil)
            let answered = try #require(store.recordAnswer(1, now: QuizClock.now, calendar: calendar))
            #expect(answered.answeredIndex == 1)
            #expect(!answered.answeredCorrectly)
            #expect(store.recordAnswer(2, now: QuizClock.now, calendar: calendar) == nil)
            #expect(DailyCultureQuestionStore(defaults: defaults)
                .cached(now: QuizClock.now, calendar: calendar)?.answeredIndex == 1)
            // A stale day cannot be answered.
            #expect(store.recordAnswer(1, now: QuizClock.date(day: 1, hour: 9), calendar: calendar) == nil)
        }
    }

    // MARK: Card copy

    @Test("card state and copy (tutoiement, no reward promise)")
    func copy() {
        var question = DailyCultureQuestion(dayKey: "2026-10-15", lotDate: "2026-10-15",
                                            quiz: CultureLotFixtures.quiz(CultureLotFixtures.idA, choices: ["Verne", "Hugo", "Zola", "Dumas"],
                                                            answerIndex: 0))
        #expect(CultureQuestionCard.choiceState(index: 0, question: question) == .neutral)
        question.answeredIndex = 2
        #expect(CultureQuestionCard.choiceState(index: 0, question: question) == .right)
        #expect(CultureQuestionCard.choiceState(index: 2, question: question) == .wrong)
        #expect(CultureQuestionCard.choiceState(index: 1, question: question) == .neutral)
        #expect(CultureQuestionCard.feedbackTitle(for: question) == "Pas tout à fait : la bonne réponse était « Verne ».")
        question.answeredIndex = 0
        #expect(CultureQuestionCard.feedbackTitle(for: question) == "Bonne réponse, bravo !")
        for state in [CultureQuestionCard.ChoiceState.neutral, .right, .wrong] {
            let text = CultureQuestionCard.accessibilityValue(state).lowercased()
            #expect(!text.contains("vous"))
            #expect(!text.contains("min"))
        }
    }
}
}

@Suite("CultureQuestionSettings")
struct CultureQuestionSettingsTests {
    @Test("off by default, parent can opt in")
    func defaultOff() throws {
        let suite = "culture.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CultureQuestionSettings.isEnabled(defaults: defaults) == false)
        CultureQuestionSettings.setEnabled(true, defaults: defaults)
        #expect(CultureQuestionSettings.isEnabled(defaults: defaults))
    }
}
