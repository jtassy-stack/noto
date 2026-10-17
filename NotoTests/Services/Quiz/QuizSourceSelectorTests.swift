import Testing
import Foundation
@testable import Noto

@Suite("QuizSourceSelector")
struct QuizSourceSelectorTests {

    private let now = QuizClock.now
    private let calendar = QuizClock.calendar
    private let curriculum = QuizCurriculumFixtures.curriculum

    private func context(_ level: String = "4e", specialties: [String] = [], weak: [String] = []) -> ChildRevisionContext {
        ChildRevisionContext(level: level, specialties: specialties, weakSubjects: weak)
    }

    private func plan(_ context: ChildRevisionContext? = nil, homework: [HomeworkSnapshot] = [],
                      masteries: [MasterySnapshot] = [], maxSlots: Int = 5,
                      period: String? = "Trimestre 1") -> QuizPlan {
        QuizSourceSelector.plan(context: context ?? self.context(), homework: homework, masteries: masteries,
                                curriculum: curriculum, now: now, calendar: calendar,
                                maxSlots: maxSlots, currentPeriod: period)
    }

    private func key(_ subject: String, _ theme: String, level: String = "4e") -> String {
        NotionKey.make(level: level, subject: subject, theme: theme)
    }

    private func mastery(_ key: String, box: Int = 1, day: Int = 0) -> MasterySnapshot {
        MasterySnapshot(notionKey: key, leitnerBox: box, nextReview: QuizClock.date(day: day), streakCorrect: 0)
    }

    private let scapin = QuizClock.homework("FRANCAIS", "Lire Les Fourberies de Scapin acte II", day: 1)
    private let pythagore = QuizClock.homework("MATHEMATIQUES", "Exercices sur le théorème de Pythagore", day: 0, hour: 8)
    private let revolution = QuizClock.homework("HISTOIRE-GEOGRAPHIE", "Apprendre la leçon sur la Révolution française", day: 2)

    // MARK: 1. Gate

    @Test("primary level is ineligible")
    func primaryIneligible() {
        #expect(plan(context("CM2")) == QuizPlan(slots: [], isEligible: false))
    }

    @Test("unknown level is ineligible", arguments: ["", "?", "Petite section"])
    func unknownIneligible(level: String) {
        #expect(!plan(context(level)).isEligible)
    }

    @Test("raw class label canonicalises (TG2 → Tle) and is eligible")
    func rawLabelEligible() {
        #expect(plan(context("TG2")).isEligible)
    }

    // MARK: 2–4. Homework

    @Test("no homework, no notion → programme only")
    func programmeOnly() {
        let p = plan()
        #expect(p.isEligible)
        #expect(!p.slots.isEmpty)
        #expect(p.slots.allSatisfy { $0.origin == .programme })
    }

    @Test("tomorrow before today before later")
    func homeworkOrder() {
        let p = plan(homework: [revolution, pythagore, scapin])
        #expect(p.slots.prefix(3).map(\.origin) == [.homeworkTomorrow, .homeworkToday, .homeworkLater])
        #expect(p.slots.prefix(3).map(\.theme) == [
            "Molière et le théâtre classique", "Théorème de Pythagore", "La Révolution française",
        ])
        #expect(p.slots[0].homeworkKey == scapin.dedupKey)
        #expect(p.slots[0].subject == "Français")
        #expect(p.slots[0].keywords == ["molière", "scapin", "comédie"])
        #expect(p.slots[0].notionKey == key("Français", "Molière et le théâtre classique"))
    }

    @Test("same day: earlier due date first, then dedupKey")
    func sameDayOrder() {
        let late = QuizClock.homework("MATHS", "Exercices sur une équation", day: 1, hour: 17)
        let early = QuizClock.homework("MATHS", "Pythagore", day: 1, hour: 8)
        let a = QuizClock.homework("FRANCAIS", "Le Horla", day: 1, hour: 8)
        let p = plan(homework: [late, a, early])
        let tied = [a, early].sorted { $0.dedupKey < $1.dedupKey }.map(\.dedupKey)
        #expect(p.slots.prefix(3).map(\.homeworkKey) == tied + [late.dedupKey])
    }

    @Test("done homework is excluded")
    func doneExcluded() {
        let done = QuizClock.homework("FRANCAIS", "Lire Scapin", day: 1, done: true)
        #expect(plan(homework: [done]).slots.allSatisfy { $0.homeworkKey == nil })
    }

    @Test("due in 3 days or yesterday excluded, in 2 days included")
    func window() {
        let in3 = QuizClock.homework("FRANCAIS", "Lire Scapin", day: 3)
        let yesterday = QuizClock.homework("FRANCAIS", "Lire Scapin", day: -1, hour: 20)
        let in2 = QuizClock.homework("FRANCAIS", "Lire Scapin", day: 2, hour: 23, minute: 59)
        let p = plan(homework: [in3, yesterday, in2])
        #expect(p.slots.compactMap(\.homeworkKey) == [in2.dedupKey])
        #expect(p.slots[0].origin == .homeworkLater)
    }

    @Test("identical rows are deduplicated")
    func dedup() {
        let twin = QuizClock.homework("FRANCAIS", "Lire Les Fourberies de Scapin acte II", day: 1, hour: 8)
        let p = plan(homework: [scapin, twin, scapin])
        #expect(p.slots.filter { $0.homeworkKey != nil }.count == 1)
        #expect(p.slots[0].homeworkKey == scapin.dedupKey)
    }

    @Test("alias HISTOIRE-GEOGRAPHIE resolves to the owning subject")
    func aliasResolves() {
        let geo = QuizClock.homework("HISTOIRE-GEOGRAPHIE", "Étude de cas : une métropole et son urbanisation", day: 1)
        let p = plan(homework: [revolution, geo])
        #expect(p.slots[0].subject == "Géographie")
        #expect(p.slots[0].theme == "L'urbanisation du monde")
        #expect(p.slots[1].subject == "Histoire")
        #expect(p.slots[1].theme == "La Révolution française")
    }

    @Test("no theme match → slot kept with a nil theme", arguments: [
        ("MATHEMATIQUES", "Mathématiques"),           // single alias → canonical name
        ("HISTOIRE-GEOGRAPHIE", "HISTOIRE-GEOGRAPHIE"), // several aliases → raw label
        ("LATIN", "LATIN"),                            // unknown subject
    ])
    func noThemeMatch(label: String, subject: String) {
        let h = QuizClock.homework(label, "Faire la fiche 4", day: 1)
        let slot = plan(homework: [h]).slots[0]
        #expect(slot.origin == .homeworkTomorrow)
        #expect(slot.subject == subject)
        #expect(slot.theme == nil)
        #expect(slot.keywords.isEmpty)
        #expect(slot.notionKey == nil)
        #expect(slot.homeworkKey == h.dedupKey)
    }

    // MARK: 5. Due notions

    @Test("due notions come after homework, lowest box then oldest then key")
    func dueNotionsOrder() {
        let pyth = key("Mathématiques", "Théorème de Pythagore")
        let horla = key("Français", "Le récit fantastique")
        let urba = key("Géographie", "L'urbanisation du monde")
        let calc = key("Mathématiques", "Calcul littéral et équations")
        let masteries = [
            mastery(pyth, box: 3, day: -1),
            mastery(horla, box: 1, day: 0),
            mastery(urba, box: 1, day: -4),
            mastery(calc, box: 3, day: -1),
        ]
        let p = plan(homework: [scapin], masteries: masteries, maxSlots: 10)
        #expect(p.slots[0].origin == .homeworkTomorrow)
        let due = p.slots.filter { $0.origin == .dueNotion }
        #expect(due.map(\.notionKey) == [urba, horla] + [calc, pyth].sorted())
        #expect(due[0].subject == "Géographie")
        #expect(due[0].theme == "L'urbanisation du monde")
        #expect(due[0].keywords == ["urbanisation", "métropole"])
        #expect(due[0].homeworkKey == nil)
    }

    @Test("a notion not yet due is skipped")
    func notDueSkipped() {
        let pyth = key("Mathématiques", "Théorème de Pythagore")
        let p = plan(masteries: [mastery(pyth, box: 2, day: 1)], maxSlots: 20)
        #expect(!p.slots.contains { $0.origin == .dueNotion })
        #expect(!p.slots.contains { $0.notionKey == pyth })   // known, so not re-offered as new material
    }

    @Test("a notion already covered by a homework slot is skipped")
    func coveredNotionSkipped() {
        let moliere = key("Français", "Molière et le théâtre classique")
        let p = plan(homework: [scapin], masteries: [mastery(moliere)], maxSlots: 20)
        #expect(p.slots.filter { $0.notionKey == moliere }.map(\.origin) == [.homeworkTomorrow])
    }

    @Test("a due notion outside the programme keeps the parts of its key")
    func dueNotionOutsideProgramme() {
        let p = plan(masteries: [mastery("3e|latin|les dieux romains"), mastery("orphan")], maxSlots: 20)
        let due = p.slots.filter { $0.origin == .dueNotion }
        #expect(due.map(\.subject) == ["latin", "orphan"])
        #expect(due.map(\.theme) == ["les dieux romains", nil])
        #expect(due.allSatisfy { $0.keywords.isEmpty })
    }

    // MARK: 6. Programme fill

    @Test("weak subject first in programme fill, then round-robin in curriculum order")
    func weakSubjectFirst() {
        let p = plan(context(weak: ["MATHEMATIQUES"]), maxSlots: 20, period: nil)
        #expect(p.slots.map(\.subject) == [
            "Mathématiques", "Français", "Histoire", "Géographie",
            "Mathématiques", "Français", "Français",
        ])
        #expect(p.slots.allSatisfy { $0.origin == .programme && $0.homeworkKey == nil && $0.notionKey != nil })
    }

    @Test("several weak subjects keep their own order")
    func weakSubjectsOrder() {
        let p = plan(context(weak: ["Géographie", "HISTOIRE-GEOGRAPHIE", "MATHS"]), maxSlots: 4, period: nil)
        #expect(p.slots.map(\.subject) == ["Géographie", "Histoire", "Mathématiques", "Français"])
    }

    @Test("period filter (3.8 PeriodRank): current period, earlier ones, \"Année\" and undated themes")
    func periodFilter() {
        let p = plan(maxSlots: 20, period: "Trimestre 1")
        #expect(Set(p.slots.compactMap(\.theme)) == [
            "Molière et le théâtre classique", "Dire l'amour", "Théorème de Pythagore",
            "La Révolution française", "L'urbanisation du monde",
        ])
        // In T2 the T1 themes stay eligible (they were taught already).
        #expect(plan(maxSlots: 20, period: "Trimestre 2").slots.count == 7)
    }

    @Test("no current period: every theme is eligible")
    func noPeriod() {
        #expect(plan(maxSlots: 20, period: nil).slots.count == 7)
    }

    @Test("themes that already have a NotionMastery are skipped")
    func masteredSkipped() {
        let pyth = key("Mathématiques", "Théorème de Pythagore")
        let p = plan(masteries: [mastery(pyth, box: 4, day: 5)], maxSlots: 20, period: nil)
        #expect(p.slots.count == 6)
        #expect(!p.slots.contains { $0.theme == "Théorème de Pythagore" })
    }

    // MARK: 7. Size, spécialités, determinism

    @Test("maxSlots truncates", arguments: [0, 1, 2])
    func truncation(maxSlots: Int) {
        #expect(plan(homework: [scapin, pythagore, revolution], maxSlots: maxSlots).slots.count == maxSlots)
    }

    @Test("homework and notions beyond maxSlots are truncated, programme adds nothing")
    func truncationBeforeProgramme() {
        let p = plan(homework: [scapin, pythagore], masteries: [mastery(key("Géographie", "L'urbanisation du monde"))],
                     maxSlots: 2)
        #expect(p.slots.map(\.origin) == [.homeworkTomorrow, .homeworkToday])
    }

    @Test("specialties empty → every spécialité eligible; known → only those")
    func specialties() {
        let all = plan(context("1re"), maxSlots: 10, period: nil)
        #expect(all.slots.map(\.subject) == ["Français", "HGGSP", "SES"])
        let ses = plan(context("1re", specialties: ["SES"]), maxSlots: 10, period: nil)
        #expect(ses.slots.map(\.subject) == ["Français", "SES"])
    }

    @Test("deterministic: same input twice, and input order does not matter")
    func determinism() {
        let masteries = [mastery(key("Mathématiques", "Théorème de Pythagore")), mastery(key("Histoire", "La Révolution française"))]
        let a = plan(homework: [scapin, pythagore, revolution], masteries: masteries, maxSlots: 8)
        let b = plan(homework: [scapin, pythagore, revolution], masteries: masteries, maxSlots: 8)
        let c = plan(homework: [revolution, scapin, pythagore], masteries: masteries.reversed(), maxSlots: 8)
        #expect(a == b)
        #expect(a == c)
    }

    // MARK: bestTheme

    @Test("bestTheme returns the winning theme and its score")
    func bestTheme() throws {
        let hit = try #require(QuizSourceSelector.bestTheme(
            text: "Lire Les Fourberies de Scapin, une comédie de Molière", level: "4e", subject: "FRANCAIS",
            specialties: [], curriculum: curriculum))
        #expect(hit.theme == QuizCurriculumFixtures.francais4e.themes[0])
        #expect(hit.score == 9)
        let byName = QuizSourceSelector.bestTheme(text: "Révisions : Théorème de Pythagore", level: "4e",
                                                  subject: "MATHS", specialties: [], curriculum: curriculum)
        #expect(byName?.score == 13)
        #expect(QuizSourceSelector.bestTheme(text: "Fiche 4", level: "4e", subject: "FRANCAIS",
                                             specialties: [], curriculum: curriculum) == nil)
    }

    @Test("bundled curriculum.json: Scapin homework maps to its programme theme")
    func bundledCurriculum() throws {
        // Follows curriculum.json, not the plan's wording: the « Fourberies
        // de Scapin » keywords sit in 6e Français in the bundled file.
        let hit = try #require(QuizSourceSelector.bestTheme(
            text: "Lire Les Fourberies de Scapin acte II", level: "6e", subject: "FRANCAIS",
            specialties: [], curriculum: CurriculumSnapshot.bundled))
        #expect(hit.theme.keywords.contains("scapin"))
    }

    @Test("6e TECHNOLOGIE: the homework slot carries the owning subject and the programme notion key")
    func aliasToDifferentlyNamedSubject() throws {
        let bundled = CurriculumSnapshot.bundled
        let owner = "Sciences et technologie"
        let theme = "Matière, mouvement, énergie, information"
        let notion = NotionKey.make(level: "6e", subject: owner, theme: theme)
        let h = QuizClock.homework("TECHNOLOGIE", "Réviser le circuit électrique", day: 1)
        let p = QuizSourceSelector.plan(context: context("6e"), homework: [h], masteries: [mastery(notion)],
                                        curriculum: bundled, now: now, calendar: calendar,
                                        maxSlots: 50, currentPeriod: nil)
        let slot = try #require(p.slots.first)
        #expect(slot.origin == .homeworkTomorrow)
        #expect(slot.subject == owner)
        #expect(slot.theme == theme)
        #expect(slot.notionKey == notion)
        // Same key as the programme: neither re-offered as due notion nor as new material.
        #expect(p.slots.filter { $0.notionKey == notion }.count == 1)
        #expect(!p.slots.contains { $0.origin == .dueNotion })
    }

    @Test("bestTheme and matchKeywords share one scoring")
    func scoringShared() {
        let service = CurriculumService(programs: QuizCurriculumFixtures.programs)
        let text = "Lire Le Horla de Maupassant, un récit fantastique"
        let best = QuizSourceSelector.bestTheme(text: text, level: "4e", subject: "FRANCAIS",
                                                specialties: [], curriculum: curriculum)
        #expect(best?.theme.theme == "Le récit fantastique")
        #expect(Set(service.matchKeywords(text: text, level: "4e", subject: "FRANCAIS"))
                == Set(QuizCurriculumFixtures.francais4e.themes[1].keywords))
    }
}

// MARK: - Programme position (3.8)

@Suite("QuizSourceSelector — programme position")
struct QuizSourceSelectorPositionTests {
    private let now = QuizClock.now
    private let calendar = QuizClock.calendar
    private let curriculum = QuizCurriculumFixtures.curriculum

    private func key(_ subject: String, _ theme: String) -> String {
        NotionKey.make(level: "4e", subject: subject, theme: theme)
    }

    private func sighting(_ subject: String, _ theme: String, weight: Double, day: Int) -> ProgrammePosition.Sighting {
        let date = QuizClock.date(day: day, hour: 10)
        return .init(notionKey: key(subject, theme), subject: subject, theme: theme, firstSeen: date, lastSeen: date,
                     count: 1, weight: weight)
    }

    private func position(_ subject: String, current: [ProgrammePosition.Sighting],
                          covered: [ProgrammePosition.Sighting] = [],
                          confidence: ProgrammePosition.Confidence = .medium) -> ProgrammePosition {
        ProgrammePosition(subjects: [SubjectAlias.fold(subject): .init(
            subject: subject, current: current, covered: covered, confidence: confidence,
            lastEvidence: (current + covered).map(\.lastSeen).max() ?? now)], unmatchedSubjects: [])
    }

    private func plan(weak: [String] = [], homework: [HomeworkSnapshot] = [], masteries: [MasterySnapshot] = [],
                      maxSlots: Int = 20, period: String?, position: ProgrammePosition? = nil,
                      curriculum: CurriculumSnapshot? = nil) -> QuizPlan {
        let context = ChildRevisionContext(level: "4e", specialties: [], weakSubjects: weak)
        if let position {
            return QuizSourceSelector.plan(context: context, homework: homework, masteries: masteries,
                                           curriculum: curriculum ?? self.curriculum, now: now, calendar: calendar,
                                           maxSlots: maxSlots, currentPeriod: period, position: position)
        }
        return QuizSourceSelector.plan(context: context, homework: homework, masteries: masteries,
                                       curriculum: curriculum ?? self.curriculum, now: now, calendar: calendar,
                                       maxSlots: maxSlots, currentPeriod: period)
    }

    @Test("a subject with a position plans no theme outside current ∪ covered, even when the period allows it")
    func positionNeverPlansUnseenTheme() {
        let p = plan(period: "Trimestre 3",
                     position: position("Français", current: [sighting("Français", "Le récit fantastique",
                                                                        weight: 9, day: -1)]))
        let francais = p.slots.filter { $0.subject == "Français" }
        #expect(francais.map(\.theme) == ["Le récit fantastique"])
        // Subjects without a position keep the calendar fallback (all of them in T3).
        #expect(p.slots.contains { $0.theme == "Calcul littéral et équations" })
        #expect(p.slots.count == 5)   // 1 Français + 2 Maths + 1 Histoire + 1 Géographie
    }

    @Test("the current theme is planned first, then covered ones by lastSeen")
    func currentThemeFirst() {
        let pos = position("Français",
                           current: [sighting("Français", "Dire l'amour", weight: 8, day: -1)],
                           covered: [sighting("Français", "Molière et le théâtre classique", weight: 3, day: -20)])
        let p = plan(weak: ["FRANCAIS"], period: nil, position: pos)
        #expect(p.slots.first?.theme == "Dire l'amour")
        #expect(p.slots.filter { $0.subject == "Français" }.map(\.theme)
            == ["Dire l'amour", "Molière et le théâtre classique"])
        #expect(!p.slots.contains { $0.theme == "Le récit fantastique" })
    }

    @Test("a confident position puts its subject before others of equal weakness")
    func confidentSubjectFirst() {
        let pos = position("Géographie", current: [sighting("Géographie", "L'urbanisation du monde", weight: 6, day: -1)],
                           confidence: .high)
        let p = plan(maxSlots: 4, period: nil, position: pos)
        #expect(p.slots.map(\.subject) == ["Géographie", "Français", "Mathématiques", "Histoire"])
    }

    @Test("an empty position with no period plans exactly like before 3.8")
    func emptyPositionMatchesLegacy() {
        let homework = [
            QuizClock.homework("FRANCAIS", "Lire Les Fourberies de Scapin acte II", day: 1),
            QuizClock.homework("MATHEMATIQUES", "Exercices sur le théorème de Pythagore", day: 0, hour: 8),
            QuizClock.homework("HISTOIRE-GEOGRAPHIE", "Apprendre la leçon sur la Révolution française", day: 2),
        ]
        let legacy = plan(homework: homework, maxSlots: 5, period: nil)
        let empty = plan(homework: homework, maxSlots: 5, period: nil, position: .empty)
        #expect(legacy == empty)
        // Snapshot of the pre-3.8 plan for this fixture.
        #expect(empty.slots.map(\.origin) == [.homeworkTomorrow, .homeworkToday, .homeworkLater, .programme, .programme])
        #expect(empty.slots.map(\.theme) == [
            "Molière et le théâtre classique", "Théorème de Pythagore", "La Révolution française",
            "Le récit fantastique", "Calcul littéral et équations",
        ])
        let unweighted = plan(maxSlots: 20, period: nil, position: .empty)
        #expect(unweighted.slots.map(\.subject) == [
            "Français", "Mathématiques", "Histoire", "Géographie", "Français", "Mathématiques", "Français",
        ])
    }

    @Test("PeriodRank fallback: in T2, T1 and Année themes are eligible, T3 is not")
    func periodRankFallbackIncludesEarlierTrimesters() {
        let programme = CurriculumSnapshot(programs: [CurriculumProgram(level: "4e", cycle: 4, subjects: [
            CurriculumSubject(name: "Français", themes: [
                CurriculumTheme(theme: "Thème T1", keywords: [], period: "Trimestre 1"),
                CurriculumTheme(theme: "Thème T2", keywords: [], period: "Trimestre 2"),
                CurriculumTheme(theme: "Thème T3", keywords: [], period: "Trimestre 3"),
                CurriculumTheme(theme: "Thème annuel", keywords: [], period: "Année"),
                CurriculumTheme(theme: "Thème sans période", keywords: [], period: nil),
            ]),
        ])])
        let p = plan(period: "Trimestre 2", curriculum: programme)
        #expect(p.slots.compactMap(\.theme) == ["Thème T1", "Thème T2", "Thème annuel", "Thème sans période"])
        #expect(PeriodRank.isEligible("Trimestre 1", current: "Trimestre 2"))
        #expect(PeriodRank.isEligible("Année", current: "Trimestre 2"))
        #expect(PeriodRank.isEligible(nil, current: "Trimestre 1"))
        #expect(!PeriodRank.isEligible("Trimestre 3", current: "Trimestre 2"))
        #expect(PeriodRank.isEligible("Trimestre 3", current: nil))
    }

    @Test("Tle: « Semestre 2 » is not eligible in October")
    func tleSemesterRank() {
        let october = QuizClock.calendar.date(from: DateComponents(year: 2023, month: 10, day: 10, hour: 12))!
        let current = PeriodRank.currentPeriod(now: october, level: "Terminale", calendar: QuizClock.calendar)
        #expect(current == "Semestre 1")
        #expect(!PeriodRank.isEligible("Semestre 2", current: current))
        #expect(PeriodRank.isEligible("Semestre 1", current: current))
        #expect(PeriodRank.isEligible("Trimestre 1", current: current))
        #expect(PeriodRank.rank("Semestre 1") == 2 && PeriodRank.rank("Semestre 2") == 3)
        #expect(PeriodRank.rank("Année") == 0 && PeriodRank.rank(nil) == 0)
    }

    @Test("PeriodRank.currentPeriod boundaries (Europe/Paris)", arguments: [
        (2023, 12, 31, "4e", "Trimestre 1"),
        (2024, 1, 1, "4e", "Trimestre 2"),
        (2024, 3, 31, "4e", "Trimestre 2"),
        (2024, 4, 1, "4e", "Trimestre 3"),
        (2024, 8, 31, "4e", "Trimestre 3"),
        (2023, 9, 1, "4e", "Trimestre 1"),
        (2024, 1, 31, "Tle", "Semestre 1"),
        (2024, 2, 1, "Tle", "Semestre 2"),
    ])
    func currentPeriodBoundaries(year: Int, month: Int, day: Int, level: String, expected: String) {
        // 23:30 Paris: a UTC-based month would already / still be wrong.
        let date = QuizClock.calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                                hour: 23, minute: 30))!
        #expect(PeriodRank.currentPeriod(now: date, level: level, calendar: QuizClock.calendar) == expected)
    }

    @Test("programmeEligibility: seen themes only for a positioned subject, calendar otherwise")
    func eligibilityPredicate() {
        let pos = position("Français", current: [sighting("Français", "Le récit fantastique", weight: 9, day: -1)])
        let eligible = QuizSourceSelector.programmeEligibility(level: "4ème", position: pos,
                                                               currentPeriod: "Trimestre 1",
                                                               curriculum: curriculum, specialties: [])
        #expect(eligible("Français", "Le récit fantastique"))
        #expect(eligible("FRANCAIS", "le récit fantastique"))
        #expect(!eligible("Français", "Molière et le théâtre classique"))
        #expect(!eligible("Français", nil))
        #expect(!eligible("Français", "Un thème inconnu"))
        #expect(eligible("Mathématiques", "Théorème de Pythagore"))       // Année
        #expect(!eligible("Mathématiques", "Calcul littéral et équations")) // T2 in T1
        #expect(eligible("Mathématiques", nil))
        #expect(eligible("Arts plastiques", "Perspective"))               // unknown subject
    }
}

@Suite("HomeworkSnapshot dedupKey and NotionKey")
struct QuizSnapshotKeyTests {

    @Test("same subject, text and day → same key, whatever the time or case")
    func sameDay() {
        let a = QuizClock.homework("FRANCAIS", "Lire Scapin", day: 1)
        let b = QuizClock.homework("Français", "LIRE SCAPIN", day: 1, hour: 18)
        #expect(a.dedupKey == b.dedupKey)
        #expect(a.dedupKey.count == 64)
    }

    @Test("another day or text → another key")
    func differs() {
        let a = QuizClock.homework("FRANCAIS", "Lire Scapin", day: 1)
        #expect(a.dedupKey != QuizClock.homework("FRANCAIS", "Lire Scapin", day: 2).dedupKey)
        #expect(a.dedupKey != QuizClock.homework("FRANCAIS", "Lire le Cid", day: 1).dedupKey)
    }

    @Test("NotionKey folds and canonicalises the level")
    func notionKey() {
        #expect(NotionKey.make(level: "4ème", subject: "Français", theme: " Molière et le théâtre classique ")
                == "4e|francais|moliere et le theatre classique")
    }
}
