import Foundation

/// Resolves a SwiftData `Child` to its index inside the current pawnote
/// session's child resource list.
///
/// Why this exists: `bridge.setActiveChild(index:)` takes a bridge-local
/// index, not a SwiftData row number. Code that iterates a filtered
/// `[Child]` with `.enumerated()` and passes that index to `sync` ends up
/// writing one kid's grades onto another kid whenever the SwiftData order
/// diverges from the pawnote login order (re-order, delete + re-add,
/// multi-child households on their second re-login).
///
/// Strategy:
///   1. Primary — match on `Child.pawnoteID` against `PronoteChildResource.id`.
///      Immune to firstName edits; only works for rows logged-in
///      post-P2 dedupe backfill.
///   2. Fallback — re-apply the same `pc.name → firstName` transform
///      used at onboarding (drop the first whitespace-separated token,
///      i.e. the LASTNAME), case-insensitive compare. Covers legacy
///      rows that still have a nil `pawnoteID` until their first
///      post-upgrade re-login backfills it.
///
/// Returns `nil` when neither path matches — the caller must decide
/// how to surface that (HomeView skips + logs so a missing child
/// never writes data to a wrong row).
enum ChildIndexResolver {

    static func resolve(
        child: Child,
        pawnoteChildren: [PronoteChildResource]
    ) -> Int? {
        // Primary: pawnoteID identity. Empty string is a bridge sentinel,
        // not a valid id — ignore it the same way ChildDedupe does.
        if let stored = child.pawnoteID, !stored.isEmpty {
            if let hit = pawnoteChildren.firstIndex(where: { $0.id == stored }) {
                return hit
            }
            // Stored id didn't match — the pawnote session probably lost
            // this kid (school removed the child resource). Fall through
            // to name matching rather than silently returning nil.
        }

        // Fallback: firstName match. Apply the same transform used at
        // onboarding so "DUPONT Gaston" resolves to "Gaston".
        let target = child.firstName.lowercased()
        return pawnoteChildren.firstIndex { pc in
            firstName(from: pc.name).lowercased() == target
        }
    }

    /// Pawnote returns `"LASTNAME Firstname"` — onboarding drops the
    /// first whitespace-separated token to get the parent-facing name.
    /// This helper re-applies the same transform so resolution stays
    /// consistent across onboarding and refresh.
    static func firstName(from pawnoteName: String) -> String {
        let parts = pawnoteName.split(separator: " ")
        guard parts.count > 1 else { return pawnoteName }
        return parts.dropFirst().joined(separator: " ")
    }
}
