import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "DirectorySchoolCache")

/// Cache of `DirectorySchool` payloads fetched from `celyn.io/api/directory/schools/:rne`.
///
/// The whitelist builder needs the full school (with its flat
/// `mailDomains` array) every time an IMAP sync runs. Hitting celyn on
/// every rebuild is both wasteful and a privacy surface, so we cache
/// locally in `UserDefaults` with a 7-day TTL.
///
/// Storage target is `UserDefaults` rather than Keychain: the payload
/// is public reference data (no credentials, no PII — just school RNE
/// + domains + kind), so Keychain would be overkill.
enum DirectorySchoolCache {

    /// 7 days. School metadata (ENT provider, commune services) changes
    /// rarely enough that a weekly refresh keeps us current without
    /// flooding celyn.
    static let ttlSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Exposed for tests so they can point the cache at an isolated
    /// suite rather than the shared `standard` defaults. `UserDefaults`
    /// is thread-safe, so `nonisolated(unsafe)` is sound.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    // MARK: - Key shape

    /// Stable cache key per RNE. Prefix avoids collision with other
    /// UserDefaults consumers.
    private static func key(for rne: String) -> String {
        "directory.school.\(rne.uppercased())"
    }

    // MARK: - Load (sync)

    /// Returns a cached `DirectorySchool` if one exists AND is fresh.
    /// Stale or missing entries return nil — callers should fall back
    /// to `refresh(rne:client:)` when they want to repopulate.
    static func load(rne: String) -> DirectorySchool? {
        guard let data = defaults.data(forKey: key(for: rne)) else { return nil }
        do {
            let entry = try JSONDecoder().decode(CacheEntry.self, from: data)
            guard !entry.isStale else { return nil }
            return entry.school
        } catch {
            logger.warning("Failed to decode cached school for \(rne, privacy: .public): \(String(describing: error))")
            return nil
        }
    }

    /// Returns the raw cached school regardless of TTL — used when the
    /// caller would rather show stale data than nothing (offline UX).
    static func loadEvenIfStale(rne: String) -> DirectorySchool? {
        guard let data = defaults.data(forKey: key(for: rne)) else { return nil }
        do {
            return try JSONDecoder().decode(CacheEntry.self, from: data).school
        } catch {
            // Mirror `load(rne:)`'s log path so a corrupt entry surfaces
            // ops-side. Drop the bad entry so we don't re-decode it on
            // every call until the next refresh overwrites.
            logger.warning("Failed to decode stale-path school for \(rne, privacy: .public): \(String(describing: error))")
            defaults.removeObject(forKey: key(for: rne))
            return nil
        }
    }

    // MARK: - Save

    static func save(_ school: DirectorySchool) {
        let entry = CacheEntry(school: school, fetchedAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else {
            logger.warning("Failed to encode school \(school.rne, privacy: .public) for caching")
            return
        }
        defaults.set(data, forKey: key(for: school.rne))
    }

    // MARK: - Refresh (async, network)

    /// Fetch via the API and cache the result. Throws from the client
    /// on network / HTTP / decoding failures — caller decides whether
    /// to swallow (background refresh) or surface (explicit user action).
    @discardableResult
    static func refresh(
        rne: String,
        client: DirectoryAPIClient = DirectoryAPIClient()
    ) async throws -> DirectorySchool {
        let school = try await client.fetchSchool(rne: rne)
        save(school)
        return school
    }

    // MARK: - Bulk lookup for MailWhitelist

    /// Build the `[RNE: DirectorySchool]` map consumed by
    /// `MailWhitelist.build(from:, directorySchools:)`. Fresh cache hits
    /// populate immediately; stale/missing entries trigger a background
    /// refresh but the map reflects whatever was synchronously available,
    /// so callers never block on the network. The next sync will pick
    /// up the freshly-refreshed entry.
    ///
    /// Fails open: any refresh failure is logged and skipped — we'd
    /// rather fall back to `ENTRegistry` than break the sync.
    @MainActor
    static func schools(
        for children: [Child],
        client: DirectoryAPIClient = DirectoryAPIClient()
    ) async -> [String: DirectorySchool] {
        var result: [String: DirectorySchool] = [:]
        var toRefresh: [String] = []

        for child in children {
            guard let rne = child.rneCode, !rne.isEmpty else { continue }
            if let fresh = load(rne: rne) {
                result[rne] = fresh
            } else {
                // Use stale data if present so the sync isn't worse
                // off than before — the whitelist gets at least what
                // the last refresh knew about.
                if let stale = loadEvenIfStale(rne: rne) {
                    result[rne] = stale
                }
                toRefresh.append(rne)
            }
        }

        // Kick off refreshes in parallel for anything missing or stale.
        // Await all before returning so the next sync run benefits, but
        // we keep the current map in `result` — the write side of the
        // cache is what matters long-term, not blocking this caller.
        await withTaskGroup(of: (String, DirectorySchool?).self) { group in
            for rne in toRefresh {
                group.addTask {
                    do {
                        let school = try await refresh(rne: rne, client: client)
                        return (rne, school)
                    } catch {
                        logger.warning("Directory refresh failed for \(rne, privacy: .public): \(String(describing: error))")
                        return (rne, nil)
                    }
                }
            }
            for await (rne, school) in group {
                if let school { result[rne] = school }
            }
        }

        return result
    }

    // MARK: - Invalidation

    static func invalidate(rne: String) {
        defaults.removeObject(forKey: key(for: rne))
    }

    /// Removes every cached directory entry. Used at signout / "clear
    /// all data" — directory records aren't sensitive, but the whole
    /// local-state-reset needs to be complete.
    static func clearAll() {
        let prefix = "directory.school."
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for k in keys { defaults.removeObject(forKey: k) }
    }
}

// MARK: - Wire format

/// On-disk wrapper — adds a `fetchedAt` timestamp around the school so
/// we can compute staleness without a separate index.
private struct CacheEntry: Codable {
    let school: DirectorySchool
    let fetchedAt: Date

    var isStale: Bool {
        Date.now.timeIntervalSince(fetchedAt) > DirectorySchoolCache.ttlSeconds
    }
}
