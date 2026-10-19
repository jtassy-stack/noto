import Foundation

/// Parent Accueil, « Cette semaine » (data viz): revision activity, notions
/// per subject, the general average over the weeks and the one-line
/// synthesis. Pure: snapshots in, values out, `now` and `calendar` passed
/// in. Every string addresses the parent (vouvoiement, the child in the
/// third person).
///
/// Data locality: quizzes and notions exist on the device where the child
/// plays, and on the parent's when the child's phone is linked (family sync,
/// phase 9.3); grades on every device that syncs the school account.
enum ParentWeekReport {
    // MARK: - Revision activity

    static let activityDays = 28

    /// Quizzes played per day over the last `activityDays` days, oldest first,
    /// today last: 0 = none, 1, 2, 3 = three or more.
    static func activityLevels(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> [Int] {
        let played = attempts.filter { $0.totalCount > 0 && $0.date <= now }
        let perDay = Dictionary(grouping: played, by: { calendar.startOfDay(for: $0.date) }).mapValues(\.count)
        let today = calendar.startOfDay(for: now)
        return (0..<activityDays).reversed().map { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return 0 }
            return min(3, perDay[day] ?? 0)
        }
    }

    /// Distinct days with at least one quiz in the last 7 days, today included.
    static func revisedDays(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        activityLevels(attempts: attempts, now: now, calendar: calendar).suffix(7).filter { $0 > 0 }.count
    }

    // MARK: - Notions

    struct NotionBar: Equatable, Sendable, Identifiable {
        let subject: String
        /// Box 4–5.
        let mastered: Int
        /// Box 3.
        let inProgress: Int
        /// Box 1–2.
        let fragile: Int
        var id: String { subject }
        var total: Int { mastered + inProgress + fragile }
    }

    /// One bar per subject with at least one theme already played, curriculum order.
    static func notionBars(_ subjects: [SubjectProgress]) -> [NotionBar] {
        subjects.compactMap { subject in
            let boxes = subject.themes.map(\.box).filter { $0 > 0 }
            guard !boxes.isEmpty else { return nil }
            return NotionBar(subject: subject.subject,
                             mastered: boxes.filter { $0 >= 4 }.count,
                             inProgress: boxes.filter { $0 == 3 }.count,
                             fragile: boxes.filter { $0 <= 2 }.count)
        }
    }

    /// The weakest theme played (lowest box), curriculum order on a tie.
    static func weakestTheme(_ subjects: [SubjectProgress]) -> (subject: String, theme: String)? {
        var best: (subject: String, theme: String, box: Int)?
        for subject in subjects {
            for theme in subject.themes where (1...2).contains(theme.box) {
                if best == nil || theme.box < best!.box {
                    best = (subject.subject, theme.theme, theme.box)
                }
            }
        }
        return best.map { ($0.subject, $0.theme) }
    }

    // MARK: - Average

    struct GradePoint: Sendable, Equatable {
        let value: Double
        let outOf: Double
        let coefficient: Double
        let date: Date

        /// Normalised to /20, like `Grade.normalizedValue`.
        var normalized: Double { outOf > 0 ? value / outOf * 20 : 0 }
    }

    static let averageWeeks = 8

    /// The general average (coefficient-weighted, /20) as it stood at the end
    /// of each of the last `averageWeeks` weeks, oldest first. Weeks before the
    /// first grade are left out, so the line starts with the data.
    static func averageHistory(_ grades: [GradePoint], now: Date, calendar: Calendar) -> [Double] {
        let usable = grades.filter { $0.outOf > 0 && $0.coefficient > 0 && $0.date <= now }
        let today = calendar.startOfDay(for: now)
        return (0..<averageWeeks).reversed().compactMap { back -> Double? in
            guard let end = calendar.date(byAdding: .day, value: 1 - back * 7, to: today) else { return nil }
            let upTo = usable.filter { $0.date < end }
            let weight = upTo.reduce(0) { $0 + $1.coefficient }
            guard weight > 0 else { return nil }
            return upTo.reduce(0) { $0 + $1.normalized * $1.coefficient } / weight
        }
    }

    /// « 14,2 », French decimal comma.
    static func averageText(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « +0,6 en 7 semaines » (first to last point), nil when the history is a single point.
    static func averageTrendText(_ history: [Double]) -> String? {
        guard history.count > 1, let first = history.first, let last = history.last else { return nil }
        let delta = (last - first).rounded(toPlaces: 1)
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        let weeks = history.count - 1
        return "\(sign)\(averageText(abs(delta))) en \(weeks) semaine\(weeks > 1 ? "s" : "")"
    }

    /// A move of at least this much reads as « en hausse » / « en baisse ».
    static let trendThreshold = 0.3

    // MARK: - Synthesis

    /// « Bonne semaine pour Joseph : 5 jours de révision et une moyenne en
    /// hausse. Une notion de Mathématiques reste à surveiller. » Nil when
    /// there is nothing to say.
    static func synthesis(firstName: String, revisedDays: Int?, averageHistory: [Double],
                          fragileSubject: String?) -> String? {
        var parts: [String] = []
        if let days = revisedDays, days > 0 {
            parts.append(days == 1 ? "1 jour de révision" : "\(days) jours de révision")
        }
        var trend = 0.0
        if averageHistory.count > 1, let first = averageHistory.first, let last = averageHistory.last {
            trend = last - first
            if trend >= trendThreshold { parts.append("une moyenne en hausse") }
            if trend <= -trendThreshold { parts.append("une moyenne en baisse") }
        }
        var sentences: [String] = []
        if !parts.isEmpty {
            let good = (revisedDays ?? 0) >= 4 || trend >= trendThreshold
            let lead = good ? "Bonne semaine pour \(firstName)" : "Cette semaine pour \(firstName)"
            sentences.append("\(lead) : \(parts.joined(separator: " et ")).")
        }
        if let subject = fragileSubject {
            sentences.append("Une notion en \(subject) reste à surveiller.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - Header

    /// « 12 – 18 oct. »: the last 7 days, today included.
    static func weekRangeText(now: Date, calendar: Calendar) -> String {
        let locale = Locale(identifier: "fr_FR")
        let start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        var day = Date.FormatStyle(locale: locale).day()
        day.timeZone = calendar.timeZone
        var dayMonth = Date.FormatStyle(locale: locale).day().month(.abbreviated)
        dayMonth.timeZone = calendar.timeZone
        let sameMonth = calendar.isDate(start, equalTo: now, toGranularity: .month)
        return "\((sameMonth ? day : dayMonth).format(start)) – \(dayMonth.format(now))"
    }

    // MARK: - Ce que l'enfant étudie

    /// The theme seen most recently in class, across subjects.
    static func studiedNow(_ position: ProgrammePosition) -> ProgrammePosition.Sighting? {
        position.orderedSubjects.compactMap(\.current.first).max { $0.lastSeen < $1.lastSeen }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
