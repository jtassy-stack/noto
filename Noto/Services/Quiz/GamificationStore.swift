import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "GamificationStore")

/// Main-actor glue between the SwiftData models and the pure `Gamification`:
/// builds the snapshots, and persists the jokers `Gamification.streak` spends.
@MainActor
enum GamificationStore {
    static func attempts(of child: Child) -> [AttemptSnapshot] {
        child.quizAttempts.map { AttemptSnapshot($0) }
    }

    static func jokerDays(of child: Child) -> [CalendarDay] {
        child.streakJokers.compactMap(\.day)
    }

    /// Current série with the persisted jokers. Read-only: the gap jokers are
    /// applied to the figures but stay pending (safe from a view `body`).
    static func streak(for child: Child, now: Date, calendar: Calendar) -> StreakStatus {
        Gamification.streak(attempts: attempts(of: child), jokers: jokerDays(of: child),
                            now: now, calendar: calendar)
    }

    /// Spends (persists) the gap jokers, idempotently (a day already covered
    /// is never stored twice), and only once a passed quiz closed the gap:
    /// while today has no passed quiz they stay pending, so a child who skips
    /// today too burns nothing (`Gamification` série rules). Called from
    /// `QuizSession.finish` with the attempt being saved (`attempts`, since
    /// `child.quizAttempts` may not list it before the save, and `save: false`
    /// to share the attempt's save); the child home calls it again as a
    /// safety net. Returns the série.
    @discardableResult
    static func recordDueJokers(for child: Child, attempts override: [AttemptSnapshot]? = nil,
                                in context: ModelContext, now: Date, calendar: Calendar,
                                save: Bool = true) -> StreakStatus {
        let history = override ?? Self.attempts(of: child)
        let status = Gamification.streak(attempts: history, jokers: jokerDays(of: child),
                                         now: now, calendar: calendar)
        let today = CalendarDay(now, calendar: calendar)
        guard Gamification.playedDays(attempts: history, calendar: calendar).contains(today) else {
            return status
        }
        let existing = Set(child.streakJokers.map(\.dayKey))
        let fresh = status.newJokers.filter { !existing.contains($0.key) }
        guard !fresh.isEmpty else { return status }
        for day in fresh {
            let joker = StreakJoker(child: child, day: day, createdAt: now)
            context.insert(joker)
        }
        guard save else { return status }
        do {
            try context.save()
        } catch {
            logger.error("Saving streak jokers failed: \(error.localizedDescription, privacy: .public)")
        }
        return status
    }

    static func subjectXP(of child: Child) -> [SubjectXP] {
        Gamification.subjectXP(attempts: attempts(of: child))
    }

    static func badges(for child: Child, now: Date, calendar: Calendar,
                       curriculum: some CurriculumLookup) -> [EarnedBadge] {
        let history = Self.attempts(of: child)
        let status = Gamification.streak(attempts: history, jokers: jokerDays(of: child),
                                         now: now, calendar: calendar)
        return Gamification.badges(attempts: history,
                                   masteries: child.notionMasteries.map { MasterySnapshot($0) },
                                   jokers: jokerDays(of: child) + status.newJokers,
                                   level: child.grade, specialties: child.specialties,
                                   curriculum: curriculum, calendar: calendar)
    }
}
