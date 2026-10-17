import Testing
import Foundation
@testable import Noto

/// Parent Accueil « Cette semaine » and the « Écran » tab: the pure figures
/// and copy (`ParentWeekReport`, `ScreenOverviewReport`).
@Suite("ParentWeekReport")
struct ParentWeekReportTests {
    private let paris = QuizClock.calendar
    private let now = QuizClock.date(day: 0, hour: 18)

    private func attempt(day: Int, minutes: Int = 10, total: Int = 5) -> AttemptSnapshot {
        AttemptSnapshot(date: QuizClock.date(day: day, hour: 17), questionKeys: [], correctCount: total,
                        totalCount: total, durationSec: 90, minutesEarned: minutes, passed: true,
                        bonusApplied: false, bonusMinutes: 0, itemSubjects: [], itemXP: [], denial: nil)
    }

    @Test func activityIsOldestFirstAndCapped() {
        let attempts = [attempt(day: 0), attempt(day: 0), attempt(day: 0), attempt(day: 0),
                        attempt(day: -1), attempt(day: -27), attempt(day: -28), attempt(day: -2, total: 0)]
        let levels = ParentWeekReport.activityLevels(attempts: attempts, now: now, calendar: paris)
        #expect(levels.count == 28)
        #expect(levels.last == 3)
        #expect(levels[26] == 1)
        #expect(levels[25] == 0)
        #expect(levels.first == 1)
        #expect(ParentWeekReport.revisedDays(attempts: attempts, now: now, calendar: paris) == 2)
    }

    @Test func notionBarsSkipUnplayedSubjects() {
        let subjects = [
            SubjectProgress(subject: "Histoire", themes: [ThemeProgress(theme: "A", box: 5),
                                                          ThemeProgress(theme: "B", box: 3),
                                                          ThemeProgress(theme: "C", box: 1),
                                                          ThemeProgress(theme: "D", box: 0)]),
            SubjectProgress(subject: "SVT", themes: [ThemeProgress(theme: "E", box: 0)]),
            SubjectProgress(subject: "Mathématiques", themes: [ThemeProgress(theme: "Fractions", box: 1),
                                                               ThemeProgress(theme: "G", box: 2)]),
        ]
        #expect(ParentWeekReport.notionBars(subjects) == [
            ParentWeekReport.NotionBar(subject: "Histoire", mastered: 1, inProgress: 1, fragile: 1),
            ParentWeekReport.NotionBar(subject: "Mathématiques", mastered: 0, inProgress: 0, fragile: 2),
        ])
        #expect(ParentWeekReport.weakestTheme(subjects)?.theme == "C")
    }

    @Test func averageHistoryIsWeightedAndStartsWithTheData() {
        let grades = [
            ParentWeekReport.GradePoint(value: 12, outOf: 20, coefficient: 1, date: QuizClock.date(day: -20, hour: 9)),
            ParentWeekReport.GradePoint(value: 8, outOf: 10, coefficient: 2, date: QuizClock.date(day: -1, hour: 9)),
        ]
        let history = ParentWeekReport.averageHistory(grades, now: now, calendar: paris)
        // The weeks before the first grade are left out: 3 points left.
        #expect(history.count == 3)
        #expect(history.first == 12)
        #expect(abs((history.last ?? 0) - (12 + 16 * 2) / 3) < 0.001)
        #expect(ParentWeekReport.averageTrendText(history) == "+2,7 en 2 semaines")
        #expect(ParentWeekReport.averageText(14.25) == "14,2" || ParentWeekReport.averageText(14.25) == "14,3")
    }

    @Test func synthesis() {
        #expect(ParentWeekReport.synthesis(firstName: "Joseph", revisedDays: 5, averageHistory: [13.6, 14.2],
                                           fragileSubject: "Mathématiques")
            == "Bonne semaine pour Joseph : 5 jours de révision et une moyenne en hausse. "
            + "Une notion en Mathématiques reste à surveiller.")
        #expect(ParentWeekReport.synthesis(firstName: "Léa", revisedDays: 1, averageHistory: [12, 12.1],
                                           fragileSubject: nil)
            == "Cette semaine pour Léa : 1 jour de révision.")
        #expect(ParentWeekReport.synthesis(firstName: "Léa", revisedDays: nil, averageHistory: [12],
                                           fragileSubject: nil) == nil)
    }

    @MainActor
    @Test func noRevisionCopyNamesTheChild() {
        #expect(ParentWeekSection.noRevisionText("Gaston")
            == "Les révisions de Gaston s'affichent sur l'appareil où Gaston fait ses quiz.")
    }
}

@Suite("ScreenOverviewReport")
struct ScreenOverviewReportTests {
    private let paris = QuizClock.calendar
    private let now = QuizClock.date(day: 0, hour: 12)

    private func attempt(day: Int, minutes: Int) -> AttemptSnapshot {
        AttemptSnapshot(date: QuizClock.date(day: day, hour: 11), questionKeys: [], correctCount: 5,
                        totalCount: 5, durationSec: 90, minutesEarned: minutes, passed: true,
                        bonusApplied: false, bonusMinutes: 0, itemSubjects: [], itemXP: [], denial: nil)
    }

    @Test func earnedPerDayCoversTheWeek() {
        let days = ScreenOverviewReport.earnedPerDay(
            attempts: [attempt(day: 0, minutes: 10), attempt(day: 0, minutes: 5), attempt(day: -3, minutes: 20),
                       attempt(day: -7, minutes: 30)],
            now: now, calendar: paris)
        #expect(days.count == 7)
        #expect(days.last?.minutes == 15)
        #expect(days[3].minutes == 20)
        #expect(days.map(\.minutes).reduce(0, +) == 35)
        #expect(ScreenOverviewReport.averageEarned(days) == 18)
        #expect(ScreenOverviewReport.averageEarned(days.map {
            ScreenOverviewReport.DayMinutes(date: $0.date, letter: $0.letter, minutes: 0)
        })
            == nil)
    }

    @Test func classSpanSkipsCancelledAndFinishedDays() {
        let lessons = [
            ScreenOverviewReport.Lesson(start: QuizClock.date(day: 0, hour: 8), end: QuizClock.date(day: 0, hour: 11),
                                        cancelled: false),
            ScreenOverviewReport.Lesson(start: QuizClock.date(day: 1, hour: 7), end: QuizClock.date(day: 1, hour: 9),
                                        cancelled: true),
            ScreenOverviewReport.Lesson(start: QuizClock.date(day: 1, hour: 8), end: QuizClock.date(day: 1, hour: 9),
                                        cancelled: false),
            ScreenOverviewReport.Lesson(start: QuizClock.date(day: 1, hour: 14),
                                        end: QuizClock.date(day: 1, hour: 16, minute: 30), cancelled: false),
        ]
        // Noon: today's classes are over, tomorrow's span.
        let span = ScreenOverviewReport.classSpan(lessons: lessons, now: now, calendar: paris)
        #expect(span?.startMinutes == 8 * 60)
        #expect(span?.endMinutes == 16 * 60 + 30)
        #expect(span.map { ScreenOverviewReport.dayLabel($0.day, now: now, calendar: paris) } == "Demain")
        #expect(ScreenOverviewReport.clockText(16 * 60 + 30) == "16 h 30")
        #expect(ScreenOverviewReport.clockText(8 * 60) == "8 h")
    }

    @Test func copy() {
        #expect(ScreenOverviewReport.tiersText([10, 5, 5]) == "10 · 5 · 5 min")
        #expect(ScreenOverviewReport.tiersText([0, 0, 0]) == "Aucune minute")
        #expect(ScreenOverviewReport.todayLine(earned: 12, cap: 20) == "12 min gagnées sur 20 possibles aujourd'hui")
        #expect(ScreenOverviewReport.todayLine(earned: 1, cap: 20) == "1 min gagnée sur 20 possibles aujourd'hui")
    }
}
