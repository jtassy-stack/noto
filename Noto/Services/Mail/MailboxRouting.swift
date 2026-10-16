import Foundation

/// Pure routing rules for `MailboxAssignment` — which children (or the
/// parent lane) receive an IMAP account's mail, how an assignment reads in
/// the UI, and what happens when the assigned child disappears.
///
/// Everything here takes plain arrays and closures (no Keychain, no
/// SwiftData fetch) so the rules are unit-testable in isolation.
enum MailboxRouting {

    /// Where an account's fetched mail is replayed.
    enum Target<C> {
        /// Process the batch once per child, each with its own whitelist.
        case children([C])
        /// Process the batch once against the family (parent) lane.
        case parent
    }

    /// Persisted reference to a child — the string form of its SwiftData
    /// `PersistentIdentifier`, same convention as
    /// `ScreenTimeEventStore.storeLinkedChildID` / `BriefingEngine`.
    static func childKey(_ child: Child) -> String {
        "\(child.id)"
    }

    /// Resolves an assignment against the family's children.
    ///
    /// - Parameters:
    ///   - children: every child of the family — the universe an explicit
    ///     `.child(id:)` is matched against.
    ///   - defaultChildren: who receives an `.allChildren` account. Defaults
    ///     to `children`; Actualités narrows it to Pronote children (its
    ///     historical behaviour) while an explicit choice is always honoured.
    ///   - key: the child's persisted id (`childKey` in production).
    static func target<C>(
        for assignment: MailboxAssignment,
        children: [C],
        defaultChildren: [C]? = nil,
        key: (C) -> String
    ) -> Target<C> {
        let ids = children.map(key)
        switch assignment.resolved(childIDs: ids) {
        case .allChildren:
            return .children(defaultChildren ?? children)
        case .child(let id):
            return .children(children.filter { key($0) == id })
        case .parent:
            return .parent
        }
    }

    /// Whether a lane may keep an account's rows under `assignment` — the
    /// lane being a child (`childID`) or the parent lane (`nil`).
    ///
    /// Deliberately independent of `target`'s `defaultChildren`: Actualités
    /// narrows "Tous les enfants" to Pronote children while École uses
    /// every child, and reconciliation must not ping-pong between the two.
    /// Any child is a legitimate home under "Tous"; only the parent lane is
    /// stale there.
    static func laneAccepts(
        _ assignment: MailboxAssignment,
        childID: String?,
        allChildIDs: [String]
    ) -> Bool {
        switch assignment.resolved(childIDs: allChildIDs) {
        case .allChildren: return childID != nil
        case .child(let id): return childID == id
        case .parent: return childID == nil
        }
    }

    /// Stored rows can only be traced back to an account through their
    /// `imapProvider` tag, which is per provider, not per account. Moving
    /// rows between lanes is only safe when exactly one configured account
    /// uses that provider — two Gmail boxes with different assignments are
    /// indistinguishable once stored.
    static func canReconcile(providerID: String, configs: [IMAPServerConfig]) -> Bool {
        configs.filter { $0.providerID == providerID }.count == 1
    }

    /// Accounts that pointed at `removedChildID` fall back to "Tous les
    /// enfants". Order and every other field are preserved.
    static func repairingOrphans(
        _ configs: [IMAPServerConfig],
        removedChildID: String
    ) -> [IMAPServerConfig] {
        configs.map { config in
            guard config.assignment == .child(id: removedChildID) else { return config }
            var repaired = config
            repaired.assignment = .allChildren
            return repaired
        }
    }

    static let allChildrenLabel = "Tous les enfants"
    static let parentLabel = "Parent"

    /// Label shown in Réglages for an account. A dangling child id reads
    /// "Tous les enfants" — what the sync actually does with it.
    static func label(
        for assignment: MailboxAssignment,
        children: [(id: String, firstName: String)]
    ) -> String {
        switch assignment.resolved(childIDs: children.map(\.id)) {
        case .allChildren:
            return allChildrenLabel
        case .child(let id):
            return children.first { $0.id == id }?.firstName ?? allChildrenLabel
        case .parent:
            return parentLabel
        }
    }

    /// Whether a monlycee.net IMAP account already delivers the inbox the
    /// ENT SSO channel (`MonLyceeMailService`) would import for `childID`.
    /// "One inbox, one fetcher": the SSO channel steps aside for that child
    /// unless every monlycee.net IMAP account is explicitly assigned to a
    /// *different* child. A parent-assigned account still counts — it is
    /// the same inbox, and importing it twice (parent lane + child) would
    /// duplicate every mail.
    static func imapCoversMonLyceeInbox(
        forChildID childID: String,
        allChildIDs: [String],
        configs: [IMAPServerConfig],
        monLyceeProviderID: String
    ) -> Bool {
        configs.contains { config in
            guard config.providerID == monLyceeProviderID else { return false }
            switch config.assignment.resolved(childIDs: allChildIDs) {
            case .allChildren, .parent: return true
            case .child(let id): return id == childID
            }
        }
    }
}
