import Testing
import Foundation
@testable import Noto

// Child « Mes cours » tab: the pure helpers in `ChildCourses` and the
// parent-controlled grades flag. No SwiftData, no network.

private let paris = QuizClock.calendar

private func grade(_ subject: String, _ value: Double, outOf: Double = 20, coefficient: Double = 1,
                   day: Int = 0, chapter: String? = nil) -> ChildCourses.GradeSnapshot {
    ChildCourses.GradeSnapshot(subject: subject, value: value, outOf: outOf, coefficient: coefficient,
                               date: QuizClock.date(day: day, hour: 10), chapter: chapter)
}

@Suite("Mes cours")
struct ChildCoursesTests {
    @Test func gradesSegmentFollowsTheParentSwitch() {
        #expect(ChildCourses.sections(gradesVisible: true) == [.homework, .schedule, .grades])
        #expect(ChildCourses.sections(gradesVisible: false) == [.homework, .schedule])
    }

    @Test func gradesAreVisibleUntilTheParentHidesThem() throws {
        let suite = "ChildCoursesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ChildGradesSettings.isVisible(defaults: defaults))
        ChildGradesSettings.setVisible(false, defaults: defaults)
        #expect(!ChildGradesSettings.isVisible(defaults: defaults))
        ChildGradesSettings.setVisible(true, defaults: defaults)
        #expect(ChildGradesSettings.isVisible(defaults: defaults))
    }

    @Test func homeworkIsGroupedByDueDayAndSkipsDoneAndPast() {
        let now = QuizClock.date(day: 0, hour: 9)
        let days = ChildCourses.homeworkDays([
            QuizClock.homework("Maths", "Ex. 3", day: 1),
            QuizClock.homework("Anglais", "Vocabulaire", day: 1),
            QuizClock.homework("Histoire", "Fiche", day: 3),
            QuizClock.homework("SVT", "Déjà fait", day: 1, done: true),
            QuizClock.homework("Français", "En retard", day: -1),
            QuizClock.homework("Physique", "Ce soir", day: 0, hour: 8),
        ], now: now, calendar: paris)

        #expect(Array(days.map(\.label).prefix(2)) == ["Pour aujourd'hui", "Pour demain"])
        #expect(days.count == 3)
        #expect(days[0].items.map(\.subject) == ["Physique"])
        #expect(days[1].items.map(\.subject) == ["Anglais", "Maths"])
        #expect(days[2].items.map(\.subject) == ["Histoire"])
    }

    @Test func dueLabelNamesTheWeekdayThenTheDate() {
        let now = QuizClock.date(day: 0, hour: 9)
        #expect(ChildCourses.dueLabel(QuizClock.date(day: 0, hour: 18), now: now, calendar: paris) == "Pour aujourd'hui")
        #expect(ChildCourses.dueLabel(QuizClock.date(day: 1), now: now, calendar: paris) == "Pour demain")
        let inThree = ChildCourses.dueLabel(QuizClock.date(day: 3), now: now, calendar: paris)
        #expect(inThree.hasPrefix("Pour ") && !inThree.contains(where: \.isNumber))
        let later = ChildCourses.dueLabel(QuizClock.date(day: 10), now: now, calendar: paris)
        #expect(later.hasPrefix("Pour ") && later.contains(where: \.isNumber))
    }

    @Test func scheduleDaysStartTodayAndAreCapped() {
        let now = QuizClock.date(day: 0, hour: 12)
        let starts = [-1, 0, 0, 1, 3, 4, 5, 6, 7, 8, 9].map { QuizClock.date(day: $0, hour: 8) }
        let days = ChildCourses.scheduleDays(lessonStarts: starts, now: now, calendar: paris)
        #expect(days.count == 7)
        #expect(days.first == paris.startOfDay(for: now))
        #expect(days == days.sorted())
        #expect(ChildCourses.dayChipLabel(days[0], now: now, calendar: paris) == "Aujourd'hui")
        #expect(ChildCourses.dayChipLabel(days[1], now: now, calendar: paris) == "Demain")
    }

    @Test func subjectAverageIsWeightedAndNormalisedTo20() throws {
        let subjects = ChildCourses.subjects([
            grade("Maths", 12, coefficient: 1, day: -3),
            grade("Maths", 8, outOf: 10, coefficient: 2, day: -1),
            grade("Anglais", 15),
            grade("Anglais", 5, outOf: 0),
        ])
        #expect(subjects.map(\.subject) == ["Anglais", "Maths"])
        let maths = try #require(subjects.last)
        // (12×1 + 16×2) / 3 = 14,67
        let average = try #require(maths.average)
        #expect(abs(average - 44.0 / 3) < 0.001)
        #expect(maths.grades.first?.value == 8)
        // A grade without a scale does not count.
        #expect(subjects.first?.average == 15)
    }

    @Test func gradeTextKeepsTheGradeScale() {
        #expect(ChildCourses.gradeText(grade("Maths", 14.5)) == "14,5/20")
        #expect(ChildCourses.gradeText(grade("Maths", 8, outOf: 10)) == "8/10")
        #expect(ChildCourses.coefficientText(1) == nil)
        #expect(ChildCourses.coefficientText(2) == "coef. 2")
        #expect(ChildCourses.coefficientText(0.5) == "coef. 0,5")
        #expect(ChildCourses.averageText(14.666) == "14,7")
    }
}
