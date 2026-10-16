import Foundation
@testable import Noto

/// Fixed clock for the Screen Time reward suites: Wednesday 14 October 2026,
/// Europe/Paris (weekday 4 in `Calendar`'s 1 = Sunday convention).
enum RewardClock {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    static let wednesday = 4

    /// 14 Oct 2026 + `dayOffset` days, at `hour:minute`.
    static func date(day dayOffset: Int = 0, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        let day = calendar.date(byAdding: .day, value: dayOffset, to: base)!
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)!
    }

    /// A private `UserDefaults` suite (never the app group, which the test
    /// host shares with the installed app).
    static func privateDefaults(_ name: String) -> UserDefaults {
        let suite = "\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
