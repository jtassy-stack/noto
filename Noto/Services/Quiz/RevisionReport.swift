import Foundation

// Parent-side reading of the revision data (plan §3.7): the « Révisions »
// screen, the briefing item and the weekly summary. Pure: snapshots in,
// values out, `now` and `calendar` passed in. Every string here addresses
// the parent (vouvoiement, « Votre enfant… »), never the child.
//
// Data locality (V1): nōto has no cross-device sync, so these figures exist
// only on the device where the child plays the quizzes (the child's phone,
// read behind the parent PIN, or a shared family device).

// MARK: - Summary

struct RevisionSummary: Sendable, Equatable {
    /// Quizzes with at least one question.
    let quizzes7d: Int
    let quizzes30d: Int
    /// Passed quizzes (`AttemptSnapshot.passed`) over 7 days.
    let passed7d: Int
    let minutesEarnedToday: Int
    let minutesEarned7d: Int
    /// Reward minutes actually used. Nil until 3.4 (`RewardLedger`):
    /// nothing records consumed minutes yet, the screen shows « — ».
    let minutesUsed7d: Int?
    /// Leitner box 4–5 (`SpacedRepetition.isMastered`).
    let masteredCount: Int
    /// Box 3.
    let inProgressCount: Int
    /// Box 1–2: missed recently or still new.
    let fragileCount: Int
    /// Fragile notion keys, weakest (lowest box, then oldest review) first.
    let fragileNotionKeys: [String]
    /// Notions whose Leitner state was updated today.
    let notionsReviewedToday: Int
    let quizzesToday: Int
    let streakDays: Int
    let lastQuizDate: Date?
    /// Last 7 days, by denial (weekly suggestion rules).
    let capOrTiersReached7d: Int
    /// Distinct days in the last 7 with a `.capReached` quiz. Only the cap
    /// counts: a `.tiersExhausted` day (barème used up, checked before the
    /// cap in `RewardPolicy`) would not earn more with a higher cap.
    let capDays7d: Int
    let belowThreshold7d: Int
    let tooShort7d: Int

    /// Any quiz in the last 30 days: the revision feature is in use on this
    /// device (gates the briefing item and the weekly notification).
    var isActive: Bool { quizzes30d > 0 }

    static func build(attempts: [AttemptSnapshot], masteries: [MasterySnapshot], streakDays: Int,
                      now: Date, calendar: Calendar) -> RevisionSummary {
        let played = attempts.filter { $0.totalCount > 0 }
        let start7 = calendar.quizStartOfDay(addingDays: -6, to: now)
        let start30 = calendar.quizStartOfDay(addingDays: -29, to: now)
        let week = played.filter { $0.date >= start7 && $0.date <= now }
        let month = played.filter { $0.date >= start30 && $0.date <= now }
        let today = played.filter { calendar.isDate($0.date, inSameDayAs: now) }

        let capped = week.filter { $0.denial == .capReached || $0.denial == .tiersExhausted }
        let capDays = Set(capped.filter { $0.denial == .capReached }
            .map { calendar.startOfDay(for: $0.date) }).count

        let fragile = masteries
            .filter { $0.leitnerBox <= 2 }
            .sorted { lhs, rhs in
                if lhs.leitnerBox != rhs.leitnerBox { return lhs.leitnerBox < rhs.leitnerBox }
                return (lhs.lastReviewedAt ?? .distantPast) < (rhs.lastReviewedAt ?? .distantPast)
            }

        return RevisionSummary(
            quizzes7d: week.count,
            quizzes30d: month.count,
            passed7d: week.filter(\.passed).count,
            minutesEarnedToday: today.reduce(0) { $0 + max(0, $1.minutesEarned) },
            minutesEarned7d: week.reduce(0) { $0 + max(0, $1.minutesEarned) },
            minutesUsed7d: nil,
            masteredCount: masteries.filter(SpacedRepetition.isMastered).count,
            inProgressCount: masteries.filter { $0.leitnerBox == 3 }.count,
            fragileCount: fragile.count,
            fragileNotionKeys: fragile.map(\.notionKey),
            notionsReviewedToday: masteries.filter { m in
                m.lastReviewedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            }.count,
            quizzesToday: today.count,
            streakDays: streakDays,
            lastQuizDate: played.map(\.date).max(),
            capOrTiersReached7d: capped.count,
            capDays7d: capDays,
            belowThreshold7d: week.filter { $0.denial == .belowThreshold }.count,
            tooShort7d: week.filter { $0.denial == .tooShort }.count
        )
    }

    /// One sentence for the weekly summary, parent tone.
    var weeklySentence: String {
        guard quizzes7d > 0 else { return "Pas de révision ces 7 derniers jours." }
        let quiz = quizzes7d > 1 ? "\(quizzes7d) quiz" : "1 quiz"
        let passed = passed7d > 1 ? "\(passed7d) réussis" : (passed7d == 1 ? "1 réussi" : "aucun réussi")
        return "Ces 7 derniers jours, votre enfant a fait \(quiz) (\(passed)) et gagné \(minutesEarned7d) min."
    }
}

// MARK: - Weekly adjustment suggestion

/// A one-line nudge for the parent, from the last 7 days. At most one, the
/// first rule that matches wins:
/// 1. struggling at 4/5: ≥ 3 quizzes below the threshold, at least half of
///    the week's quizzes, while the threshold is above 3/5 → lower it;
/// 2. hitting the cap: `.capReached` on ≥ 3 distinct days, cap below its
///    maximum and the barème able to earn more than the cap → raise it by
///    10 min (`.tiersExhausted` days never count: a higher cap cannot help);
/// 3. thin bank: ≥ 2 quizzes too short, minimum above 3 → lower it.
enum RevisionSuggestion: Equatable, Sendable {
    case lowerThreshold
    case raiseCap(to: Int)
    case lowerMinimumLength(to: Int)

    static let capStep = 10

    static func suggest(summary s: RevisionSummary, config: RewardConfig) -> RevisionSuggestion? {
        if s.belowThreshold7d >= 3, s.belowThreshold7d * 2 >= s.quizzes7d,
           config.passThreshold > 0.6 + 1e-9 {
            return .lowerThreshold
        }
        if s.capDays7d >= 3, config.dailyCap < RewardConfig.dailyCapRange.upperBound,
           config.tiers.reduce(0, +) > config.dailyCap {
            return .raiseCap(to: min(config.dailyCap + capStep, RewardConfig.dailyCapRange.upperBound))
        }
        if s.tooShort7d >= 2, config.minQuestionCount > RewardConfig.minQuestionCountRange.lowerBound {
            return .lowerMinimumLength(to: config.minQuestionCount - 1)
        }
        return nil
    }

    /// Parent-facing copy (vouvoiement).
    var text: String {
        switch self {
        case .lowerThreshold:
            return "Votre enfant échoue souvent de peu au seuil de 4/5 : vous pouvez l'abaisser à 3/5 "
                + "le temps qu'il prenne confiance."
        case .raiseCap(let minutes):
            return "Votre enfant atteint souvent le plafond quotidien : vous pouvez le relever à \(minutes) min."
        case .lowerMinimumLength(let count):
            return "Plusieurs quiz étaient trop courts pour rapporter des minutes (banque de questions encore réduite) : "
                + "vous pouvez abaisser la longueur minimale à \(count) questions."
        }
    }

    /// The config with the suggestion applied (« Appliquer » button).
    func applied(to config: RewardConfig) -> RewardConfig {
        var c = config
        switch self {
        case .lowerThreshold: c.passThreshold = 0.6
        case .raiseCap(let minutes): c.dailyCap = minutes
        case .lowerMinimumLength(let count): c.minQuestionCount = count
        }
        return c.sanitized()
    }
}

// MARK: - Briefing item

/// The « Révisions » briefing line, parent tone. Nil when not relevant:
/// - no quiz in 30 days on this device (feature unused: never nag);
/// - nothing yet today, no contrôle tomorrow, and before 17:00 (the child
///   is still at school).
/// Priority: `.low`, raised to `.normal` only when a contrôle is tomorrow and
/// nothing was revised today.
struct RevisionBriefingItem: Sendable, Equatable {
    let title: String
    let subtitle: String
    let priority: BriefingPriority

    static let eveningHour = 17

    static func make(summary s: RevisionSummary, examTomorrow: Bool, now: Date,
                     calendar: Calendar) -> RevisionBriefingItem? {
        guard s.isActive else { return nil }

        if s.quizzesToday > 0 {
            let title: String
            if s.notionsReviewedToday > 0 {
                let n = s.notionsReviewedToday
                title = "Votre enfant a révisé \(n) notion\(n > 1 ? "s" : "") aujourd'hui"
            } else {
                let n = s.quizzesToday
                title = "Votre enfant a fait \(n) quiz de révision aujourd'hui"
            }
            var parts = ["\(s.minutesEarnedToday) min gagnées"]
            if s.streakDays > 1 { parts.append("série de \(s.streakDays) jours") }
            return RevisionBriefingItem(title: title, subtitle: parts.joined(separator: " · "), priority: .low)
        }

        if examTomorrow {
            return RevisionBriefingItem(
                title: "Pas encore de révision aujourd'hui",
                subtitle: "Un contrôle est prévu demain : un quiz de 3 minutes peut aider votre enfant.",
                priority: .normal
            )
        }

        guard calendar.component(.hour, from: now) >= eveningHour else { return nil }
        return RevisionBriefingItem(
            title: "Pas encore de révision aujourd'hui",
            subtitle: s.streakDays > 0 ? "Série en cours : \(s.streakDays) jour\(s.streakDays > 1 ? "s" : "")" : "",
            priority: .low
        )
    }
}

// MARK: - Notion labels

enum RevisionNotionLabel {
    /// "Subject · Theme" from the curriculum for a `NotionKey` (folded), or
    /// the key's last part when the theme is no longer in the programme.
    static func label(for key: String, programs: [CurriculumProgram]) -> String {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 {
            for program in programs {
                for subject in program.subjects {
                    for theme in subject.themes
                    where NotionKey.make(level: program.level, subject: subject.name, theme: theme.theme) == key {
                        return "\(subject.name) · \(theme.theme)"
                    }
                }
            }
        }
        let fallback = parts.last ?? key
        return fallback.prefix(1).uppercased() + fallback.dropFirst()
    }
}
