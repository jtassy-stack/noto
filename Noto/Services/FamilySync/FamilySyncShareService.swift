@preconcurrency import CloudKit
import CoreTransferable
import Foundation
import Observation

/// Family sync (phase 9.2): the CloudKit side of linking. The parent creates
/// one zone per child in their private database and shares the whole zone
/// (`CKShare(recordZoneID:)`) with the child's device; the child's device
/// accepts it. No record is written here: the sync engine comes in 9.3.
///
/// Only call this when `FamilySyncLink.isEnabled()` is true:
/// `CKContainer(identifier:)` traps without the iCloud entitlement.
@MainActor
enum FamilySyncShareService {
    static var container: CKContainer { CKContainer(identifier: FamilySyncLink.containerIdentifier) }

    private static func ownZoneID(_ zoneName: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private static func shareID(_ zoneName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZoneID(zoneName))
    }

    // MARK: Parent side

    /// The zone-wide share for this zone, created with the zone on first use.
    /// The share title stays generic: CloudKit shows it in the invitation and
    /// it must never carry the child's name.
    static func share(zoneName: String) async throws -> CKShare {
        let database = container.privateCloudDatabase
        if let existing = try await existingShare(zoneName: zoneName) { return existing }

        let zoneID = ownZoneID(zoneName)
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "nōto" as CKRecordValue
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else {
            throw CKError(.internalError)
        }
        return saved
    }

    /// True once a participant other than the parent accepted the share.
    static func childHasAccepted(zoneName: String) async throws -> Bool {
        guard let share = try await existingShare(zoneName: zoneName) else { return false }
        return share.participants.contains { $0.role != .owner && $0.acceptanceStatus == .accepted }
    }

    /// Unlink: deleting the zone deletes its share, so the child's device
    /// loses access, and every record synced into it.
    static func deleteZone(zoneName: String) async throws {
        do {
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: ownZoneID(zoneName))
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone.
        }
    }

    /// The child is being removed from the parent's device: revoke the
    /// child's access now, or at a later launch if CloudKit is unreachable.
    /// Queued before trying, so the zone name survives the `Child`. Zones the
    /// parent does not own (child device) are left alone.
    static func revokeOnChildRemoval(_ child: Child) {
        guard FamilySyncLink.isEnabled(), child.familySyncZoneOwner == nil,
              let zoneName = child.familySyncZoneName else { return }
        FamilySyncLink.addPendingDeletion(zoneName)
        FamilySyncStateStore().clear(zoneName: zoneName)
        Task { await retryPendingDeletions() }
    }

    static func retryPendingDeletions() async {
        guard FamilySyncLink.isEnabled() else { return }
        for zoneName in FamilySyncLink.pendingDeletions() {
            do {
                try await deleteZone(zoneName: zoneName)
                FamilySyncLink.removePendingDeletion(zoneName)
            } catch {
                NSLog("[noto][warn] family sync: deleting a removed child's zone failed, retrying at next launch: %@",
                      error.localizedDescription)
            }
        }
    }

    private static func existingShare(zoneName: String) async throws -> CKShare? {
        do {
            return try await container.privateCloudDatabase.record(for: shareID(zoneName)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    // MARK: Child side

    struct AcceptedZone: Equatable, Sendable {
        let zoneName: String
        let ownerName: String
    }

    enum AcceptError: Error {
        case notAFamilyInvitation
    }

    /// Accepts an invitation opened on the child's device, after checking it
    /// is one of ours.
    static func accept(_ metadata: CKShare.Metadata) async throws -> AcceptedZone {
        let zoneID = metadata.share.recordID.zoneID
        guard FamilySyncLink.isAcceptable(containerIdentifier: metadata.containerIdentifier,
                                          zoneName: zoneID.zoneName,
                                          shareRecordName: metadata.share.recordID.recordName) else {
            throw AcceptError.notAFamilyInvitation
        }
        _ = try await CKContainer(identifier: metadata.containerIdentifier).accept(metadata)
        return AcceptedZone(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
    }
}

/// What the parent shares with `ShareLink`: the system sheet sends the
/// CloudKit invitation (Messages, AirDrop…) to the child's device. Invited
/// recipients only, read-write (the child's device writes its results).
struct FamilyShareItem: Transferable {
    let zoneName: String

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation<FamilyShareItem> { item in
            .prepareShare(
                container: CKContainer(identifier: FamilySyncLink.containerIdentifier),
                allowedSharingOptions: CKAllowedSharingOptions(
                    allowedParticipantPermissionOptions: .readWrite,
                    allowedParticipantAccessOptions: .specifiedRecipientsOnly
                )
            ) {
                try await FamilySyncShareService.share(zoneName: item.zoneName)
            }
        }
    }
}

/// Invitations opened on this device, handed over by `NotoSceneDelegate` and
/// confirmed in `RootView` before anything is accepted.
@MainActor
@Observable
final class FamilySyncInbox {
    static let shared = FamilySyncInbox()

    var pending: CKShare.Metadata?

    func receive(_ metadata: CKShare.Metadata) {
        guard FamilySyncLink.isEnabled() else { return }
        pending = metadata
    }
}
