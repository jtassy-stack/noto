import Testing
import Foundation
@testable import Noto

@Suite("ExamKeywordDetector")
struct ExamKeywordDetectorTests {

    private let now = QuizClock.now
    private let calendar = QuizClock.calendar

    private static func fixture(_ prefix: String) -> String {
        CurriculumHomeworkFixtures.labels.first { $0.text.contains(prefix) }!.text
    }

    // MARK: matches

    @Test("each keyword in the realistic homework fixtures", arguments: [
        fixture("Contrôle mardi"),
        fixture("Interrogation jeudi"),
        fixture("évaluation de vendredi"),
        fixture("DS vendredi"),
    ])
    func fixtureKeywords(text: String) {
        #expect(ExamKeywordDetector.matches(text))
    }

    @Test("case and accents are folded", arguments: [
        "CONTRÔLE de maths", "Évaluation sur le chapitre 3", "contrôle", "EVALUATION",
    ])
    func folding(text: String) {
        #expect(ExamKeywordDetector.matches(text))
    }

    @Test("\"ds\" matches as a whole word, optionally numbered", arguments: [
        ("Lire le dossier sur les fonds marins", false),
        ("dsl je n'ai pas fini", false),
        ("DS de physique jeudi", true),
        ("Réviser pour le DS.", true),
        ("DS2 de maths", true),
        ("DS1 vendredi", true),
        ("DS n°3", true),
        ("DSL", false),
    ])
    func dsWholeWord(text: String, expected: Bool) {
        #expect(ExamKeywordDetector.matches(text) == expected)
    }

    @Test("explicit forms of interro, contrôle and évaluation match", arguments: [
        "interro demain", "Deux interros cette semaine", "INTERROGATION écrite", "Interrogations de la semaine",
        "Contrôles de fin de trimestre", "Deux évaluations cette semaine",
    ])
    func explicitForms(text: String) {
        #expect(ExamKeywordDetector.matches(text))
    }

    @Test("verbs and self-assessment are not exams", arguments: [
        "Interroger le document p.45",
        "Contrôler vos résultats avec la calculatrice",
        "Auto-évaluation du chapitre 3",
        "Faire l'auto évaluation p.12",
        "Évaluer la fiabilité de la source",
    ])
    func falsePositives(text: String) {
        #expect(!ExamKeywordDetector.matches(text))
    }

    @Test("\"bac blanc\" is a phrase: \"bac\" alone does not match")
    func bacBlancPhrase() {
        #expect(ExamKeywordDetector.matches("Bac blanc de philosophie lundi"))
        #expect(ExamKeywordDetector.matches("Réviser pour le BAC-BLANC"))
        #expect(!ExamKeywordDetector.matches("Réviser le programme du bac"))
        #expect(!ExamKeywordDetector.matches("Un tableau blanc et le bac à sable"))
    }

    @Test("plain homework does not match", arguments: [
        "Exercices 12 à 15 p.67 sur les fractions", "Lire Le Horla de Maupassant", "",
    ])
    func noKeyword(text: String) {
        #expect(!ExamKeywordDetector.matches(text))
    }

    @Test("\"devoir surveillé\" is not a keyword yet (suggestion pending)")
    func devoirSurveilleNotYet() {
        #expect(!ExamKeywordDetector.keywords.contains(.phrase("devoir surveille")))
        #expect(!ExamKeywordDetector.matches("Devoir surveillé de mathématiques"))
    }

    // MARK: hasExamTomorrow

    private func hasExam(_ homework: [HomeworkSnapshot] = [], _ schedule: [ScheduleSnapshot] = []) -> Bool {
        ExamKeywordDetector.hasExamTomorrow(homework: homework, schedule: schedule, now: now, calendar: calendar)
    }

    private func lesson(day: Int, cancelled: Bool = false, isTest: Bool = true) -> ScheduleSnapshot {
        ScheduleSnapshot(subject: "MATHEMATIQUES", start: QuizClock.date(day: day, hour: 10),
                         end: QuizClock.date(day: day, hour: 11), cancelled: cancelled, isTest: isTest)
    }

    @Test("nothing planned → no exam")
    func empty() {
        #expect(!hasExam())
    }

    @Test("midnight-stamped due date tomorrow matches (less than 1 h away)")
    func midnightTomorrow() {
        #expect(hasExam([QuizClock.homework("MATHS", "Contrôle sur Thalès", day: 1)]))
    }

    @Test("23:59 today does not count as tomorrow")
    func lateToday() {
        #expect(!hasExam([QuizClock.homework("MATHS", "Contrôle sur Thalès", day: 0, hour: 23, minute: 59)]))
    }

    @Test("an exam in 2 days does not count")
    func dayAfterTomorrow() {
        #expect(!hasExam([QuizClock.homework("MATHS", "Contrôle sur Thalès", day: 2)]))
    }

    @Test("done homework is ignored")
    func doneIgnored() {
        #expect(!hasExam([QuizClock.homework("MATHS", "Contrôle sur Thalès", day: 1, done: true)]))
    }

    @Test("homework tomorrow without a keyword does not count")
    func noKeywordTomorrow() {
        #expect(!hasExam([QuizClock.homework("MATHS", "Exercices 3 et 4 p.12", day: 1)]))
    }

    @Test("a test lesson tomorrow counts")
    func testLessonTomorrow() {
        #expect(hasExam([], [lesson(day: 1)]))
    }

    @Test("a cancelled, non-test or not-tomorrow lesson does not count")
    func lessonIgnored() {
        #expect(!hasExam([], [lesson(day: 1, cancelled: true), lesson(day: 1, isTest: false), lesson(day: 0), lesson(day: 2)]))
    }
}
