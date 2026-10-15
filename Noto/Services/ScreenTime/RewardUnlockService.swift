import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "RewardUnlockService")

/// What the child home says about the cagnotte minutes (tutoiement copy in
/// `ChildHomeView`). Pure.
enum RewardStatus: Equatable, Sendable {
    /// No Screen Time setup (authorization or watched apps missing), or
    /// nothing owed today: the neutral « gagnées aujourd'hui » wording.
    case neutral
    /// A reward activity runs: the apps are unlocked for (at most) N min.
    case unlocked(minutes: Int)
    /// During a class block (or reserve not yet released): the minutes wait.
    case afterClass
    /// Credited, but the daily budget is not spent yet: nothing to unlock,
    /// the minutes add up once it is.
    case waitingForBudget(minutes: Int)

    /// `appLimitMonitoring`: the daily budget activity is registered. Without
    /// it no budget can be spent, so pending minutes never unlock: the child
    /// is not promised they will (neutral wording).
    static func make(ledger: RewardLedger, configured: Bool, inClass: Bool,
                     appLimitMonitoring: Bool = true,
                     now: Date, calendar: Calendar) -> RewardStatus {
        guard configured else { return .neutral }
        var ledger = ledger
        ledger.rollOver(now: now, calendar: calendar)
        if inClass, ledger.balance > 0 { return .afterClass }
        if !ledger.activities.isEmpty { return .unlocked(minutes: ledger.unlockedMinutes) }
        if ledger.reserve > 0 { return .afterClass }
        if ledger.pending > 0, appLimitMonitoring { return .waitingForBudget(minutes: ledger.pending) }
        return .neutral
    }
}

/// Foreground maintenance decisions, pure so they are tested.
enum RewardMaintenance {
    enum DailyResetAction: Equatable, Sendable { case register, stop, none }

    /// `noto.reward.daily` only when the app-limit activity (which already
    /// starts at 00:00) is not registered, and only if a slot is free.
    static func dailyResetAction(registered: Set<String>,
                                 appleLimit: Int = RewardConstants.appleActivityLimit) -> DailyResetAction {
        let hasDaily = registered.contains(RewardConstants.dailyActivityName)
        if registered.contains(RewardConstants.appLimitActivityName) {
            return hasDaily ? .stop : .none
        }
        guard !hasDaily, registered.count < appleLimit else { return .none }
        return .register
    }

    /// Defensive re-lock (like `clearIfOutsideClassHours` for the class
    /// lock): a reward activity vanished from `DeviceActivityCenter` without
    /// the extension recording its end (`droppedMissing` > 0 in this
    /// refresh), none runs any more, the budget was spent today and the
    /// shield is down → shield the selection again. Only that case: a shield
    /// down for any other reason (the parent raised the budget, which
    /// re-registers the app-limit activity and lifts it) is left alone.
    static func shouldRelock(ledger: RewardLedger, droppedMissing: Int, shieldEngaged: Bool,
                             appLimitMonitoring: Bool, budgetSpentToday: Bool) -> Bool {
        droppedMissing > 0 && ledger.activities.isEmpty
            && appLimitMonitoring && budgetSpentToday && !shieldEngaged
    }
}

/// Turns quiz minutes into unlocked Screen Time (plan §3.4, PHASE3_DESIGN §C.2).
///
/// - `credit` (quiz finished) → `RewardLedger.credit` → `unlock()`.
/// - `unlock()`: inside a class block → the minutes go to the reserve,
///   nothing is unlocked. Otherwise, when the budget shield is up (or a
///   reward runs), lifts the DEFAULT store shield and registers
///   `noto.reward.<uuid>` on the persisted watched selection, now → 23:59,
///   threshold = the minutes (`RewardEngine`, shared with the extension).
/// - `foregroundRefresh`: midnight leftovers, reserve release after class,
///   `noto.reward.daily`, defensive re-lock.
///
/// Never touches `ManagedSettingsStore(named: ClassLockConstants.storeName)`:
/// the class lock is absolute (CLAUDE.md « crédit ≠ verrou cours »).
/// Without Screen Time authorization or watched apps nothing is registered
/// and nothing crashes: the minutes stay in the ledger.
@MainActor
enum RewardUnlockService {
    /// Authorization approved and at least one watched app or category.
    static var isConfigured: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
            && RewardShield.hasTokens(ScreenTimeEventStore.loadWatchedSelection())
    }

    private static var isPreview: Bool { ProcessInfo.processInfo.isRunningForPreviews }

    /// Quiz hook (`QuizSession.onMinutesEarned`): records the minutes, then
    /// tries to unlock.
    @discardableResult
    static func credit(minutes: Int, at date: Date = .now, schedule: [ScheduleEntry]) -> RewardUnlockOutcome {
        guard minutes > 0, !isPreview else { return .nothingPending }
        RewardLedgerStore.update(now: date) { $0.credit(minutes, now: date, calendar: .current) }
        logger.info("Credited \(minutes) min")
        return unlock(schedule: schedule, now: date)
    }

    @discardableResult
    static func unlock(schedule: [ScheduleEntry], now: Date = .now) -> RewardUnlockOutcome {
        guard !isPreview else { return .nothingPending }
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { return .notAuthorized }
        let selection = ScreenTimeEventStore.loadWatchedSelection()
        guard RewardShield.hasTokens(selection) else { return .noSelection }

        let blocks = gateBlocks(schedule: schedule, now: now)
        let outcome = RewardEngine.unlockPending(now: now, blocks: blocks, selection: selection)
        logger.info("Unlock: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// On every foreground (RootView).
    static func foregroundRefresh(schedule: [ScheduleEntry], now: Date = .now) {
        guard !isPreview, isConfigured else { return }
        let calendar = Calendar.current
        let center = DeviceActivityCenter()
        let store = ManagedSettingsStore()
        let registered = Set(center.activities.map(\.rawValue))

        // Midnight leftovers (a missed extension callback) and activities
        // the center no longer knows.
        let (leftovers, droppedMissing) = RewardLedgerStore.update(now: now) { ledger in
            let reset = ledger.midnightReset(now: now, calendar: calendar)
            let dropped = ledger.dropMissing(registered: registered, now: now, calendar: calendar)
            return (reset.namesToStop, dropped)
        }
        RewardEngine.stop(leftovers, center: center)

        // Reserve released once no class block runs (the extension also
        // does it on the class-lock `intervalDidEnd`, which is unreliable).
        let blocks = gateBlocks(schedule: schedule, now: now)
        if RewardGate.canConsume(now: now, blocks: blocks, calendar: calendar) {
            let released = RewardLedgerStore.update(now: now) { $0.releaseReserve(now: now, calendar: calendar) }
            if released > 0 { logger.info("Released \(released) min from reserve") }
        }

        // Reward activities the ledger does not know (lost or reset ledger,
        // a lost cross-process write): nothing would ever stop them, and they
        // take schedule slots the class lock needs. The ledger is re-read
        // right before, so a name the extension just committed is kept.
        let known = Set(RewardLedgerStore.load(now: now).activityNames)
        let orphans = registered.filter { RewardConstants.isRewardActivity($0) && !known.contains($0) }.sorted()
        RewardEngine.stop(orphans, center: center)
        if !orphans.isEmpty { logger.info("Stopped \(orphans.count) unknown reward activities") }

        ensureDailyResetActivity(center: center)
        unlock(schedule: schedule, now: now)

        let ledger = RewardLedgerStore.load(now: now)
        if RewardMaintenance.shouldRelock(
            ledger: ledger, droppedMissing: droppedMissing + orphans.count, shieldEngaged: RewardShield.isEngaged(store),
            appLimitMonitoring: Set(center.activities.map(\.rawValue)).contains(RewardConstants.appLimitActivityName),
            budgetSpentToday: RewardBudget.isSpentToday(now: now, calendar: calendar)
        ) {
            RewardShield.apply(ScreenTimeEventStore.loadWatchedSelection(), to: store)
            logger.info("Defensive re-lock: a reward vanished unrecorded, budget spent today")
        }
    }

    /// Child home wording.
    static func status(schedule: [ScheduleEntry], now: Date = .now) -> RewardStatus {
        let blocks = gateBlocks(schedule: schedule, now: now)
        let appLimitMonitoring = DeviceActivityCenter().activities
            .contains(DeviceActivityName(RewardConstants.appLimitActivityName))
        return RewardStatus.make(ledger: RewardLedgerStore.load(now: now), configured: isConfigured,
                                 inClass: !RewardGate.canConsume(now: now, blocks: blocks),
                                 appLimitMonitoring: appLimitMonitoring,
                                 now: now, calendar: .current)
    }

    /// Class windows for the reward gate: the registered ones
    /// (`ClassBlockStore`, written by `ClassScheduleShieldService.sync`
    /// only) united with the timetable's, so stale or empty SwiftData never
    /// shrinks the gate. The store is only written here when nothing would
    /// be lost: no class lock registered (the extension still needs the
    /// windows to hold the reserve), or a registered lock whose store is
    /// still empty (upgrade); and never with an empty timetable.
    private static func gateBlocks(schedule: [ScheduleEntry], now: Date) -> [ClassBlock] {
        let computed = ClassScheduleShieldService.computeBlocks(from: schedule, now: now)
        let stored = ClassBlockStore.load()
        let lockRegistered = !ScreenTimeEventStore.loadClassLockActivityNames().isEmpty
        if !computed.isEmpty, computed != stored, !lockRegistered || stored.isEmpty {
            ClassBlockStore.store(computed)
        }
        return ClassScheduleShieldService.mergedBlocks(stored, computed)
    }

    private static func ensureDailyResetActivity(center: DeviceActivityCenter) {
        let daily = DeviceActivityName(RewardConstants.dailyActivityName)
        switch RewardMaintenance.dailyResetAction(registered: Set(center.activities.map(\.rawValue))) {
        case .register:
            let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                                  intervalEnd: DateComponents(hour: 23, minute: 59),
                                                  repeats: true)
            do {
                try center.startMonitoring(daily, during: schedule)
            } catch {
                logger.error("noto.reward.daily not registered: \(error.localizedDescription, privacy: .public)")
            }
        case .stop:
            center.stopMonitoring([daily])
        case .none:
            break
        }
    }
}
