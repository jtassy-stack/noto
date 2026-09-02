import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "FullSyncService")

/// Outcome of one `FullSyncService.sync` run.
struct FullSyncResult {
    /// Parent-facing error lines, one per failed connection or child.
    var errors: [String] = []
    /// True when direct-Pronote children could not be synced because no
    /// bridge session could be established. Views decide whether that
    /// deserves a modal (user-initiated refresh) or just the reconnect
    /// card (automatic launch sync).
    var pronoteUnavailable = false

    var joinedErrors: String? {
        errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

/// Runs a full data sync for a set of children across every connector
/// (direct Pronote, MonLycée, PCN/ENT, École Directe, Skolengo).
///
/// Owned by no view: RootView uses it for the launch-time initial sync and
/// HomeView for user-initiated refreshes. Always invoke it through
/// `SyncCoordinator.requestSync`, which owns `isSyncing`, de-duplication
/// and the automatic-trigger cooldown.
@MainActor
final class FullSyncService {
    private let modelContext: ModelContext
    private var pronoteService: PronoteService { .shared }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Sync `children` and report the aggregated outcome to
    /// `SyncCoordinator.finishedSync`. Each child's `lastSyncedAt` is
    /// stamped by its sync service on success.
    @discardableResult
    func sync(children targetChildren: [Child]) async -> FullSyncResult {
        var result = FullSyncResult()
        // Children with a direct Pronote bridge connection (QR code login)
        let directPronoteChildren = targetChildren.filter(\.isDirectPronote)
        // Children from MonLycée (have entProvider) — sync via logbook
        let monlyceeChildren = targetChildren.filter { $0.entProvider == .monlycee }
        // Pure ENT children (PCN etc)
        let entChildren = targetChildren.filter { $0.schoolType == .ent && $0.entProvider != .monlycee }
        // École Directe children
        let edChildren = targetChildren.filter { $0.schoolType == .ecoledirecte }
        // Skolengo children
        let skolengoChildren = targetChildren.filter { $0.schoolType == .skolengo }

        // Direct Pronote sync (QR code login)
        if !directPronoteChildren.isEmpty {
            // autoConnect is re-entrant: if RootView's launch auto-connect is
            // still running this awaits it instead of consuming the refresh
            // token a second time.
            if pronoteService.bridge == nil {
                await PronoteAutoConnect.autoConnect(modelContext: modelContext)
            }
            if let bridge = pronoteService.bridge {
                // Resolve each child to its pawnote-session index via
                // pawnoteID (or firstName fallback) — SwiftData order
                // has no relation to the bridge's internal child list,
                // so enumerated() would silently sync the wrong kid.
                let pawnoteRoster = bridge.getChildren()
                let syncService = PronoteSyncService(modelContext: modelContext)
                for child in directPronoteChildren {
                    guard let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnoteRoster) else {
                        // Surface the skip as a user-visible error instead of
                        // a silent continue — otherwise the banner reads "tout
                        // va bien" while one kid's dashboard freezes. The
                        // remediation is always to re-run QR login, which
                        // re-backfills pawnoteID via ChildDedupe.
                        logger.warning("Skipping sync for \(child.firstName, privacy: .private): no matching pawnote resource")
                        result.errors.append("Impossible de synchroniser \(child.firstName) — reconnectez-vous via QR code pour relier cet enfant à Pronote.")
                        continue
                    }
                    await syncService.sync(child: child, bridge: bridge, childIndex: idx)
                    if !syncService.failedCategories.isEmpty {
                        result.errors.append("Sync incomplète pour \(child.firstName) : \(syncService.failedCategories.joined(separator: ", "))")
                    }
                }
            } else {
                result.pronoteUnavailable = true
                result.errors.append("Connexion à Pronote impossible. Reconnectez-vous via QR code si le problème persiste.")
            }
        }

        // MonLycée children: try Pronote bridge first, fallback to logbook
        if !monlyceeChildren.isEmpty {
            if pronoteService.bridge == nil {
                await PronoteAutoConnect.autoConnect(modelContext: modelContext)
            }
            if let bridge = pronoteService.bridge {
                let pawnoteRoster = bridge.getChildren()
                let syncService = PronoteSyncService(modelContext: modelContext)
                for child in monlyceeChildren {
                    guard let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnoteRoster) else {
                        logger.warning("Skipping monlycee sync for \(child.firstName, privacy: .private): no matching pawnote resource")
                        result.errors.append("Impossible de synchroniser \(child.firstName) — reconnectez-vous via QR code pour relier cet enfant à Pronote.")
                        continue
                    }
                    await syncService.sync(child: child, bridge: bridge, childIndex: idx)
                    if !syncService.failedCategories.isEmpty {
                        result.errors.append("Sync incomplète pour \(child.firstName) : \(syncService.failedCategories.joined(separator: ", "))")
                    }
                }
            } else {
                // Fallback: sync from the logbook captured at ENT login. An
                // absent or non-matching logbook is a failure, not an empty
                // sync — otherwise the child would be stamped as synced with
                // no data and no way for the parent to know.
                let syncService = MonLyceeSyncService(modelContext: modelContext)
                for child in monlyceeChildren where !syncService.syncFromStoredLogbook(for: child) {
                    result.errors.append("Impossible de synchroniser \(child.firstName) — reconnectez-vous via MonLycée.")
                }
            }
        }

        // Pure ENT/PCN sync
        if !entChildren.isEmpty {
            result.errors.append(contentsOf: await syncENTChildren(entChildren))
        }

        // École Directe sync
        if !edChildren.isEmpty {
            result.errors.append(contentsOf: await syncEcoleDirecteChildren(edChildren))
        }

        // Skolengo sync
        if !skolengoChildren.isEmpty {
            result.errors.append(contentsOf: await syncSkolengoChildren(skolengoChildren))
        }

        SyncCoordinator.shared.finishedSync(errors: result.joinedErrors)
        return result
    }

    // MARK: - ENT / PCN

    private func syncENTChildren(_ entChildren: [Child]) async -> [String] {
        var errors: [String] = []

        // Group children by provider so we login once per provider
        var byProvider: [ENTProvider: [Child]] = [:]
        for child in entChildren {
            let provider = child.entProvider ?? .pcn
            byProvider[provider, default: []].append(child)
        }

        let syncService = ENTSyncService(modelContext: modelContext)

        for (provider, children) in byProvider {
            let key = "ent_credentials_\(provider.rawValue)"
            guard let credsData = try? KeychainService.load(key: key),
                  let creds = String(data: credsData, encoding: .utf8) else {
                errors.append("\(provider.name) : identifiants manquants")
                continue
            }

            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                errors.append("\(provider.name) : identifiants corrompus")
                continue
            }

            let client = ENTClient(provider: provider)
            do {
                // ENT is a React SPA — must use HeadlessENTAuth (WKWebView), not URLSession POST
                let loginURL = provider.baseURL.appendingPathComponent("auth/login")
                let cookies = try await HeadlessENTAuth.login(
                    loginURL: loginURL,
                    email: String(parts[0]),
                    password: String(parts[1])
                )
                ENTClient.importCookies(cookies)
                // Signal PhotoGridView to retry any pending thumbnail loads — the session
                // is now valid and cookies are in URLSession.shared's cookie storage.
                NotificationCenter.default.post(name: .entSessionReady, object: nil)
            } catch {
                errors.append("\(provider.name) : reconnexion échouée — \(error.localizedDescription)")
                continue
            }

            for child in children {
                do {
                    try await syncService.sync(
                        child: child,
                        client: client,
                        entChildId: child.entChildId ?? child.firstName
                    )
                } catch {
                    errors.append("\(child.firstName) : sync échouée — \(error.localizedDescription)")
                }
            }

            // Pre-warm photo cache in background — auth is valid right now, ideal moment to download.
            // Collect paths here (main actor) before crossing into the detached task.
            let photoPaths = children.flatMap(\.photos).map(\.entPath)
            if !photoPaths.isEmpty {
                let preloadClient = client
                Task.detached(priority: .background) {
                    await ENTPhotoCache.shared.preload(paths: photoPaths, client: preloadClient)
                }
            }
        }

        return errors
    }

    // MARK: - École Directe

    private func syncEcoleDirecteChildren(_ edChildren: [Child]) async -> [String] {
        var errors: [String] = []
        let syncService = EcoleDirecteSyncService(modelContext: modelContext)

        // Group by accountId so we login once per famille account
        var byAccount: [String: [Child]] = [:]
        for child in edChildren {
            let key = child.edAccountId ?? child.entChildId ?? child.firstName
            byAccount[key, default: []].append(child)
        }

        for (accountId, children) in byAccount {
            let credKey = "ed_credentials_\(accountId)"
            guard let credsData = try? KeychainService.load(key: credKey),
                  let creds = String(data: credsData, encoding: .utf8) else {
                errors.append("École Directe : identifiants manquants — reconnectez-vous")
                continue
            }
            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                errors.append("École Directe : identifiants corrompus")
                continue
            }

            let client = EcoleDirecteClient(accountId: accountId)
            do {
                _ = try await client.login(username: String(parts[0]), password: String(parts[1]))
            } catch {
                errors.append("École Directe : reconnexion échouée — \(error.localizedDescription)")
                continue
            }

            for child in children {
                do {
                    try await syncService.sync(child: child, client: client)
                } catch {
                    NSLog("[noto][error] ED sync failed for %@: %@", child.firstName, error.localizedDescription)
                    errors.append("\(child.firstName) (ED) : sync échouée — \(error.localizedDescription)")
                }
            }
        }

        return errors
    }

    // MARK: - Skolengo

    private func syncSkolengoChildren(_ skolengoChildren: [Child]) async -> [String] {
        var errors: [String] = []
        let syncService = SkolengoSyncService(modelContext: modelContext)

        // Group by schoolId — one session per school, matching how the
        // API scopes auth (X-Skolengo-School-Id header on every call).
        var bySchool: [String: [Child]] = [:]
        for child in skolengoChildren {
            guard let schoolId = child.skolengoSchoolId else {
                errors.append("\(child.firstName) (Skolengo) : établissement manquant — reconnectez-vous")
                continue
            }
            bySchool[schoolId, default: []].append(child)
        }

        for (schoolId, children) in bySchool {
            // Minimal school stub — sufficient for header construction and
            // token refresh (which reuses the cached token_endpoint, not a
            // fresh OIDC discovery), so no live school re-search is needed
            // for background sync.
            let school = SkolengoSchool(
                id: schoolId,
                name: children.first?.establishment ?? "",
                city: nil,
                emsCode: children.first?.skolengoEmsCode,
                emsOIDCWellKnownUrl: ""
            )
            let client = SkolengoClient(school: school)
            do {
                try await client.ensureValidToken()
            } catch {
                errors.append("Skolengo : reconnexion échouée — \(error.localizedDescription)")
                continue
            }

            for child in children {
                do {
                    try await syncService.sync(child: child, client: client)
                } catch {
                    NSLog("[noto][error] Skolengo sync failed for %@: %@", child.firstName, error.localizedDescription)
                    errors.append("\(child.firstName) (Skolengo) : sync échouée — \(error.localizedDescription)")
                }
            }
        }

        return errors
    }
}
