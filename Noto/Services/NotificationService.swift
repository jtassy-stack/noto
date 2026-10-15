import UserNotifications
import Foundation

@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Homework Reminder

    /// Planifie une notification locale la veille à 8h00 pour un devoir à rendre.
    func scheduleHomeworkReminder(childName: String, subject: String, dueDate: Date) async {
        let center = UNUserNotificationCenter.current()

        guard let reminderDate = Calendar.current.date(byAdding: .day, value: -1, to: dueDate) else { return }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: reminderDate)
        components.hour = 8
        components.minute = 0
        components.second = 0

        let content = UNMutableNotificationContent()
        content.title = "Devoir à rendre demain"
        content.body = "\(childName) a un devoir de \(subject) à rendre demain."
        content.sound = .default
        content.threadIdentifier = "homework.\(childName)"

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "homework.\(childName).\(subject).\(reminderDate.timeIntervalSince1970)"

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    // MARK: - Difficulty Alert

    /// Planifie une notification immédiate quand le ML détecte une difficulté.
    func scheduleDifficultyAlert(childName: String, subject: String) async {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Difficulté détectée"
        content.body = "\(childName) rencontre des difficultés en \(subject). Pensez à vérifier ses notes récentes."
        content.sound = .default
        content.threadIdentifier = "difficulty.\(childName)"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = "difficulty.\(childName).\(subject).\(Date().timeIntervalSince1970)"

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    // MARK: - Carnet à signer

    /// Planifie une notification immédiate quand un nouveau mot du carnet de liaison arrive.
    func scheduleCarnetNotification(for child: Child, subject: String, wordId: String?) async {
        // Check user preference
        guard UserDefaults.standard.bool(forKey: "notif_carnet") else { return }

        // Deduplicate: only notify for genuinely new words
        if let wordId, hasAlreadyNotified(wordId: wordId) { return }
        if let wordId { markNotified(wordId: wordId) }

        let content = UNMutableNotificationContent()
        content.title = "Carnet de liaison — \(child.firstName)"
        content.body = subject.isEmpty ? "Un nouveau mot est à signer." : subject
        content.sound = .default
        content.categoryIdentifier = "CARNET"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let id = "carnet_\(child.id)_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        try? await UNUserNotificationCenter.current().add(request)
    }

    private func hasAlreadyNotified(wordId: String) -> Bool {
        let existing = UserDefaults.standard.stringArray(forKey: "notified_carnets") ?? []
        return existing.contains(wordId)
    }

    private func markNotified(wordId: String) {
        var existing = UserDefaults.standard.stringArray(forKey: "notified_carnets") ?? []
        existing.append(wordId)
        if existing.count > 200 { existing = Array(existing.suffix(200)) }
        UserDefaults.standard.set(existing, forKey: "notified_carnets")
    }

    // MARK: - Weekly revision summary (3.7)

    /// Keeps the weekly « Révisions » notification in line with the toggle,
    /// the device mode and the permission. Never asks for permission (the
    /// Notifications section of Réglages owns that flow); idempotent (fixed
    /// identifier, re-adding replaces), so it is safe on every foreground.
    /// See `WeeklyRevisionNotification` for why the body is generic.
    func syncWeeklyRevisionSummary(childNames: [String], enabled: Bool,
                                   mode: DeviceMode = DeviceMode.current) async {
        let center = UNUserNotificationCenter.current()
        let status = await authorizationStatus()
        guard WeeklyRevisionNotification.shouldSchedule(enabled: enabled, mode: mode,
                                                        childNames: childNames, status: status) else {
            center.removePendingNotificationRequests(withIdentifiers: [WeeklyRevisionNotification.identifier])
            return
        }
        try? await center.add(WeeklyRevisionNotification.makeRequest(childNames: childNames))
    }

    // MARK: - Cancel

    /// Annule toutes les notifications en attente pour un enfant donné.
    func cancelAll(for childName: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending
            .filter { $0.identifier.hasPrefix("homework.\(childName).") || $0.identifier.hasPrefix("difficulty.\(childName).") }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: toRemove)
    }
}

// MARK: - Weekly revision notification (pure builder)

/// Sunday 19:00 local notification for the weekly revision summary.
///
/// Approach (simplest correct one, no push server, no background task):
/// a single repeating `UNCalendarNotificationTrigger` (weekday 1 = Sunday in
/// the Gregorian calendar, 19:00) with a **generic** body. Its content cannot
/// be computed at delivery time: the app does not run then, and nōto has no
/// background refresh (`BGAppRefreshTask` was rejected, see
/// `ClassScheduleShieldService`). The figures and the adjustment suggestion
/// (`RevisionSummary`, `RevisionSuggestion`) are computed live when the parent
/// opens Réglages › Révisions.
///
/// Scheduled only when: the parent toggle is on, the device is in parent mode
/// (the copy addresses the parent; a child must not receive « Votre
/// enfant… » on their own phone), at least one child on this device revised in
/// the last 30 days, and notifications are authorized (or provisional).
///
/// V1 limitation: quizzes are only played in child mode (`ChildHomeView`) and
/// attempts are not synced, so no device meets both conditions yet; the
/// Réglages toggle is hidden until it can (`SettingsView.weeklyRevisionsAvailable`).
enum WeeklyRevisionNotification {
    static let identifier = "revisions.weekly"
    static let enabledKey = "notif_weekly_revisions"
    /// Gregorian weekday: 1 = Sunday.
    static let weekday = 1
    static let hour = 19

    static func dateComponents() -> DateComponents {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        return components
    }

    static func shouldSchedule(enabled: Bool, mode: DeviceMode, childNames: [String],
                               status: UNAuthorizationStatus) -> Bool {
        guard enabled, mode == .parent, !childNames.isEmpty else { return false }
        return status == .authorized || status == .provisional
    }

    /// Parent tone (vouvoiement), no figures (see the type comment).
    static func content(childNames: [String]) -> (title: String, body: String) {
        let names = childNames.filter { !$0.isEmpty }
        let who: String
        switch names.count {
        case 0: who = "de votre enfant"
        case 1: who = "de \(names[0])"
        default: who = "de " + names.dropLast().joined(separator: ", ") + " et " + names[names.count - 1]
        }
        return ("Bilan hebdo des révisions",
                "Le bilan de la semaine \(who) est prêt, avec une suggestion de réglage si besoin : "
                    + "Réglages › Révisions.")
    }

    static func makeRequest(childNames: [String]) -> UNNotificationRequest {
        let text = content(childNames: childNames)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = "revisions.weekly"
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents(), repeats: true)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}
