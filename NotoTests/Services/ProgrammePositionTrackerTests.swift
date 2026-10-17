import Testing
import Foundation
@testable import Noto

/// `ProgrammePositionTracker` (3.8): pure, offline, on the hand-written 4e
/// programme of `QuizCurriculumFixtures`. `QuizClock.now` is 2023-11-14.
@Suite("ProgrammePositionTracker")
struct ProgrammePositionTrackerTests {
    private let curriculum = QuizCurriculumFixtures.curriculum
    private let calendar = QuizClock.calendar

    private func lesson(_ subject: String, _ text: String, day: Int, title: String = "", themes: [String] = [],
                        source: LessonContentSource = .pronoteLesson) -> LessonContentSnapshot {
        LessonContentSnapshot(subject: subject, date: QuizClock.date(day: day, hour: 10), title: title, text: text,
                              themes: themes, source: source)
    }

    private func compute(level: String = "4e", lessons: [LessonContentSnapshot] = [],
                         homework: [HomeworkSnapshot] = [], now: Date = QuizClock.now) -> ProgrammePosition {
        ProgrammePositionTracker.compute(level: level, specialties: [], lessons: lessons, homework: homework,
                                         curriculum: curriculum, now: now, calendar: calendar)
    }

    private func key(_ subject: String, _ theme: String) -> String {
        NotionKey.make(level: "4e", subject: subject, theme: theme)
    }

    @Test("a single 3-point keyword gives no sighting")
    func belowThresholdKeywordIgnored() {
        let p = compute(lessons: [lesson("FRANCAIS", "Une comédie en un acte", day: -1)])
        #expect(!p.hasAny)
        #expect(p.unmatchedSubjects.isEmpty)
    }

    @Test("a theme-name hit gives a sighting")
    func themeNameHitAccepted() throws {
        let p = compute(lessons: [lesson("HISTOIRE", "Cours : la Révolution française", day: -2)])
        let histoire = try #require(p.position(forSubject: "Histoire"))
        #expect(histoire.current.map(\.theme) == ["La Révolution française"])
        #expect(histoire.current.first?.notionKey == key("Histoire", "La Révolution française"))
        #expect(p.eligibleKeys(forSubject: SubjectAlias.fold("Histoire")) == [key("Histoire", "La Révolution française")])
        #expect(p.eligibleKeys(forSubject: SubjectAlias.fold("Géographie")) == nil)
    }

    @Test("a Pronote teacher tag beats a higher keyword score elsewhere")
    func teacherTagWinsOverText() throws {
        // Text alone: « Le récit fantastique » (horla + maupassant + fantastique = 9).
        let tagged = lesson("FRANCAIS", "Le Horla de Maupassant, un récit fantastique", day: -1,
                            themes: ["Théâtre classique"])
        let p = compute(lessons: [tagged])
        let francais = try #require(p.position(forSubject: "Français"))
        #expect(francais.current.map(\.theme) == ["Molière et le théâtre classique"])
        #expect(francais.covered.isEmpty)
        #expect(ProgrammePositionTracker.tagMatches("Molière et le théâtre classique",
                                                    theme: "Molière et le théâtre classique"))
        #expect(!ProgrammePositionTracker.tagMatches("Le", theme: "Le récit fantastique"))
    }

    @Test("an older theme with more hits loses current to a recent one (14 d half-life)")
    func recencyPicksCurrent() throws {
        let old = [-40, -39].map { QuizClock.homework("FRANCAIS", "Lire Scapin, une comédie de Molière", day: $0) }
        let recent = QuizClock.homework("FRANCAIS", "Le Horla de Maupassant", day: -1)
        let p = compute(homework: old + [recent])
        let francais = try #require(p.position(forSubject: "Français"))
        #expect(francais.current.map(\.theme) == ["Le récit fantastique"])
        #expect(francais.covered.map(\.theme) == ["Molière et le théâtre classique"])
        #expect(francais.covered.first?.count == 2)
    }

    @Test("lesson evidence weighs more than homework")
    func lessonSourceOutweighsHomework() throws {
        let p = compute(lessons: [lesson("FRANCAIS", "Le Horla de Maupassant", day: 0)],
                        homework: [QuizClock.homework("FRANCAIS", "Scapin, comédie", day: 0)])
        let francais = try #require(p.position(forSubject: "Français"))
        let all = francais.current + francais.covered
        let fantastique = try #require(all.first { $0.theme == "Le récit fantastique" })
        let moliere = try #require(all.first { $0.theme == "Molière et le théâtre classique" })
        #expect(francais.current.first?.theme == "Le récit fantastique")
        #expect(abs(fantastique.weight - 9) < 1e-9)   // 6 × 1.5
        #expect(abs(moliere.weight - 6) < 1e-9)
    }

    @Test("homework due in 5 days counts as today; one due in 30 days is ignored")
    func futureHomeworkCountsAsCurrent() throws {
        let p = compute(homework: [
            QuizClock.homework("MATHEMATIQUES", "Pythagore : calculer l'hypoténuse", day: 5),
            QuizClock.homework("MATHEMATIQUES", "Résoudre une équation à une inconnue", day: 30),
        ])
        let maths = try #require(p.position(forSubject: "Mathématiques"))
        #expect(maths.current.map(\.theme) == ["Théorème de Pythagore"])
        #expect(maths.covered.isEmpty)
        #expect(abs((maths.current.first?.weight ?? 0) - 6) < 1e-9)
    }

    @Test("HISTOIRE-GEOGRAPHIE feeds both subjects; two close chapters are both current")
    func parallelChaptersTwoCurrent() throws {
        let p = compute(lessons: [
            lesson("HISTOIRE-GEOGRAPHIE", "La révolution de 1789", day: -1),
            lesson("HISTOIRE-GEOGRAPHIE", "L'urbanisation : une métropole", day: -1),
            lesson("FRANCAIS", "Scapin, comédie", day: -2),
            lesson("FRANCAIS", "Le Horla, Maupassant", day: -1),
        ])
        #expect(p.position(forSubject: "Histoire")?.current.map(\.theme) == ["La Révolution française"])
        #expect(p.position(forSubject: "Géographie")?.current.map(\.theme) == ["L'urbanisation du monde"])
        let francais = try #require(p.position(forSubject: "Français"))
        #expect(francais.current.map(\.theme) == ["Le récit fantastique", "Molière et le théâtre classique"])
        #expect(francais.covered.isEmpty)
    }

    @Test("a label matching no curriculum subject lands in unmatchedSubjects")
    func unknownSubjectListed() {
        let p = compute(lessons: [lesson("ARTS PLASTIQUES", "Perspective et point de fuite", day: -1)],
                        homework: [QuizClock.homework("ARTS PLASTIQUES", "Apporter un carnet", day: 1)])
        #expect(!p.hasAny)
        #expect(p.unmatchedSubjects == ["ARTS PLASTIQUES"])
    }

    @Test("primary level: empty")
    func primaryLevelEmpty() {
        let p = ProgrammePositionTracker.compute(
            level: "CM2", specialties: [], lessons: [lesson("FRANCAIS", "Lire des contes : un conte", day: -1)],
            homework: [], curriculum: curriculum, now: QuizClock.now, calendar: calendar)
        #expect(p == .empty)
    }

    @Test("confidence: low, medium, high, and the stale downgrade")
    func confidenceLevels() throws {
        let one = compute(homework: [QuizClock.homework("MATHS", "Pythagore et hypoténuse", day: -1)])
        #expect(one.position(forSubject: "Mathématiques")?.confidence == .low)

        let two = compute(homework: [
            QuizClock.homework("MATHS", "Pythagore et hypoténuse", day: -1),
            QuizClock.homework("MATHS", "Encore Pythagore : hypoténuse", day: -1),
        ])
        #expect(two.position(forSubject: "Mathématiques")?.confidence == .medium)

        let strong = [
            lesson("MATHS", "Théorème de Pythagore", day: -3),
            lesson("MATHS", "Pythagore : hypoténuse", day: -2),
            lesson("MATHS", "Pythagore, exercices sur l'hypoténuse", day: -2),
        ]
        #expect(compute(lessons: strong).position(forSubject: "Mathématiques")?.confidence == .high)

        // Same evidence 25 days earlier (holidays since): high → medium.
        let later = QuizClock.calendar.date(byAdding: .day, value: 25, to: QuizClock.now)!
        let stale = compute(lessons: strong, now: later)
        #expect(stale.position(forSubject: "Mathématiques")?.confidence == .medium)
        #expect(ProgrammePosition.Confidence.low < .medium && ProgrammePosition.Confidence.medium < .high)
    }

    @Test("homework also stored as a .homework row counts once")
    func homeworkDeduplicated() throws {
        let h = QuizClock.homework("MATHS", "Pythagore et hypoténuse", day: -1)
        let stored = LessonContentSnapshot(subject: h.subject, date: h.dueDate, title: "", text: h.descriptionText,
                                           themes: [], source: .homework)
        let p = compute(lessons: [stored], homework: [h])
        #expect(p.position(forSubject: "Mathématiques")?.current.first?.count == 1)
    }

    @Test("sightings sort the same way every run, whatever the input order")
    func deterministicOrdering() {
        let lessons = [
            lesson("FRANCAIS", "Scapin, comédie", day: -20),
            lesson("FRANCAIS", "Poème lyrique", day: -14),
            lesson("FRANCAIS", "Le Horla, Maupassant", day: -1),
            lesson("HISTOIRE-GEOGRAPHIE", "La révolution de 1789", day: -3),
        ]
        let a = compute(lessons: lessons)
        let b = compute(lessons: lessons.reversed())
        #expect(a == b)
        #expect(a.position(forSubject: "Français")?.covered.map(\.theme)
            == ["Dire l'amour", "Molière et le théâtre classique"])
        #expect(a.orderedSubjects.map(\.subject) == ["Français", "Histoire"])
    }
}
