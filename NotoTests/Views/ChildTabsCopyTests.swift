import Testing
import Foundation
@testable import Noto

// Child app tabs (Aujourd'hui, Réviser, Parcours, Moi): the pure copy and
// layout helpers. No SwiftData, no network.

private let paris = QuizClock.calendar

private func slot(_ origin: QuizPlanSlot.Origin) -> QuizPlanSlot {
    QuizPlanSlot(origin: origin, subject: "Histoire", theme: nil, keywords: [], homeworkKey: nil, notionKey: nil)
}

private func homework(_ subject: String, day: Int, done: Bool = false) -> HomeworkSnapshot {
    HomeworkSnapshot(subject: subject, descriptionText: "Exercices \(subject) J+\(day)",
                     dueDate: QuizClock.date(day: day, hour: 8), done: done, calendar: paris)
}

@MainActor
@Suite("Aujourd'hui")
struct ChildTodayCopyTests {
    @Test func examPitchPromisesTheBonusOnlyWhenOn() {
        #expect(ChildTodayView.examPitch(bonus: 5) == "Un petit quiz ce soir pour t'échauffer ? +5 min de bonus.")
        #expect(ChildTodayView.examPitch(bonus: nil) == "Un petit quiz ce soir pour t'échauffer ?")
    }

    @Test func examBonusFollowsTheParentRules() {
        #expect(ChildHomeView.examBonusMinutes(RewardConfig(examEveBonus: 5, examEveBonusEnabled: true)) == 5)
        #expect(ChildHomeView.examBonusMinutes(RewardConfig(examEveBonus: 5, examEveBonusEnabled: false)) == nil)
        #expect(ChildHomeView.examBonusMinutes(RewardConfig(examEveBonus: 0, examEveBonusEnabled: true)) == nil)
    }

    @Test func classLockIsSaidOnlyWhileClassesAreOn() {
        let end = QuizClock.date(day: 0, hour: 16, minute: 30)
        #expect(ChildTodayView.classLockText(lastLessonEnd: end, now: QuizClock.date(day: 0, hour: 10))?
            .hasPrefix("Pendant les cours, tes applis sont en pause jusqu'à") == true)
        #expect(ChildTodayView.classLockText(lastLessonEnd: end, now: QuizClock.date(day: 0, hour: 17)) == nil)
        #expect(ChildTodayView.classLockText(lastLessonEnd: nil, now: QuizClock.date(day: 0, hour: 10)) == nil)
    }

    @Test func homeworkGoesUnderTheFirstLessonOfItsSubject() {
        let now = QuizClock.date(day: 0, hour: 9)
        let lines = ChildTodayView.homeworkLines(
            lessonSubjects: ["MATHEMATIQUES", "Histoire", "Mathématiques", "Anglais"],
            homework: [homework("Mathématiques", day: 3), homework("Mathématiques", day: 1),
                       homework("Histoire", day: 0), homework("Anglais", day: 1, done: true)],
            now: now, calendar: paris)
        #expect(lines.count == 4)
        // Soonest one still to do, folded subject match.
        #expect(lines[0]?.dueDate == QuizClock.date(day: 1, hour: 8))
        // Due today: already handed in, not tonight's work.
        #expect(lines[1] == nil)
        // Second maths lesson: said once only.
        #expect(lines[2] == nil)
        // Done.
        #expect(lines[3] == nil)
    }

    @Test func dueLabelSaysTomorrowOrTheWeekday() {
        let now = QuizClock.date(day: 0, hour: 9)
        #expect(ChildTodayView.homeworkDueLabel(QuizClock.date(day: 1, hour: 8), now: now, calendar: paris)
            == "Pour demain")
        #expect(ChildTodayView.homeworkDueLabel(QuizClock.date(day: 3, hour: 8), now: now, calendar: paris)
            .hasPrefix("Pour "))
    }

    @Test func dateLineIsCapitalised() {
        let line = ChildTodayView.dateLine(QuizClock.date(day: 0, hour: 12))
        #expect(line.first?.isUppercase == true)
    }
}

@MainActor
@Suite("Réviser")
struct ChildReviseCopyTests {
    @Test func compositionFollowsThePlan() {
        let plan = QuizPlan(slots: [slot(.homeworkTomorrow), slot(.homeworkTomorrow), slot(.dueNotion),
                                    slot(.dueNotion), slot(.programme)], isEligible: true)
        #expect(ChildReviseView.compositionLines(plan).map(\.text)
            == ["2 sur tes devoirs de demain", "2 notions à revoir", "1 sur ton programme"])
    }

    @Test func compositionSaysUpcomingWhenNotAllForTomorrow() {
        let plan = QuizPlan(slots: [slot(.homeworkTomorrow), slot(.homeworkLater), slot(.dueNotion)],
                            isEligible: true)
        #expect(ChildReviseView.compositionLines(plan).map(\.text)
            == ["2 sur tes devoirs à venir", "1 notion à revoir"])
    }

    @Test func emptyPlanHasNoLine() {
        #expect(ChildReviseView.compositionLines(QuizPlan(slots: [], isEligible: true)).isEmpty)
    }
}

@MainActor
@Suite("Moi")
struct ChildMeCopyTests {
    @Test func monthStartsOnMonday() {
        // 1 October 2026 is a Thursday: three empty cells first.
        let today = CalendarDay(year: 2026, month: 10, day: 19)
        let played: Set<CalendarDay> = [CalendarDay(year: 2026, month: 10, day: 18)]
        let jokers: Set<CalendarDay> = [CalendarDay(year: 2026, month: 10, day: 16)]
        let cells = ChildMeView.monthCells(today: today, played: played, jokers: jokers, calendar: paris)
        #expect(cells.prefix(3).allSatisfy { $0 == nil })
        #expect(cells.count == 3 + 31)
        #expect(cells[3]?.day.day == 1)
        #expect(cells[3 + 17]?.mark == .played)
        #expect(cells[3 + 15]?.mark == .joker)
        #expect(cells[3 + 18]?.isToday == true)
        #expect(cells[3 + 19]?.isFuture == true)
    }

    @Test func dayLabels() {
        let cell = ChildMeView.MonthCell(day: CalendarDay(year: 2026, month: 10, day: 16), mark: .joker,
                                         isToday: false, isFuture: false)
        #expect(ChildMeView.dayAccessibilityLabel(cell) == "Le 16 : sauvé par un joker")
    }
}

@MainActor
@Suite("Parcours et résultat")
struct ChildPathCopyTests {
    @Test func selectedSubjectWinsElseFirst() {
        let subjects = [SubjectProgress(subject: "Mathématiques", themes: []),
                        SubjectProgress(subject: "Histoire", themes: [])]
        #expect(SubjectPathView.resolvedSubject("HISTOIRE", subjects: subjects, position: .empty)?.subject
            == "Histoire")
        #expect(SubjectPathView.resolvedSubject(nil, subjects: subjects, position: .empty)?.subject
            == "Mathématiques")
        #expect(SubjectPathView.resolvedSubject("Anglais", subjects: subjects, position: .empty)?.subject
            == "Mathématiques")
    }

    @Test func scoreIsASubtitle() {
        let result = QuizSessionResult(correctCount: 4, totalCount: 5, durationSec: 90,
                                       decision: RewardDecision(base: 10, bonus: 0, denial: nil,
                                                                countsAsSuccess: true),
                                       requiredCorrect: 4)
        #expect(QuizResultView.scoreLine(for: result) == "4 bonnes réponses sur 5")
        let one = QuizSessionResult(correctCount: 1, totalCount: 5, durationSec: 90,
                                    decision: .denied(.belowThreshold), requiredCorrect: 4)
        #expect(QuizResultView.scoreLine(for: one) == "1 bonne réponse sur 5")
    }
}

@MainActor
@Suite("Vision enfant")
struct ChildPreviewCopyTests {
    @Test func bannerAddressesTheParent() {
        #expect(ChildPreviewBanner.title("Joseph") == "Vision enfant : l'appli de Joseph")
        #expect(ChildPreviewBanner.entryTitle("Joseph") == "Voir l'appli de Joseph")
        // Parent tone: no tutoiement in the parent's bar and alert.
        for text in [ChildPreviewBanner.detail("Joseph"), ChildPreviewBanner.actionMessage("Joseph"),
                     ChildPreviewBanner.classMissingDetail("Joseph")] {
            #expect(text.contains("Joseph"))
            #expect(!text.contains(" tu ") && !text.contains(" ton ") && !text.contains(" tes "))
        }
    }

    @Test func bannerSaysWhereTheProgressLives() {
        #expect(ChildPreviewBanner.detail("Joseph").contains("synchro famille"))
    }
}
