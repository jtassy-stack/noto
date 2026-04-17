import Testing
import Foundation
@testable import Noto

/// Coverage for `DirectorySchoolCache` — the 7-day TTL'd UserDefaults
/// store that feeds `MailWhitelist.build(from:, directorySchools:)`
/// without hitting celyn on every sync.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so concurrent
/// test execution can't collide on the shared `.standard` store.
@Suite("DirectorySchoolCache", .serialized)
struct DirectorySchoolCacheTests {

    private static var counter: Int = 0

    private static func makeSuite() -> UserDefaults {
        counter += 1
        let name = "noto.test.directory.\(counter).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    private func withIsolatedCache<T>(_ body: () throws -> T) rethrows -> T {
        let original = DirectorySchoolCache.defaults
        DirectorySchoolCache.defaults = Self.makeSuite()
        defer { DirectorySchoolCache.defaults = original }
        return try body()
    }

    private func withIsolatedCacheAsync<T>(_ body: () async throws -> T) async rethrows -> T {
        let original = DirectorySchoolCache.defaults
        DirectorySchoolCache.defaults = Self.makeSuite()
        defer { DirectorySchoolCache.defaults = original }
        return try await body()
    }

    private func makeSchool(rne: String = "0930122Y", mailDomains: [String] = ["monlycee.net"]) -> DirectorySchool {
        DirectorySchool(
            rne: rne,
            name: "Collège Test",
            kind: "college",
            academy: "Créteil",
            holidayZone: "C",
            website: nil,
            commune: nil,
            ent: nil,
            services: [],
            mailDomains: mailDomains
        )
    }

    // MARK: - Round-trip

    @Test("save + load returns the same payload when fresh")
    func saveLoadRoundTrip() {
        withIsolatedCache {
            let school = makeSchool()
            DirectorySchoolCache.save(school)
            let loaded = DirectorySchoolCache.load(rne: school.rne)
            #expect(loaded == school)
        }
    }

    @Test("load returns nil for a never-cached RNE")
    func loadMissReturnsNil() {
        withIsolatedCache {
            #expect(DirectorySchoolCache.load(rne: "0000000X") == nil)
        }
    }

    @Test("RNE lookup is case-insensitive on the key path")
    func rneCaseInsensitive() {
        withIsolatedCache {
            let school = makeSchool(rne: "0930122Y")
            DirectorySchoolCache.save(school)
            #expect(DirectorySchoolCache.load(rne: "0930122y") != nil)
        }
    }

    // MARK: - TTL

    @Test("load returns nil after TTL has elapsed")
    func staleEntriesReturnNil() throws {
        try withIsolatedCache {
            let school = makeSchool()
            // Hand-craft an expired entry — avoids hanging a test on
            // 7 days of real time.
            let expired = OnDiskEntryMirror(
                school: school,
                fetchedAt: Date(timeIntervalSinceNow: -(DirectorySchoolCache.ttlSeconds + 60))
            )
            let data = try JSONEncoder().encode(expired)
            DirectorySchoolCache.defaults.set(data, forKey: "directory.school.\(school.rne)")

            #expect(DirectorySchoolCache.load(rne: school.rne) == nil)
            // loadEvenIfStale should still return it — offline UX path.
            #expect(DirectorySchoolCache.loadEvenIfStale(rne: school.rne) == school)
        }
    }

    // MARK: - Invalidation

    @Test("invalidate removes a single entry")
    func invalidateRemovesOne() {
        withIsolatedCache {
            let a = makeSchool(rne: "0930001A")
            let b = makeSchool(rne: "0930002B")
            DirectorySchoolCache.save(a)
            DirectorySchoolCache.save(b)
            DirectorySchoolCache.invalidate(rne: "0930001A")
            #expect(DirectorySchoolCache.load(rne: "0930001A") == nil)
            #expect(DirectorySchoolCache.load(rne: "0930002B") != nil)
        }
    }

    @Test("clearAll removes every cached entry, leaves unrelated keys intact")
    func clearAllScopedToPrefix() {
        withIsolatedCache {
            DirectorySchoolCache.save(makeSchool(rne: "0930001A"))
            DirectorySchoolCache.save(makeSchool(rne: "0930002B"))
            DirectorySchoolCache.defaults.set("keep-me", forKey: "unrelated.key")

            DirectorySchoolCache.clearAll()
            #expect(DirectorySchoolCache.load(rne: "0930001A") == nil)
            #expect(DirectorySchoolCache.load(rne: "0930002B") == nil)
            #expect(DirectorySchoolCache.defaults.string(forKey: "unrelated.key") == "keep-me")
        }
    }
}

// MARK: - Mirror of the cache's private `CacheEntry`

/// Exact shape of `DirectorySchoolCache.CacheEntry` — kept in sync so
/// the TTL test can seed an expired-looking record directly. If the
/// cache ever adds fields, update here too.
private struct OnDiskEntryMirror: Codable {
    let school: DirectorySchool
    let fetchedAt: Date
}
