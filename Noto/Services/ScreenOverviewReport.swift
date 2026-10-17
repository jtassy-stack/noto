import Foundation

/// Parent « Écran » tab: the bonus minutes earned with quizzes (today against
/// the daily cap, the last 7 days), the class hours the lock covers and the
/// barème. Pure: values in, values out, `now` and `calendar` passed in.
/// Parent tone (vouvoiement).
///
/// Data locality (V1): quizzes and the reward rules live on the device where
/// the child plays; the timetable is on every device that syncs the school
/// account. nōto reads no app usage (that needs a DeviceActivityReport
/// extension), so this screen shows earned minutes, never time spent.
enum ScreenOverviewReport {
    struct DayMinutes: Equatable, Sendable, Identifiable {
        let date: Date
        /// « L », « M »…, Monday first.
        let letter: String
        let minutes: Int
        var id: Date { date }
    }

    /// Minutes credited by quizzes per day, the last 7 days, oldest first.
    static func earnedPerDay(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> [DayMinutes] {
        let today = calendar.startOfDay(for: now)
        let perDay = Dictionary(grouping: attempts.filter { $0.date <= now },
                                by: { calendar.startOfDay(for: $0.date) })
            .mapValues { $0.reduce(0) { $0 + max(0, $1.minutesEarned) } }
        return (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DayMinutes(date: day, letter: weekdayLetter(day, calendar: calendar), minutes: perDay[day] ?? 0)
        }
    }

    static func weekdayLetter(_ date: Date, calendar: Calendar) -> String {
        // 1 = Sunday.
        ["D", "L", "M", "M", "J", "V", "S"][calendar.component(.weekday, from: date) - 1]
    }

    /// Average over the days with at least one minute, nil when none.
    static func averageEarned(_ days: [DayMinutes]) -> Int? {
        let earning = days.map(\.minutes).filter { $0 > 0 }
        guard !earning.isEmpty else { return nil }
        return Int((Double(earning.reduce(0, +)) / Double(earning.count)).rounded())
    }

    struct Lesson: Sendable, Equatable {
        let start: Date
        let end: Date
        let cancelled: Bool
    }

    struct ClassSpan: Equatable, Sendable {
        let day: Date
        /// Minutes since midnight.
        let startMinutes: Int
        let endMinutes: Int
    }

    /// From the first lesson to the last of today, or of the next school day
    /// within a week. Cancelled lessons do not count.
    static func classSpan(lessons: [Lesson], now: Date, calendar: Calendar) -> ClassSpan? {
        let today = calendar.startOfDay(for: now)
        let live = lessons.filter { !$0.cancelled }
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let ofDay = live.filter { calendar.isDate($0.start, inSameDayAs: day) }
            guard let first = ofDay.map(\.start).min(), let last = ofDay.map(\.end).max() else { continue }
            if offset == 0, last <= now { continue }
            return ClassSpan(day: day, startMinutes: minutes(of: first, calendar: calendar),
                             endMinutes: minutes(of: last, calendar: calendar))
        }
        return nil
    }

    static func minutes(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// « 8 h », « 16 h 30 ».
    static func clockText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : String(format: "%d h %02d", h, m)
    }

    /// « Aujourd'hui », « Demain », or the weekday.
    static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Aujourd'hui" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Demain"
        }
        var style = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).weekday(.wide)
        style.timeZone = calendar.timeZone
        return style.format(day).capitalized
    }

    /// « 10 · 5 · 5 min ».
    static func tiersText(_ tiers: [Int]) -> String {
        let used = tiers.filter { $0 > 0 }
        guard !used.isEmpty else { return "Aucune minute" }
        return used.map { String($0) }.joined(separator: " · ") + " min"
    }

    /// « 12 min gagnées sur 20 possibles aujourd'hui ».
    static func todayLine(earned: Int, cap: Int) -> String {
        guard cap > 0 else { return "Les quiz ne rapportent pas de minutes (plafond à 0)." }
        return "\(earned) min gagnée\(earned > 1 ? "s" : "") sur \(cap) possibles aujourd'hui"
    }
}
