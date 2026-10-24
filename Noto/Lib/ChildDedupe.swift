import Foundation

/// Pure lookup helpers that resolve whether a `PronoteChildResource`
/// (or a synthetic fallback) already has a corresponding `Child` row
/// inside a `Family`.
///
/// Replaces the previous behavior of blindly inserting a new Child
/// every time the parent re-runs QR login, which compounded duplicates
/// silently.
///
/// Strategy (highest precedence first):
///   1. Match on `pawnoteID` — the identifier returned by pawnote.
///      Stable across re-logins, immune to firstName edits.
///   2. Fallback composite `(firstName, schoolType)` — used when the
///      existing row predates the pawnoteID field (first run after
///      upgrade) or for synthetic fallback children.
///
/// Composite matching is case-insensitive on `firstName` so that a
/// parent editing casing in Settings does not break the link. School
/// type narrows the scope so an ENT and a Pronote child with the same
/// first name remain distinct rows.
enum ChildDedupe {

    /// Returns the existing `Child` in `existing` that should be reused
    /// for the given pawnote-sourced input, or `nil` if none matches.
    static func match(
        in existing: [Child],
        pawnoteID: String?,
        firstName: String,
        schoolType: SchoolType
    ) -> Child? {
        // Primary: pawnoteID identity. Only trust a non-empty id — an
        // empty string coming out of the JS bridge is a "missing" sentinel,
        // not a valid key, and would otherwise match every other row that
        // also has an empty string.
        if let pawnoteID, !pawnoteID.isEmpty {
            if let hit = existing.first(where: { $0.pawnoteID == pawnoteID }) {
                return hit
            }
        }

        // Fallback composite. Scoped to schoolType so a pronote Gaston
        // and an ent Gaston stay independent. Rows that already carry a
        // real (non-empty) pawnoteID are skipped entirely — they're
        // claimed by a specific kid and the composite path must not
        // silently overwrite them with a synthetic or mis-identified one.
        let normalizedName = firstName.lowercased()
        return existing.first { child in
            guard child.schoolType == schoolType else { return false }
            guard child.firstName.lowercased() == normalizedName else { return false }
            if let existingID = child.pawnoteID, !existingID.isEmpty {
                return false
            }
            return true
        }
    }

    /// Same purpose for a child listed by an ENT (MonLycée logbook, PCN
    /// roster): returns the row to reuse, or nil.
    ///
    ///   1. `entChildId` on the same provider — the ENT's own stable id.
    ///   2. A child with the same first name and no ENT id yet, on this
    ///      provider OR with no provider at all. The second case is the
    ///      MonLycée case: the ENT lists Gaston, and the Pronote session
    ///      opened through that same ENT also listed Gaston — one person,
    ///      so the ENT data attaches to the Pronote row instead of making
    ///      a second one. A row already claimed by another ENT id or by
    ///      another provider is never reused.
    static func matchENT(
        in existing: [Child],
        entChildId: String?,
        firstName: String,
        provider: ENTProvider
    ) -> Child? {
        if let entChildId, !entChildId.isEmpty,
           let hit = existing.first(where: { $0.entProvider == provider && $0.entChildId == entChildId }) {
            return hit
        }
        let normalizedName = firstName.lowercased()
        return existing.first { child in
            guard child.firstName.lowercased() == normalizedName else { return false }
            guard child.entProvider == nil || child.entProvider == provider else { return false }
            if let existingID = child.entChildId, !existingID.isEmpty { return false }
            return true
        }
    }
}
