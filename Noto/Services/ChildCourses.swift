import Foundation

/// « Afficher les notes » in the child app (« Mes cours »): parent-controlled,
/// ON by default — the child already sees their grades on Pronote / the ENT.
/// Stored in the app group next to the other child feature flags
/// (`CultureQuestionSettings`, `FamilyChallengeSettings`) and edited from
/// Réglages › Révisions, behind the parent PIN on a child-mode device.
enum ChildGradesSettings {
    static let visibleKey = "noto_child_grades_visible"

    static func isVisible(defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) -> Bool {
        guard let defaults, defaults.object(forKey: visibleKey) != nil else { return true }
        return defaults.bool(forKey: visibleKey)
    }

    static func setVisible(_ visible: Bool,
                           defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) {
        defaults?.set(visible, forKey: visibleKey)
    }
}

/// Pure helpers of the child « Mes cours » tab (`ChildCoursesView`): homework
/// grouped by due day, school days ahead, per-subject averages. Works on
/// snapshots, so no SwiftData in tests. Copy addresses the child (tutoiement).
enum ChildCourses {
    /// The tab's segments; « Notes » only when the parent left grades visible.
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case homework, schedule, grades

        var id: String { rawValue }

        var title: String {
            switch self {
            case .homework: "Devoirs"
            case .schedule: "Emploi du temps"
            case .grades:   "Notes"
            }
        }
    }

    static func sections(gradesVisible: Bool) -> [Section] {
        gradesVisible ? Section.allCases : [.homework, .schedule]
    }

    // MARK: - Devoirs

    struct HomeworkDay: Equatable, Sendable {
        let day: Date
        let label: String
        let items: [HomeworkSnapshot]
    }

    /// Homework still to do, due today or later, grouped by due day (soonest
    /// first), subjects alphabetical within a day.
    static func homeworkDays(_ homework: [HomeworkSnapshot], now: Date, calendar: Calendar,
                             locale: Locale = Locale(identifier: "fr_FR")) -> [HomeworkDay] {
        let today = calendar.startOfDay(for: now)
        let pending = homework.filter { !$0.done && $0.dueDate >= today }
        let byDay = Dictionary(grouping: pending) { calendar.startOfDay(for: $0.dueDate) }
        return byDay.keys.sorted().map { day in
            HomeworkDay(
                day: day,
                label: dueLabel(day, now: now, calendar: calendar, locale: locale),
                items: byDay[day, default: []].sorted {
                    ($0.subject, $0.descriptionText) < ($1.subject, $1.descriptionText)
                }
            )
        }
    }

    /// « Pour aujourd'hui », « Pour demain », « Pour jeudi » within the week,
    /// else « Pour jeudi 30 octobre ».
    static func dueLabel(_ due: Date, now: Date, calendar: Calendar,
                         locale: Locale = Locale(identifier: "fr_FR")) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "Pour aujourd'hui"
        case 1: return "Pour demain"
        case 2...6:
            return "Pour " + due.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                           timeZone: calendar.timeZone).weekday(.wide))
        default:
            return "Pour " + due.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                           timeZone: calendar.timeZone)
                .weekday(.wide).day().month(.wide))
        }
    }

    // MARK: - Emploi du temps

    /// Start of each day from today on that has at least one lesson, the
    /// next `limit` of them.
    static func scheduleDays(lessonStarts: [Date], now: Date, calendar: Calendar, limit: Int = 7) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let days = Set(lessonStarts.map { calendar.startOfDay(for: $0) }.filter { $0 >= today })
        return Array(days.sorted().prefix(limit))
    }

    /// « Aujourd'hui », « Demain », else « lun. 20 ».
    static func dayChipLabel(_ day: Date, now: Date, calendar: Calendar,
                             locale: Locale = Locale(identifier: "fr_FR")) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Aujourd'hui" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: tomorrow) { return "Demain" }
        return day.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day())
    }

    // MARK: - Notes

    struct GradeSnapshot: Equatable, Sendable {
        let subject: String
        let value: Double
        let outOf: Double
        let coefficient: Double
        let date: Date
        let chapter: String?

        /// Normalised to /20, like `Grade.normalizedValue`.
        var normalized: Double { outOf > 0 ? value / outOf * 20 : 0 }
    }

    struct SubjectGrades: Equatable, Sendable {
        let subject: String
        /// Coefficient-weighted average /20; nil when no grade counts.
        let average: Double?
        /// Most recent first.
        let grades: [GradeSnapshot]
    }

    /// One entry per subject (alphabetical), with its weighted average /20.
    static func subjects(_ grades: [GradeSnapshot]) -> [SubjectGrades] {
        let bySubject = Dictionary(grouping: grades, by: \.subject)
        return bySubject.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { subject in
            let rows = bySubject[subject, default: []]
            return SubjectGrades(subject: subject, average: weightedAverage(rows),
                                 grades: rows.sorted { $0.date > $1.date })
        }
    }

    /// Coefficient-weighted average normalised to /20; grades without a
    /// scale or with a zero coefficient do not count.
    static func weightedAverage(_ grades: [GradeSnapshot]) -> Double? {
        let usable = grades.filter { $0.outOf > 0 && $0.coefficient > 0 }
        let weight = usable.reduce(0) { $0 + $1.coefficient }
        guard weight > 0 else { return nil }
        return usable.reduce(0) { $0 + $1.normalized * $1.coefficient } / weight
    }

    /// « 14,5/20 » with the grade's own scale, French decimal comma.
    static func gradeText(_ grade: GradeSnapshot) -> String {
        "\(number(grade.value))/\(number(grade.outOf))"
    }

    /// « coef. 2 », nil for coefficient 1.
    static func coefficientText(_ coefficient: Double) -> String? {
        coefficient == 1 ? nil : "coef. \(number(coefficient))"
    }

    /// « 14,2 », one decimal, French comma.
    static func averageText(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « 15 » for whole numbers, else « 14,5 » (up to two decimals).
    static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }
}
