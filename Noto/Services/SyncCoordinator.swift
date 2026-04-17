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
/// - **60-second cooldown**: once a sync completes *successfully*, new
///   automatic requests within 60 s are silently dropped. Failed syncs
///   never start the cooldown — retries must always be possible.
/// - **Persistence**: last-sync timestamp is written to UserDefaults so
///   it survives app restarts.
@MainActor
final class SyncCoordinator: ObservableObject {

    static let shared = SyncCoordinator()

    private let defaults = UserDefaults.standard
    private let lastSyncKey = "syncCoordinatorLastSyncDate"

    private init() {
        let interval = defaults.double(forKey: lastSyncKey)
        if interval > 0 {
            lastSyncDate = Date(timeIntervalSince1970: interval)
        }
    }

    // MARK: - State

    @Published private(set) var isSyncing: Bool = false

    /// Last *successful* sync timestamp — used by views for the "last sync" label.
    /// Nil until the first successful sync after install.
    @Published private(set) var lastSyncDate: Date?

    /// Errors from the most recent sync run, if any.
    @Published private(set) var syncError: String?

    // MARK: - Private

    private let cooldownInterval: TimeInterval = 60

    /// Currently running sync task (if any).  New callers that arrive
    /// while this is non-nil will await it instead of spawning a second.
    private var inFlightTask: Task<Void, Never>?

    // MARK: - Public API

    /// Request a full sync.
    ///
    /// - Parameter force: When `true`, bypasses the cooldown timer — use
    ///   for explicit user actions (pull-to-refresh). Automatic triggers
    ///   (background fetch, .onAppear) should leave this at `false`.
    /// - Parameter action: The actual sync work; supplied by
    ///   `HomeView.performFullRefresh()` so the coordinator doesn't own
    ///   the modelContext or child list.
    func requestSync(force: Bool = false, action: @escaping () async -> Void) async {
        // If already running, wait for the current task and return.
        if let existing = inFlightTask {
            logger.debug("Sync already in-flight — awaiting existing task")
            await existing.value
            return
        }

        // Enforce cooldown only for automatic triggers on successful syncs.
        // Forced requests (pull-to-refresh) and post-error retries always proceed.
        if !force && syncError == nil,
           let last = lastSyncDate,
           Date.now.timeIntervalSince(last) < cooldownInterval {
            let remaining = Int(cooldownInterval - Date.now.timeIntervalSince(last))
            logger.debug("Sync cooldown active — \(remaining) s remaining, skipping")
            return
        }

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

    /// Called by `HomeView` once its sync logic completes.
    /// Only advances the cooldown timestamp on clean runs — a failed sync
    /// must never block the user from retrying immediately.
    func finishedSync(errors: String?) {
        syncError = errors
        if errors == nil {
            let now = Date.now
            lastSyncDate = now
            defaults.set(now.timeIntervalSince1970, forKey: lastSyncKey)
        }
    }
}
