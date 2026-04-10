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
