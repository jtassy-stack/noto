import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "PronoteImport")

/// Turns the roster of a freshly opened Pronote session into `Child` rows
/// and runs their first sync. Shared by the QR login and the ENT web login
/// so both dedupe the same way: a parent who reconnects must not get a
/// second « Gaston ».
@MainActor
enum PronoteChildImporter {

    /// Creates or refreshes one `Child` per pawnote resource (synthetic
    /// child on the parent username when the roster is empty), deduped
    /// through `ChildDedupe`. Saves the context. Returns the children in
    /// roster order — the index is the pawnote child index for `sync`.
    static func importChildren(
        from bridge: PawnoteBridge,
        token: PronoteRefreshToken,
        family: Family,
        modelContext: ModelContext
    ) throws -> [Child] {
        let pronoteChildren = bridge.getChildren()
        var resolved: [Child] = []

        for pc in pronoteChildren {
            let nameParts = pc.name.split(separator: " ")
            let firstName = nameParts.count > 1
                ? String(nameParts.dropFirst().joined(separator: " "))
                : pc.name

            if let existing = ChildDedupe.match(
                in: family.children,
                pawnoteID: pc.id,
                firstName: firstName,
                schoolType: .pronote
            ) {
                // Refresh what may have moved on the school side (grade at
                // the year roll-over, establishment rename). firstName is
                // deliberately kept: the parent may have edited it.
                existing.level = GradeInference.level(from: pc.className)
                existing.grade = GradeInference.grade(from: pc.className)
                existing.establishment = token.url
                if existing.pawnoteID == nil || existing.pawnoteID?.isEmpty == true {
                    existing.pawnoteID = pc.id
                }
                resolved.append(existing)
                continue
            }

            let child = Child(
                firstName: firstName,
                level: GradeInference.level(from: pc.className),
                grade: GradeInference.grade(from: pc.className),
                schoolType: .pronote,
                establishment: token.url,
                pawnoteID: pc.id.isEmpty ? nil : pc.id
            )
            child.family = family
            modelContext.insert(child)
            resolved.append(child)
        }

        if pronoteChildren.isEmpty {
            // No listed resource (single-child parent space, or a student
            // login): one synthetic child on the username. Empty grade, not
            // "?", so CurriculumService never stores a corrupt value.
            logger.warning("Pronote login returned no children; synthetic child for \(token.username, privacy: .private)")
            if let existing = ChildDedupe.match(
                in: family.children,
                pawnoteID: nil,
                firstName: token.username,
                schoolType: .pronote
            ) {
                existing.establishment = token.url
                resolved.append(existing)
            } else {
                let child = Child(
                    firstName: token.username,
                    level: .college,
                    grade: "",
                    schoolType: .pronote,
                    establishment: token.url
                )
                child.family = family
                modelContext.insert(child)
                resolved.append(child)
            }
        }

        try modelContext.save()
        return resolved
    }

    /// First sync of the children this login listed, with bridge-local
    /// indices, through the coordinator. A partial failure (a school that
    /// blocks one endpoint) is not fatal: rows and token are already saved
    /// and the missing sections retry on the next cycle.
    /// Returns true when at least one child had a failed category.
    static func initialSync(
        children: [Child],
        bridge: PawnoteBridge,
        modelContext: ModelContext
    ) async -> Bool {
        let syncService = PronoteSyncService(modelContext: modelContext)
        var hadPartialFailure = false
        await SyncCoordinator.shared.requestSync(force: true) {
            for (index, child) in children.enumerated() {
                await syncService.sync(child: child, bridge: bridge, childIndex: index)
                if !syncService.failedCategories.isEmpty {
                    hadPartialFailure = true
                    let childName = child.firstName
                    let missing = syncService.failedCategories.joined(separator: ", ")
                    logger.warning("Partial sync during onboarding for \(childName, privacy: .private): missing \(missing, privacy: .public)")
                }
            }
        }
        return hadPartialFailure
    }
}
