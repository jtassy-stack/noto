import Foundation
import SwiftData

/// Main-actor glue between the SwiftData models and the pure parent-side
/// reports (`RevisionSummary`, `RevisionBriefingItem`, `RevisionSuggestion`).
@MainActor
enum RevisionReportStore {
    static func summary(for child: Child, now: Date = Date(), calendar: Calendar = .current) -> RevisionSummary {
        RevisionSummary.build(
            attempts: GamificationStore.attempts(of: child),
            masteries: child.notionMasteries.map { MasterySnapshot($0) },
            streakDays: GamificationStore.streak(for: child, now: now, calendar: calendar).days,
            now: now, calendar: calendar
        )
    }

    static func examTomorrow(for child: Child, now: Date, calendar: Calendar) -> Bool {
        ExamKeywordDetector.hasExamTomorrow(
            homework: child.homework.map { HomeworkSnapshot($0, calendar: calendar) },
            schedule: child.schedule.map { ScheduleSnapshot($0) },
            now: now, calendar: calendar
        )
    }

    static func briefingItem(for child: Child, now: Date = Date(),
                             calendar: Calendar = .current) -> RevisionBriefingItem? {
        RevisionBriefingItem.make(summary: summary(for: child, now: now, calendar: calendar),
                                  examTomorrow: examTomorrow(for: child, now: now, calendar: calendar),
                                  now: now, calendar: calendar)
    }

    /// First names of the children who revised on this device in the last 30 days.
    static func activeChildNames(_ children: [Child], now: Date = Date(),
                                 calendar: Calendar = .current) -> [String] {
        children.filter { summary(for: $0, now: now, calendar: calendar).isActive }.map(\.firstName)
    }

    /// Re-schedules (or removes) the weekly notification. Called on launch /
    /// foreground and when the parent flips the toggle.
    static func syncWeeklyNotification(children: [Child],
                                       defaults: UserDefaults = .standard) async {
        // Same default as the `@AppStorage` toggle in Réglages: on.
        let enabled = defaults.object(forKey: WeeklyRevisionNotification.enabledKey) as? Bool ?? true
        await NotificationService.shared.syncWeeklyRevisionSummary(childNames: activeChildNames(children),
                                                                   enabled: enabled)
    }
}
