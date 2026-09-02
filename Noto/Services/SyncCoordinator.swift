import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "SyncCoordinator")

/// Singleton that serialises full-sync requests from all trigger sites
/// (launch-time initial sync, pull-to-refresh, `.triggerFullSync`,
/// Pronote reconnect, AddChild onboarding syncs).
///
/// Responsibilities:
/// - **De-duplicate concurrent callers**: if a sync is already running,
///   new callers await the in-flight task and share its result.
/// - **Cooldown for automatic triggers**: an automatic request made less
///   than 60 s after the previous *attempt* (successful or not) is dropped.
///   Counting attempts rather than successes is what gives failed logins
///   a backoff — otherwise every view appearance re-submits stale
///   credentials to the school server. User-initiated requests
///   (`force: true`) always run.
/// - **Persistence**: last successful-sync timestamp is written to
///   UserDefaults for the "Dernière sync" label. Per-child "first sync
///   done" state lives on `Child.lastSyncedAt`, not here.
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

    /// When the most recent sync *started* during this launch, whatever its
    /// outcome. In-memory only: the cooldown must not survive a relaunch.
    @Published private(set) var lastAttemptDate: Date?

    /// True once any sync has been started during this launch. Lets the UI
    /// tell "not attempted yet" (spinner) from "attempted and still pending"
    /// (failure card) without a per-run error string.
    var hasAttemptedSync: Bool { lastAttemptDate != nil }

    // MARK: - Private

    private let cooldownInterval: TimeInterval = 60

    /// Currently running sync task (if any).  New callers that arrive
    /// while this is non-nil will await it instead of spawning a second.
    private var inFlightTask: Task<Void, Never>?

    // MARK: - Public API

    /// Request a full sync.
    ///
    /// - Parameter force: When `true`, bypasses the cooldown timer — use
    ///   for explicit user actions (pull-to-refresh, "Synchroniser
    ///   maintenant", the Réessayer button). Automatic triggers (launch,
    ///   foreground, child added) leave this at `false`.
    /// - Parameter action: The actual sync work. The coordinator doesn't
    ///   own the modelContext or child list, so callers supply it.
    func requestSync(force: Bool = false, action: @escaping () async -> Void) async {
        // If already running, wait for the current task and return.
        if let existing = inFlightTask {
            logger.debug("Sync already in-flight — awaiting existing task")
            await existing.value
            return
        }

        if SyncCooldownPolicy.shouldSkip(force: force,
                                         lastAttempt: lastAttemptDate,
                                         now: .now,
                                         cooldown: cooldownInterval) {
            let elapsed = Date.now.timeIntervalSince(lastAttemptDate ?? .distantPast)
            logger.debug("Sync cooldown active — \(Int(self.cooldownInterval - elapsed)) s remaining, skipping")
            return
        }

        lastAttemptDate = .now
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

    /// Called by the sync runner once its work completes.
    /// Only advances the "last successful sync" timestamp on clean runs.
    func finishedSync(errors: String?) {
        syncError = errors
        if errors == nil {
            let now = Date.now
            lastSyncDate = now
            defaults.set(now.timeIntervalSince1970, forKey: lastSyncKey)
        }
    }
}

/// Pure decision for the automatic-trigger cooldown, kept free of actor
/// state so it can be unit-tested.
enum SyncCooldownPolicy {
    /// - Returns: `true` when an automatic request should be dropped
    ///   because another attempt started less than `cooldown` ago.
    static func shouldSkip(force: Bool, lastAttempt: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard !force, let lastAttempt else { return false }
        return now.timeIntervalSince(lastAttempt) < cooldown
    }
}
