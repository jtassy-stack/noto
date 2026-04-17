import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "SyncCoordinator")

/// Singleton that serialises full-sync requests from all trigger sites
/// (HomeView pull-to-refresh, .triggerFullSync notification, pronote
/// reconnect, background fetch).
///
/// Responsibilities:
/// - **De-duplicate concurrent callers**: if a sync is already running,
///   new callers await the in-flight task and share its result.
/// - **60-second cooldown**: once a sync completes successfully, new
///   requests within 60 s are silently dropped.  The cooldown is stored
///   here (not in `@State`) so it survives view re-creation.
@MainActor
final class SyncCoordinator: ObservableObject {

    static let shared = SyncCoordinator()

    private init() {}

    // MARK: - State

    @Published private(set) var isSyncing: Bool = false

    /// Last successful sync timestamp — used by views for the "last sync" label.
    @Published private(set) var lastSyncDate: Date?

    /// Errors from the most recent sync run, if any.
    @Published private(set) var syncError: String?

    // MARK: - Private

    /// 60-second minimum interval between syncs.
    private let cooldownInterval: TimeInterval = 60

    /// Currently running sync task (if any).  New callers that arrive
    /// while this is non-nil will await it instead of spawning a second.
    private var inFlightTask: Task<Void, Never>?

    // MARK: - Public API

    /// Request a full sync.  If a sync is already in-flight, awaits it
    /// rather than double-triggering.  Respects the 60 s cooldown.
    ///
    /// - Parameter action: The actual work to perform; supplied by
    ///   `HomeView.performFullRefresh()` so the coordinator doesn't need
    ///   to own the modelContext or the child list.
    func requestSync(action: @escaping () async -> Void) async {
        // If already running, wait for the current task and return.
        if let existing = inFlightTask {
            logger.debug("Sync already in-flight — awaiting existing task")
            await existing.value
            return
        }

        // Enforce cooldown.
        if let last = lastSyncDate,
           Date.now.timeIntervalSince(last) < cooldownInterval {
            let remaining = Int(cooldownInterval - Date.now.timeIntervalSince(last))
            logger.debug("Sync cooldown active — \(remaining) s remaining, skipping")
            return
        }

        // Kick off the sync and track the task.
        let task = Task<Void, Never> {
            isSyncing = true
            syncError = nil
            defer {
                isSyncing = false
                inFlightTask = nil
            }
            await action()
        }

        inFlightTask = task
        await task.value
    }

    /// Called by `HomeView` once its own sync logic completes, to record
    /// the timestamp and surface errors.
    func finishedSync(errors: String?) {
        lastSyncDate = Date.now
        syncError = errors
    }
}
