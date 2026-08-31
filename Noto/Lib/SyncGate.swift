import Foundation

/// Shared decision logic for "should this sync wipe local data?", used by
/// every fetch-all-then-wipe-and-insert sync service (École Directe, ENT,
/// Skolengo). Prevents a transient empty/failed fetch from silently
/// deleting data that was already synced successfully.
enum SyncGate {
    enum Decision: Equatable {
        /// Fresh data arrived — safe to wipe local rows and insert new ones.
        case proceed
        /// No data and no errors — treat as a no-op to avoid losing local state.
        case preserve
        /// No data and at least one error — fail loudly so the caller can retry.
        case fail(String)
    }

    static func decide(hasData: Bool, fetchErrors: [String]) -> Decision {
        if hasData { return .proceed }
        if !fetchErrors.isEmpty { return .fail(fetchErrors.joined(separator: ", ")) }
        return .preserve
    }
}
