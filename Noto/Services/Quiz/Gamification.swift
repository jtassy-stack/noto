import Foundation

// Gamification (plan §3.6, design brief C.1 item 6). Pure: no SwiftData, no
// clock, no actor. `now` and `calendar` are always passed in, inputs are the
// Sendable snapshots of `QuizSnapshots.swift`. Persistence (jokers spent) is
// done by the caller on the main actor (`GamificationStore`).
//
// Everything here rewards REAL work only: XP comes from right answers, the
// série from passed quizzes, badges from milestones actually reached. There
// is no locked badge, no countdown, no loss message (child mode, no
// pressure).

// MARK: - Calendar day

/// A calendar day as year / month / day in the calendar it was computed
/// with. Used as the streak unit and as the persisted joker key
/// (`StreakJoker.dayKey`, "YYYY-MM-DD"): a string key survives a time-zone
/// change, a stored start-of-day `Date` would shift by the offset.
struct CalendarDay: Hashable, Comparable, Sendable, Codable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// Parses "YYYY-MM-DD"; nil for anything else.
    init?(key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// "YYYY-MM-DD".
    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Joker budgets are per calendar month of the COVERED day.
    var monthIndex: Int { year * 12 + (month - 1) }

    /// Start of this day in `calendar` (noon then `startOfDay`, so a zone
    /// whose DST jump is at midnight still resolves).
    func startOfDay(in calendar: Calendar) -> Date {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }

    /// Calendar arithmetic (DST-safe), never `± 86 400 s`.
    func adding(days: Int, calendar: Calendar) -> CalendarDay {
        CalendarDay(calendar.quizStartOfDay(addingDays: days, to: startOfDay(in: calendar)), calendar: calendar)
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

// MARK: - Results

/// XP and level of one subject.
struct SubjectXP: Equatable, Sendable, Identifiable {
    /// Display name, as first seen on an item (`QuizItem.subject`).
    let subject: String
    let xp: Int
    var id: String { SubjectAlias.fold(subject) }
    var level: Gamification.LevelProgress { Gamification.level(forXP: xp) }
}

/// A subject level reached by the quiz just played (`QuizResultView`).
struct SubjectLevelUp: Equatable, Sendable {
    let subject: String
    let level: Int
}

/// The série as shown on the child home.
struct StreakStatus: Equatable, Sendable {
    /// Consecutive days with a passed quiz. A day covered by a joker keeps
    /// the série alive but does not add to it.
    let days: Int
    /// Missed days of the current gap that jokers cover (empty most days).
    /// Already applied to `days`; persisted as `StreakJoker` only once today
    /// has a passed quiz (`GamificationStore.recordDueJokers`), pending before.
    let newJokers: [CalendarDay]
    /// Jokers spent on days of the current month (persisted + new).
    let jokersUsedThisMonth: Int
    let jokersLeftThisMonth: Int
    /// Yesterday (or the day before) was saved by a joker: the home says so.
    let protectedByJoker: Bool
}

enum BadgeKind: Hashable, Sendable {
    case firstQuiz
    /// 7 or 30 days.
    case streak(days: Int)
    case subjectLevel(subject: String, level: Int)
    case themeMastered(subject: String, theme: String)
}

struct EarnedBadge: Hashable, Sendable, Identifiable {
    let kind: BadgeKind
    /// When it was reached; nil when the history does not say (theme
    /// mastery reached before `MasterySnapshot.masteredAt` existed).
    let earnedAt: Date?

    var id: String {
        switch kind {
        case .firstQuiz: "first-quiz"
        case .streak(let days): "streak-\(days)"
        case .subjectLevel(let subject, let level): "level-\(SubjectAlias.fold(subject))-\(level)"
        case .themeMastered(let subject, let theme):
            "theme-\(SubjectAlias.fold(subject))-\(SubjectAlias.fold(theme))"
        }
    }
}

// MARK: - Gamification

enum Gamification {

    // MARK: XP
    //
    // | answer                     | XP      |
    // |----------------------------|---------|
    // | wrong or skipped           | 0       |
    // | right, difficulty 1        | 10      |
    // | right, difficulty 2        | 10 + 2  |
    // | right, difficulty 3        | 10 + 5  |
    //
    // Difficulty outside 1…3 is clamped. A perfect 5-question quiz of
    // difficulty 1 = 50 XP. No XP for an attempt caught by a farming guard,
    // checked on its own whatever the score and whichever denial
    // `RewardPolicy` returned first: too fast (tapping through, below
    // `minDurationSec`), or the same question-key set as ANY earlier attempt
    // inside `replayWindow`, failed ones included (replaying a failed set).
    // Every other attempt earns its right answers, including a
    // `.belowThreshold` one (« ce que tu viens de revoir compte quand
    // même ») and a capped one (design brief A.2 rule 8: a passed quiz still
    // feeds XP and the série when it earns no minute).
    //
    // XP is computed once, at the end of the quiz, and stored per question on
    // `QuizAttempt.itemXP` with the subject (`itemSubjects`): the attempt
    // keeps only sorted `questionKeys` and item ids that a bank sync can
    // delete, so subject and difficulty cannot be recovered later. Attempts
    // saved before 3.6 therefore carry 0 XP.
    //
    // The culture question of the day earns no XP (and no minute): it is a
    // curiosity card, not revision (`DailyCultureQuestion`).

    static let xpPerCorrectAnswer = 10

    /// Bonus on top of `xpPerCorrectAnswer` for a right answer.
    static func difficultyBonus(_ difficulty: Int) -> Int {
        switch difficulty {
        case ...1: 0
        case 2: 2
        default: 5
        }
    }

    static func xp(correct: Bool, difficulty: Int) -> Int {
        correct ? xpPerCorrectAnswer + difficultyBonus(difficulty) : 0
    }

    /// False when a farming guard catches the attempt (too fast, or an
    /// identical replay of any earlier attempt, passed or not). Independent of
    /// `RewardPolicy.evaluate`'s first denial, so a fast or replayed attempt
    /// below the threshold earns nothing either.
    static func earnsXP(attempt: AttemptSnapshot, history: [AttemptSnapshot], config: RewardConfig,
                        now: Date, calendar: Calendar) -> Bool {
        !RewardPolicy.isTooFast(attempt, config: config)
            && !RewardPolicy.isReplay(attempt, history: history, passedOnly: false, config: config,
                                      now: now, calendar: calendar)
    }

    /// XP of each question of a finished quiz, in play order (zeros when it
    /// does not `earnsXP`).
    static func questionXP(difficulties: [Int], correct: [Bool], earnsXP: Bool) -> [Int] {
        guard earnsXP else { return Array(repeating: 0, count: correct.count) }
        return zip(difficulties, correct).map { xp(correct: $1, difficulty: $0) }
    }

    // MARK: Levels
    //
    // Level n starts at 50·n·(n−1) cumulative XP in the subject: each level
    // costs 100 XP more than the previous one.
    //
    // | level | from XP | ≈ perfect easy quizzes |
    // |-------|---------|------------------------|
    // | 1     | 0       | 0                      |
    // | 2     | 100     | 2                      |
    // | 3     | 300     | 6                      |
    // | 4     | 600     | 12                     |
    // | 5     | 1 000   | 20                     |
    //
    // No cap: the curve stays reachable but slows down.

    struct LevelProgress: Equatable, Sendable {
        let level: Int
        /// XP earned since the start of `level`.
        let xpIntoLevel: Int
        /// XP between the start of `level` and the next one.
        let xpForNextLevel: Int
        var fraction: Double { xpForNextLevel > 0 ? Double(xpIntoLevel) / Double(xpForNextLevel) : 0 }
    }

    /// Cumulative XP at which `level` starts (level ≤ 1 → 0).
    static func xpThreshold(level: Int) -> Int {
        guard level > 1 else { return 0 }
        return 50 * level * (level - 1)
    }

    static func level(forXP rawXP: Int) -> LevelProgress {
        let xp = max(0, rawXP)
        var level = 1
        while xpThreshold(level: level + 1) <= xp { level += 1 }
        let start = xpThreshold(level: level)
        return LevelProgress(level: level, xpIntoLevel: xp - start,
                             xpForNextLevel: xpThreshold(level: level + 1) - start)
    }

    /// Total XP over every attempt.
    static func totalXP(attempts: [AttemptSnapshot]) -> Int {
        attempts.reduce(0) { $0 + $1.xpEarned }
    }

    /// XP per subject, subjects grouped case- and accent-insensitively, in
    /// order of first appearance (chronological). Questions without a subject
    /// count in `totalXP` only.
    static func subjectXP(attempts: [AttemptSnapshot]) -> [SubjectXP] {
        var order: [String] = []
        var names: [String: String] = [:]
        var totals: [String: Int] = [:]
        for attempt in attempts.sorted(by: { $0.date < $1.date }) {
            for (subject, xp) in zip(attempt.itemSubjects, attempt.itemXP) {
                let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = SubjectAlias.fold(trimmed)
                if names[key] == nil {
                    names[key] = trimmed
                    order.append(key)
                }
                totals[key, default: 0] += max(0, xp)
            }
        }
        return order.map { SubjectXP(subject: names[$0]!, xp: totals[$0] ?? 0) }
    }

    /// XP of `subject` (folded match), 0 when never played.
    static func xp(for subject: String, in subjects: [SubjectXP]) -> Int {
        let key = SubjectAlias.fold(subject)
        return subjects.first { $0.id == key }?.xp ?? 0
    }

    /// Levels crossed between two XP tallies, one entry per subject (the
    /// highest level reached), in `after` order.
    static func levelUps(before: [SubjectXP], after: [SubjectXP]) -> [SubjectLevelUp] {
        after.compactMap { subject in
            let old = level(forXP: xp(for: subject.subject, in: before)).level
            let new = subject.level.level
            return new > old ? SubjectLevelUp(subject: subject.subject, level: new) : nil
        }
    }

    // MARK: Série + jokers
    //
    // A day counts when it has at least one passed quiz
    // (`AttemptSnapshot.passed`). Counted back from today; when nothing has
    // passed yet today the count starts from yesterday (the série is not
    // shown as broken before the child has had a chance to play).
    //
    // Jokers: 2 per calendar month. A missed day is covered automatically
    // when, and only when:
    // - it is in the CURRENT gap, i.e. between the last covered day and
    //   today (an old, already broken gap is never resurrected later);
    // - the whole gap can be covered: a joker is never wasted on a gap the
    //   budget cannot bridge (a 3-day hole in one month breaks the série);
    // - the covered day's month has fewer than 2 jokers (budget per month of
    //   the covered day, so it resets on the 1st; a gap over a month boundary
    //   draws on both months);
    // - it is not today (today is still playable) nor in the future;
    // - a covered day exists before the gap (nothing to save otherwise).
    // The gap jokers are returned in `newJokers` and already applied to
    // `days`, but they stay PENDING until a passed quiz closes the gap: the
    // caller persists them (`StreakJoker`, `GamificationStore.recordDueJokers`)
    // only once today is a played day, from `QuizSession.finish`. A child who
    // skips today too therefore burns nothing: the next day the longer gap is
    // re-evaluated against an intact budget. Once persisted, a joker day stays
    // covered whatever happens later (stable série).

    static let jokersPerMonth = 2

    /// Days with at least one passed quiz, in `calendar`.
    static func playedDays(attempts: [AttemptSnapshot], calendar: Calendar) -> Set<CalendarDay> {
        Set(attempts.filter(\.passed).map { CalendarDay($0.date, calendar: calendar) })
    }

    /// - Parameter jokerBudget: jokers per month; 0 disables jokers
    ///   (`QuizStreak.current`, the 3.5 counter).
    static func streak(attempts: [AttemptSnapshot], jokers: [CalendarDay], now: Date, calendar: Calendar,
                       jokerBudget: Int = jokersPerMonth) -> StreakStatus {
        let played = playedDays(attempts: attempts, calendar: calendar)
        let today = CalendarDay(now, calendar: calendar)
        // A joker never covers today (or a later day, e.g. after a clock change).
        let persisted = Set(jokers.filter { $0 < today })
        let fresh = jokersToSpend(played: played, jokers: persisted, today: today,
                                  calendar: calendar, budget: jokerBudget)
        let allJokers = persisted.union(fresh)
        let covered = played.union(allJokers)

        let yesterday = today.adding(days: -1, calendar: calendar)
        var day = played.contains(today) ? today : yesterday
        var count = 0
        while covered.contains(day) {
            if played.contains(day) { count += 1 }
            day = day.adding(days: -1, calendar: calendar)
        }
        // « Un joker a protégé ta série »: the série is alive and yesterday
        // was covered by a joker, not by a quiz.
        let protected = count > 0 && allJokers.contains(yesterday)

        let used = allJokers.filter { $0.monthIndex == today.monthIndex }.count
        return StreakStatus(days: count, newJokers: fresh.sorted(), jokersUsedThisMonth: used,
                            jokersLeftThisMonth: max(0, jokerBudget - used), protectedByJoker: protected)
    }

    /// The current gap (yesterday back to the last covered day) when the
    /// budget covers all of it, else nothing. Pure helper of `streak`.
    static func jokersToSpend(played: Set<CalendarDay>, jokers: Set<CalendarDay>, today: CalendarDay,
                              calendar: Calendar, budget: Int = jokersPerMonth) -> Set<CalendarDay> {
        guard budget > 0, let earliest = played.union(jokers).min() else { return [] }
        // A gap longer than two months' budget can never be bridged.
        let longestBridgeable = 2 * budget
        var gap: [CalendarDay] = []
        var day = today.adding(days: -1, calendar: calendar)
        while day >= earliest, !played.contains(day), !jokers.contains(day) {
            gap.append(day)
            if gap.count > longestBridgeable { return [] }
            day = day.adding(days: -1, calendar: calendar)
        }
        // Empty gap: yesterday is covered. `day < earliest`: no anchor.
        guard !gap.isEmpty, day >= earliest else { return [] }

        var usedByMonth: [Int: Int] = [:]
        for joker in jokers { usedByMonth[joker.monthIndex, default: 0] += 1 }
        for missed in gap {
            let month = missed.monthIndex
            guard usedByMonth[month, default: 0] < budget else { return [] }
            usedByMonth[month, default: 0] += 1
        }
        return Set(gap)
    }

    /// First day each série length in `milestones` was reached, over the
    /// whole history (a badge earned stays earned when the série later
    /// breaks). Jokers bridge runs the same way as in `streak`.
    static func streakMilestones(attempts: [AttemptSnapshot], jokers: [CalendarDay], calendar: Calendar,
                                 milestones: [Int] = [7, 30]) -> [Int: CalendarDay] {
        let played = playedDays(attempts: attempts, calendar: calendar)
        let covered = played.union(jokers).sorted()
        var reached: [Int: CalendarDay] = [:]
        var run = 0
        var previous: CalendarDay?
        for day in covered {
            if let previous, previous.adding(days: 1, calendar: calendar) != day { run = 0 }
            if played.contains(day) {
                run += 1
                for milestone in milestones where run == milestone && reached[milestone] == nil {
                    reached[milestone] = day
                }
            }
            previous = day
        }
        return reached
    }

    // MARK: Badges
    //
    // Only real milestones, earned only (nothing locked is ever listed):
    // - first quiz: the first finished quiz with at least one question,
    //   whatever its score;
    // - série of 7 and of 30 days (longest-ever, see `streakMilestones`);
    // - every subject level from 2 up (`level(forXP:)`), dated by the
    //   attempt that crossed it;
    // - « thème maîtrisé »: every notion of a programme theme has a
    //   `NotionMastery` that is, or once was, mastered (box ≥ 4, stamped
    //   once in `masteredAt`), and the theme has at least one. Permanent: a
    //   later miss sends the box back to 1 but never takes the badge back
    //   (child mode, no loss). Notions are keyed at theme level today
    //   (`NotionKey.make(level:subject:theme:)`), finer keys
    //   "<theme key>|<notion>" are grouped under their theme.

    static let streakBadgeDays = [7, 30]

    static func badges(attempts: [AttemptSnapshot], masteries: [MasterySnapshot], jokers: [CalendarDay],
                       level: String, specialties: [String], curriculum: some CurriculumLookup,
                       calendar: Calendar) -> [EarnedBadge] {
        var badges: [EarnedBadge] = []
        let sorted = attempts.sorted { $0.date < $1.date }

        if let first = sorted.first(where: { $0.totalCount > 0 }) {
            badges.append(EarnedBadge(kind: .firstQuiz, earnedAt: first.date))
        }

        let milestones = streakMilestones(attempts: attempts, jokers: jokers, calendar: calendar,
                                          milestones: streakBadgeDays)
        for days in streakBadgeDays {
            if let day = milestones[days] {
                badges.append(EarnedBadge(kind: .streak(days: days), earnedAt: day.startOfDay(in: calendar)))
            }
        }

        badges += subjectLevelBadges(attempts: sorted)
        badges += themeMasteredBadges(masteries: masteries, level: level, specialties: specialties,
                                      curriculum: curriculum)
        return badges
    }

    /// One badge per subject level ≥ 2, dated by the attempt that reached it.
    static func subjectLevelBadges(attempts: [AttemptSnapshot]) -> [EarnedBadge] {
        var order: [String] = []
        var names: [String: String] = [:]
        var totals: [String: Int] = [:]
        var reached: [String: [(level: Int, date: Date)]] = [:]
        for attempt in attempts.sorted(by: { $0.date < $1.date }) {
            var gained: [String: Int] = [:]
            for (subject, xp) in zip(attempt.itemSubjects, attempt.itemXP) {
                let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = SubjectAlias.fold(trimmed)
                if names[key] == nil {
                    names[key] = trimmed
                    order.append(key)
                }
                gained[key, default: 0] += max(0, xp)
            }
            for (key, xp) in gained {
                let old = level(forXP: totals[key] ?? 0).level
                totals[key, default: 0] += xp
                let new = level(forXP: totals[key] ?? 0).level
                if new > old {
                    for reachedLevel in (old + 1)...new {
                        reached[key, default: []].append((reachedLevel, attempt.date))
                    }
                }
            }
        }
        return order.flatMap { key in
            (reached[key] ?? []).map {
                EarnedBadge(kind: .subjectLevel(subject: names[key]!, level: $0.level), earnedAt: $0.date)
            }
        }
    }

    /// Mastered themes of the child's level programme, in curriculum order.
    static func themeMasteredBadges(masteries: [MasterySnapshot], level rawLevel: String,
                                    specialties: [String], curriculum: some CurriculumLookup) -> [EarnedBadge] {
        let level = CurriculumService.canonicalLevel(rawLevel)
        guard CurriculumService.revisionLevels.contains(level), !masteries.isEmpty else { return [] }
        var badges: [EarnedBadge] = []
        var seenSubjects = Set<String>()
        var seenKeys = Set<String>()
        for subject in curriculum.subjects(for: level) where seenSubjects.insert(subject).inserted {
            for theme in curriculum.themes(for: level, subject: subject, specialties: specialties) {
                let key = NotionKey.make(level: level, subject: subject, theme: theme.theme)
                guard seenKeys.insert(key).inserted,
                      isThemeMastered(themeKey: key, masteries: masteries) else { continue }
                badges.append(EarnedBadge(kind: .themeMastered(subject: subject, theme: theme.theme),
                                          earnedAt: themeMasteredAt(themeKey: key, masteries: masteries)))
            }
        }
        return badges
    }

    /// Every notion under `themeKey` is, or once was, mastered, and there is
    /// at least one.
    static func isThemeMastered(themeKey: String, masteries: [MasterySnapshot]) -> Bool {
        let notions = themeNotions(themeKey, in: masteries)
        return !notions.isEmpty && notions.allSatisfy(hasBeenMastered)
    }

    /// When the last notion of the theme was first mastered (the theme then
    /// became mastered); nil when one of them predates `masteredAt`.
    static func themeMasteredAt(themeKey: String, masteries: [MasterySnapshot]) -> Date? {
        let dates = themeNotions(themeKey, in: masteries).map(\.masteredAt)
        guard !dates.isEmpty, dates.allSatisfy({ $0 != nil }) else { return nil }
        return dates.compactMap { $0 }.max()
    }

    /// Mastered now, or once (a miss resets the box, never `masteredAt`).
    static func hasBeenMastered(_ mastery: MasterySnapshot) -> Bool {
        mastery.masteredAt != nil || SpacedRepetition.isMastered(mastery)
    }

    private static func themeNotions(_ themeKey: String, in masteries: [MasterySnapshot]) -> [MasterySnapshot] {
        masteries.filter { $0.notionKey == themeKey || $0.notionKey.hasPrefix(themeKey + "|") }
    }

    // MARK: Family weekly challenge

    /// Passed quizzes in the current week (`calendar`'s first weekday), for
    /// the family challenge card. Shown only when the parent enabled it
    /// (`FamilyChallengeSettings`, off by default).
    static func passedQuizzesThisWeek(attempts: [AttemptSnapshot], now: Date, calendar: Calendar) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return attempts.filter { $0.passed && week.contains($0.date) }.count
    }
}
