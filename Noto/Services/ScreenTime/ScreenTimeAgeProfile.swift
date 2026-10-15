import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "ScreenTimePlan")

/// A daily time range, in minutes from midnight (may cross midnight: the
/// night range 21:00 → 07:00).
struct DailyTimeRange: Codable, Sendable, Equatable {
    var startMinutes: Int
    var endMinutes: Int

    init(start: (hour: Int, minute: Int), end: (hour: Int, minute: Int)) {
        startMinutes = start.hour * 60 + start.minute
        endMinutes = end.hour * 60 + end.minute
    }

    /// « 21:00 – 07:00 ».
    var label: String { "\(Self.format(startMinutes)) – \(Self.format(endMinutes))" }

    static func format(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

/// Age profiles of the guided Screen Time setup (plan §3.7), with repères:
/// a suggested base budget, an earnable cap and barème, and night / meal
/// ranges. These are suggestions the parent adjusts, not rules: nōto applies
/// the base budget (app-limit monitoring) and the reward config; the night
/// and meal ranges are shown as the values to enter in iOS Temps d'arrêt
/// (nōto does not shield on a time range besides the class lock, which this
/// setup never touches).
enum ScreenTimeAgeProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case age11to13
    case age14to15
    case age16to18

    var id: String { rawValue }

    var label: String {
        switch self {
        case .age11to13: return "11–13 ans"
        case .age14to15: return "14–15 ans"
        case .age16to18: return "16–18 ans"
        }
    }

    var levelsLabel: String {
        switch self {
        case .age11to13: return "6e · 5e"
        case .age14to15: return "4e · 3e"
        case .age16to18: return "Lycée"
        }
    }

    /// Daily budget of the leisure apps before any quiz (whole hours: the
    /// app-limit threshold is set in hours).
    var baseBudgetHours: Int {
        switch self {
        case .age11to13: return 1
        case .age14to15: return 2
        case .age16to18: return 2
        }
    }

    /// Earnable minutes per day (`RewardConfig.dailyCap`) and barème.
    var earnableCap: Int {
        switch self {
        case .age11to13: return 20
        case .age14to15, .age16to18: return 30
        }
    }

    var tiers: [Int] {
        switch self {
        case .age11to13: return [10, 5, 5]
        case .age14to15, .age16to18: return [10, 10, 10]
        }
    }

    var night: DailyTimeRange {
        switch self {
        case .age11to13: return DailyTimeRange(start: (21, 0), end: (7, 0))
        case .age14to15: return DailyTimeRange(start: (22, 0), end: (7, 0))
        case .age16to18: return DailyTimeRange(start: (23, 0), end: (7, 0))
        }
    }

    /// Lunch and dinner, the same for every profile.
    var meals: [DailyTimeRange] {
        [DailyTimeRange(start: (12, 0), end: (13, 30)), DailyTimeRange(start: (19, 30), end: (20, 30))]
    }

    /// From the child's class (6e–5e, 4e–3e, lycée); nil outside 6e → Tle.
    static func suggested(forGrade grade: String) -> ScreenTimeAgeProfile? {
        switch CurriculumService.canonicalLevel(grade) {
        case "6e", "5e": return .age11to13
        case "4e", "3e": return .age14to15
        case "2nde", "1re", "Tle": return .age16to18
        default: return nil
        }
    }

    /// `config` with this profile's cap and barème; every other rule
    /// (threshold, bonus, replay, minimum length) is kept.
    func applied(to config: RewardConfig) -> RewardConfig {
        var c = config
        c.dailyCap = earnableCap
        c.tiers = tiers
        return c.sanitized()
    }
}

/// What the guided setup decided: the profile and the night / meal ranges
/// (repères, see `ScreenTimeAgeProfile`). App group JSON in a versioned
/// envelope; 3.4 may read the ranges to keep reward unlocks out of them.
struct ScreenTimePlan: Codable, Sendable, Equatable {
    var profile: ScreenTimeAgeProfile
    var night: DailyTimeRange
    var meals: [DailyTimeRange]

    init(profile: ScreenTimeAgeProfile) {
        self.profile = profile
        night = profile.night
        meals = profile.meals
    }
}

enum ScreenTimePlanStore {
    static let key = "noto_screentime_plan"

    struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let plan: ScreenTimePlan
    }

    static func load(defaults: UserDefaults? = RewardConfigStore.appGroupDefaults) -> ScreenTimePlan? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Envelope.currentVersion else {
            logger.error("Screen time plan unreadable or from another version, ignored")
            return nil
        }
        return envelope.plan
    }

    static func save(_ plan: ScreenTimePlan, defaults: UserDefaults? = RewardConfigStore.appGroupDefaults) {
        guard let defaults,
              let data = try? JSONEncoder().encode(Envelope(version: Envelope.currentVersion, plan: plan)) else {
            logger.error("Screen time plan not saved")
            return
        }
        defaults.set(data, forKey: key)
    }
}
