@preconcurrency import BackgroundTasks
@preconcurrency import CloudKit
import Foundation
import SwiftData

/// Family sync (phase 9.3): moves the records between the two phones through
/// the child's shared zone. Runs at launch, on foreground and in a
/// background refresh, never on a push (no CloudKit subscription in V1).
///
/// - Child's device (the `Child` whose zone has an owner, i.e. the parent's
///   share): sends its quizzes, notions, jokers and day minutes, then applies
///   the parent's rules it fetches back.
/// - Parent's device (zones it owns): sends its rules, then writes what the
///   child sent into its own `Child` (`FamilySyncIngest`).
///
/// A record is sent again only when its content changed (`FamilySyncOutbox`);
/// fetching is incremental (CloudKit change token). Every record has a
/// single writer, so saves overwrite without merging.
///
/// Uses the plain async `CKDatabase` calls rather than `CKSyncEngine`: with
/// no push and one writer per record, a change token and a fingerprint per
/// record are the whole state.
@MainActor
enum FamilySyncEngine {
    static let backgroundTaskIdentifier = "fr.noto.app.familySync"
    /// Automatic triggers closer than this are skipped (foreground bursts).
    static let cooldown: TimeInterval = 60
    private static let batchSize = 200

    /// Set by `NotoApp` for the background refresh, which has no view.
    static var modelContainer: ModelContainer?

    private static var isRunning = false
    private static var lastRun: Date?

    static func sync(context: ModelContext, force: Bool = false, now: Date = .now) async {
        guard FamilySyncLink.isEnabled(), !isRunning else { return }
        if !force, let lastRun, now.timeIntervalSince(lastRun) < cooldown { return }
        isRunning = true
        lastRun = now
        defer { isRunning = false }

        let state = FamilySyncStateStore()
        let children = (try? context.fetch(FetchDescriptor<Child>())) ?? []
        for child in children {
            guard let zoneName = child.familySyncZoneName, FamilySyncLink.isFamilyZone(zoneName) else { continue }
            do {
                if let owner = child.familySyncZoneOwner {
                    try await syncChildDevice(child, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: owner),
                                              state: state)
                } else {
                    try await syncParentDevice(child, zoneID: CKRecordZone.ID(zoneName: zoneName,
                                                                              ownerName: CKCurrentUserDefaultName),
                                               context: context, state: state)
                }
                child.familySyncLastSyncedAt = .now
                try? context.save()
            } catch let error as CKError where FamilySyncEngine.isZoneGone(error) {
                zoneGone(child, zoneName: zoneName, context: context, state: state)
            } catch {
                NSLog("[noto][warn] family sync failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: Background refresh

    static func backgroundRefresh() async {
        guard let modelContainer else { return }
        await sync(context: modelContainer.mainContext, force: true)
        scheduleBackgroundRefresh()
    }

    /// Asks iOS for the next background refresh. Best effort: iOS decides
    /// when, and launch and foreground still sync.
    static func scheduleBackgroundRefresh() {
        guard FamilySyncLink.isEnabled() else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[noto][warn] family sync: background refresh not scheduled: %@", error.localizedDescription)
        }
    }

    // MARK: Sides

    private static func syncChildDevice(_ child: Child, zoneID: CKRecordZone.ID,
                                        state: FamilySyncStateStore) async throws {
        let database = FamilySyncShareService.container.sharedCloudDatabase
        let records = FamilySyncOutbox.childRecords(for: child, ledger: RewardLedgerStore.load())
        try await push(FamilySyncOutbox.pending(records, sent: state.sent(zoneName: zoneID.zoneName)),
                       zoneID: zoneID, database: database, state: state)

        let fetched = try await fetchChanges(zoneID: zoneID, database: database, state: state)
        for record in fetched.records where record.kind == .rules {
            FamilySyncRulesApplier.apply(record)
        }
        state.setChangeToken(fetched.token, zoneName: zoneID.zoneName)
    }

    private static func syncParentDevice(_ child: Child, zoneID: CKRecordZone.ID, context: ModelContext,
                                         state: FamilySyncStateStore) async throws {
        let database = FamilySyncShareService.container.privateCloudDatabase
        let rules = [SyncedRules.current().record]
        do {
            try await push(FamilySyncOutbox.pending(rules, sent: state.sent(zoneName: zoneID.zoneName)),
                           zoneID: zoneID, database: database, state: state)
        } catch let error as CKError where isZoneGone(error) && child.familySyncLinkedAt == nil {
            // Zone named but no invitation sent yet (`FamilyLinkView`
            // creates it with the share): nothing to sync.
            return
        }

        let fetched = try await fetchChanges(zoneID: zoneID, database: database, state: state)
        let result = FamilySyncIngest.apply(fetched.records, to: child, context: context)
        if let minutes = result.minutes { state.setReceivedMinutes(minutes, zoneName: zoneID.zoneName) }
        state.addIngestedIDs(result.insertedIDs, zoneName: zoneID.zoneName)
        if !result.isEmpty, child.familySyncLinkedAt == nil { child.familySyncLinkedAt = .now }
        if let latest = fetched.latestChildChange,
           child.familySyncReceivedAt.map({ latest > $0 }) ?? true {
            child.familySyncReceivedAt = latest
        }
        try context.save()
        // Only once the records are saved: a failed save fetches them again.
        state.setChangeToken(fetched.token, zoneName: zoneID.zoneName)
    }

    /// The zone was deleted (unlinked by the parent, or the share revoked).
    /// Child side, the link goes and the local settings become editable
    /// again. Parent side, only a zone that was linked is forgotten.
    private static func zoneGone(_ child: Child, zoneName: String, context: ModelContext,
                                 state: FamilySyncStateStore) {
        guard child.familySyncZoneOwner != nil || child.familySyncLinkedAt != nil else { return }
        forget(child, zoneName: zoneName, context: context, state: state)
    }

    /// Unlinked: clears the link and the sync state. Parent side, the
    /// results received from the child's phone are removed too.
    static func forget(_ child: Child, zoneName: String, context: ModelContext,
                       state: FamilySyncStateStore = FamilySyncStateStore()) {
        if child.familySyncZoneOwner == nil {
            FamilySyncIngest.purge(ids: state.ingestedIDs(zoneName: zoneName), from: child, context: context)
        }
        child.familySyncZoneName = nil
        child.familySyncZoneOwner = nil
        child.familySyncLinkedAt = nil
        child.familySyncLastSyncedAt = nil
        child.familySyncReceivedAt = nil
        state.clear(zoneName: zoneName)
        try? context.save()
    }

    // MARK: CloudKit

    nonisolated static func isZoneGone(_ error: CKError) -> Bool {
        switch error.code {
        case .zoneNotFound, .userDeletedZone: return true
        case .partialFailure:
            return error.partialErrorsByItemID?.values.contains { ($0 as? CKError).map(isZoneGone) ?? false } ?? false
        default: return false
        }
    }

    private static func push(_ records: [FamilySyncRecord], zoneID: CKRecordZone.ID, database: CKDatabase,
                             state: FamilySyncStateStore) async throws {
        var start = 0
        while start < records.count {
            let batch = Array(records[start..<min(start + batchSize, records.count)])
            start += batchSize
            let result = try await database.modifyRecords(saving: batch.map { $0.ckRecord(in: zoneID) },
                                                          deleting: [], savePolicy: .allKeys, atomically: false)
            var saved: [FamilySyncRecord] = []
            for record in batch {
                switch result.saveResults[CKRecord.ID(recordName: record.name, zoneID: zoneID)] {
                case .success?:
                    saved.append(record)
                case .failure(let error)?:
                    if let error = error as? CKError, isZoneGone(error) { throw error }
                    NSLog("[noto][warn] family sync: a record was not sent: %@", error.localizedDescription)
                case nil:
                    break
                }
            }
            state.markSent(saved, zoneName: zoneID.zoneName)
        }
    }

    private struct Fetched {
        var records: [FamilySyncRecord]
        var token: Data?
        /// Latest server modification date of a record the child's phone
        /// wrote (rules records are the parent's own).
        var latestChildChange: Date?
    }

    private static func fetchChanges(zoneID: CKRecordZone.ID, database: CKDatabase,
                                     state: FamilySyncStateStore) async throws -> Fetched {
        var token = state.changeToken(zoneName: zoneID.zoneName).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var records: [FamilySyncRecord] = []
        var latestChildChange: Date?
        var restarted = false
        while true {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for result in changes.modificationResultsByID.values {
                    if case .success(let modification) = result,
                       let record = FamilySyncRecord(ckRecord: modification.record) {
                        records.append(record)
                        if record.kind != .rules, let date = modification.record.modificationDate,
                           latestChildChange.map({ date > $0 }) ?? true {
                            latestChildChange = date
                        }
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            } catch let error as CKError where error.code == .changeTokenExpired && !restarted {
                // Start over from the beginning: ingest is idempotent.
                token = nil
                records = []
                latestChildChange = nil
                restarted = true
            }
        }
        let data = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return Fetched(records: records, token: data, latestChildChange: latestChildChange)
    }
}
