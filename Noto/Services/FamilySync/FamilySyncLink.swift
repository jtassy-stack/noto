import CloudKit
import Foundation

/// Family sync (phase 9.2): linking a child's phone to the parent's. Pure:
/// the flag, the zone name and the link state. The CloudKit calls live in
/// `FamilySyncShareService`.
///
/// The parent owns one CloudKit zone per child in their private database and
/// shares it with the child's device (read-write, invited recipients only).
/// The zone name is random and opaque (CloudKit keeps it in clear): it never
/// carries the child's name or an id from the school.
enum FamilySyncLink {
    static let containerIdentifier = "iCloud.fr.noto.app"
    static let zonePrefix = "enfant-"
    static let infoPlistKey = "NotoFamilySyncEnabled"

    /// Off until the iCloud container exists and the app carries the iCloud
    /// entitlement: `CKContainer(identifier:)` traps without it, so nothing
    /// touches CloudKit while this is false. Set by `FAMILY_SYNC_ENABLED` in
    /// the xcconfig.
    static func isEnabled(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        guard let value = info?[infoPlistKey] as? String else { return false }
        return ["YES", "TRUE", "1"].contains(value.uppercased())
    }

    static func makeZoneName() -> String {
        zonePrefix + UUID().uuidString.lowercased()
    }

    /// A zone nōto created: « enfant-<uuid> ». Anything else in a share is
    /// refused.
    static func isFamilyZone(_ name: String) -> Bool {
        guard name.hasPrefix(zonePrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count))) != nil
    }

    /// An invitation the child's device may accept: our container, a zone
    /// nōto created, and a zone-wide share (never a share of one record).
    static func isAcceptable(containerIdentifier: String, zoneName: String, shareRecordName: String) -> Bool {
        containerIdentifier == Self.containerIdentifier
            && isFamilyZone(zoneName)
            && shareRecordName == CKRecordNameZoneWideShare
    }

    // MARK: Pending zone deletions

    /// Zones the parent's device still has to delete: a linked child was
    /// removed from this device while CloudKit was unreachable. Kept apart
    /// from SwiftData because the `Child` is gone; the names are opaque.
    static let pendingDeletionsKey = "familySync.pendingZoneDeletions"

    static func pendingDeletions(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: pendingDeletionsKey) ?? []).filter(isFamilyZone)
    }

    static func addPendingDeletion(_ zoneName: String, _ defaults: UserDefaults = .standard) {
        guard isFamilyZone(zoneName) else { return }
        var names = pendingDeletions(defaults)
        if !names.contains(zoneName) { names.append(zoneName) }
        defaults.set(names, forKey: pendingDeletionsKey)
    }

    static func removePendingDeletion(_ zoneName: String, _ defaults: UserDefaults = .standard) {
        defaults.set(pendingDeletions(defaults).filter { $0 != zoneName }, forKey: pendingDeletionsKey)
    }

    enum State: Equatable, Sendable {
        /// No zone yet.
        case notLinked
        /// Parent side: the zone is named, the child's device has not
        /// accepted the invitation yet.
        case invited
        /// The child's device accepted the invitation.
        case linked(since: Date)
    }

    static func state(zoneName: String?, linkedAt: Date?) -> State {
        guard let zoneName, isFamilyZone(zoneName) else { return .notLinked }
        if let linkedAt { return .linked(since: linkedAt) }
        return .invited
    }

    // MARK: - Copy

    /// Parent side (vouvoiement).
    static func parentStatus(_ state: State, firstName: String, calendar: Calendar) -> String {
        switch state {
        case .notLinked:
            return "Le téléphone de \(firstName) n'est pas relié à celui-ci."
        case .invited:
            return "En attente : ouvrez l'invitation sur le téléphone de \(firstName) pour le relier."
        case .linked(let since):
            return "Le téléphone de \(firstName) est relié depuis le \(dayText(since, calendar: calendar))."
        }
    }

    static func parentExplanation(firstName: String) -> String {
        "Les quiz, les notions, la série et les minutes gagnées par \(firstName) s'afficheront ici. "
            + "Vos règles de récompense s'appliqueront sur son téléphone. "
            + "Tout est chiffré de bout en bout dans votre iCloud : nōto ne voit rien, "
            + "et ni les messages, ni les notes, ni les photos ne passent par là."
    }

    /// Child side (tutoiement): shown before accepting, so the child knows
    /// what their parents will see.
    static let childConfirmTitle = "Relier ton téléphone à celui de tes parents ?"
    static let parentDeviceInvitationTitle = "Invitation pour le téléphone de votre enfant"
    static let parentDeviceInvitationMessage = "Ouvrez ce lien sur le téléphone de votre enfant, dans nōto en mode enfant."
    static let childAcceptFailed = "Impossible de relier ton téléphone pour l'instant. Vérifie que tu es connecté à iCloud, puis rouvre l'invitation."

    static let childConfirmMessage = "Ils verront tes quiz, tes notions, ta série et tes minutes gagnées. "
        + "Tes messages et tes notes restent sur ton téléphone."

    static func dayText(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.wide)
        style.timeZone = calendar.timeZone
        return style.format(date)
    }

    // MARK: - Sync status (phase 9.4)

    /// « il y a 5 min », « hier à 21h30 », « le 12 octobre ».
    static func relativeText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "à l'instant" }
        if elapsed < 3600 { return "il y a \(Int(elapsed / 60)) min" }
        let time = String(format: "%dh%02d", calendar.component(.hour, from: date),
                          calendar.component(.minute, from: date))
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd'hui à \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier à \(time)"
        }
        return "le \(dayText(date, calendar: calendar))"
    }

    /// This device's last sync (« Relier le téléphone », the child's Réglages).
    static func syncedText(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Pas encore synchronisé" }
        return "Synchronisé " + relativeText(date, now: now, calendar: calendar)
    }

    /// Parent side: how fresh the child's data is, from when the child's
    /// phone last sent something (`Child.familySyncReceivedAt`), not from
    /// the parent's own poll.
    static func receivedText(_ date: Date?, firstName: String, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Rien reçu du téléphone de \(firstName) pour l'instant" }
        return "Dernières données du téléphone de \(firstName) : " + relativeText(date, now: now, calendar: calendar)
    }

    /// Parent side, linked, no quiz in the last 30 days (vouvoiement):
    /// waiting while the child's phone has sent nothing yet, then a plain
    /// « no quiz ».
    static func noRevisionsText(firstName: String, receivedAt: Date?) -> String {
        receivedAt == nil
            ? "Les révisions de \(firstName) s'afficheront ici après la prochaine synchronisation de son téléphone."
            : "\(firstName) n'a pas fait de quiz de révision ces 30 derniers jours."
    }

    static func noMinutesText(firstName: String, receivedAt: Date?) -> String {
        receivedAt == nil
            ? "Les minutes gagnées par \(firstName) s'afficheront ici après la prochaine synchronisation de son téléphone."
            : "\(firstName) n'a pas gagné de minutes avec les quiz ces 30 derniers jours."
    }

    /// Today's minutes earned during class, kept until the class block ends
    /// (the class lock is never lifted by them). Nil when none, or when the
    /// figures are from another day.
    static func reserveText(_ minutes: SyncedDayMinutes?, now: Date, calendar: Calendar) -> String? {
        guard let minutes, minutes.reserve > 0,
              minutes.day == RewardLedger.dayKey(for: now, calendar: calendar) else { return nil }
        return "\(minutes.reserve) min gagnées pendant les cours, gardées pour après les cours."
    }
}

extension Child {
    /// Parent's device, child's phone linked: quizzes, notions, jokers and
    /// minutes arrive from that phone (phase 9.3).
    var receivesFamilySync: Bool {
        familySyncZoneOwner == nil && familySyncZoneName != nil && familySyncLinkedAt != nil
    }
}
