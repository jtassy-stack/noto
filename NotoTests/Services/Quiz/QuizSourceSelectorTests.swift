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

    @Test("period filter: current period, \"Année\" and undated themes only")
    func periodFilter() {
        let p = plan(maxSlots: 20, period: "Trimestre 2")
        #expect(Set(p.slots.compactMap(\.theme)) == [
            "Le récit fantastique", "Dire l'amour", "Théorème de Pythagore",
            "Calcul littéral et équations", "L'urbanisation du monde",
        ])
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
