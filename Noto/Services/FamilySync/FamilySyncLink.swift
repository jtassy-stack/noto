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
}
