import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for `DirectorySchoolCache` — the 7-day TTL'd UserDefaults
/// store that feeds `MailWhitelist.build(from:, directorySchools:)`
/// without hitting celyn on every sync.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so concurrent
/// test execution can't collide on the shared `.standard` store.
@Suite("DirectorySchoolCache", .serialized)
@MainActor
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

    // MARK: - On-disk format guard

    @Test("save() output round-trips into OnDiskEntryMirror — pins the wire format")
    func onDiskFormatMatchesMirror() throws {
        try withIsolatedCache {
            let school = makeSchool()
            DirectorySchoolCache.save(school)
            let data = DirectorySchoolCache.defaults.data(forKey: "directory.school.\(school.rne)")
            #expect(data != nil)
            // If the cache's private `CacheEntry` drifts from the mirror,
            // this decode fails loudly instead of silently skipping the
            // TTL test (which uses the mirror to seed expired records).
            let decoded = try JSONDecoder().decode(OnDiskEntryMirror.self, from: data!)
            #expect(decoded.school == school)
        }
    }

    // MARK: - schools(for:) behaviour — the real consumer entry point

    @Test("schools(for:) returns stale cached entry when refresh fails — the fail-open guarantee")
    func schoolsForStaleFallback() async throws {
        try await withIsolatedCacheAsync {
            let ctx = try makeContext()
            let child = makeChild(rne: "0930122Y", in: ctx)
            let cachedSchool = makeSchool(rne: "0930122Y", mailDomains: ["monlycee.net", "ac-creteil.fr"])

            // Hand-seed an EXPIRED entry so the cache goes out to refresh.
            seedExpiredEntry(cachedSchool)

            // Client throws — refresh fails, fail-open path must engage.
            let client = stubClient { _ in .init(status: 500, body: Data()) }
            defer { DirectoryStubProtocol.reset() }

            let map = await DirectorySchoolCache.schools(for: [child], client: client)
            #expect(map["0930122Y"] == cachedSchool)
        }
    }

    @Test("refresh(rne:) failure leaves existing cached entry intact")
    func refreshFailurePreservesExistingEntry() async throws {
        try await withIsolatedCacheAsync {
            let original = makeSchool(rne: "0930122Y", mailDomains: ["monlycee.net"])
            DirectorySchoolCache.save(original)

            let client = stubClient { _ in .init(status: 500, body: Data()) }
            defer { DirectoryStubProtocol.reset() }

            do {
                _ = try await DirectorySchoolCache.refresh(rne: "0930122Y", client: client)
                Issue.record("expected refresh to throw")
            } catch {
                // Fresh entry must still be there — a failed refresh
                // must NEVER nuke a cached payload.
                #expect(DirectorySchoolCache.load(rne: "0930122Y") == original)
            }
        }
    }

    @Test("schools(for:) skips children with nil / empty rneCode — doesn't call client")
    func schoolsForSkipsUnlinkedChildren() async throws {
        try await withIsolatedCacheAsync {
            let ctx = try makeContext()
            let linked = makeChild(rne: "0930122Y", in: ctx)
            let notLinked = makeChild(rne: nil, in: ctx)
            let emptyRNE = makeChild(rne: "", in: ctx)

            // Client asserts it's only called for the linked child.
            let client = stubClient { request in
                #expect(request.url?.path.contains("0930122Y") == true,
                        "client should only be hit for the linked child — got \(request.url?.absoluteString ?? "nil")")
                return .init(status: 200, body: Self.schoolJSON(rne: "0930122Y"))
            }
            defer { DirectoryStubProtocol.reset() }

            let map = await DirectorySchoolCache.schools(for: [linked, notLinked, emptyRNE], client: client)
            #expect(map.keys.sorted() == ["0930122Y"])
        }
    }
}

// MARK: - Helpers for schools(for:) tests

extension DirectorySchoolCacheTests {

    fileprivate func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    fileprivate func makeChild(rne: String?, in ctx: ModelContext) -> Child {
        let c = Child(
            firstName: "Test",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "https://xxxxx.index-education.net/pronote",
            rneCode: rne
        )
        ctx.insert(c)
        return c
    }

    /// Wires a `DirectoryStubProtocol` handler and returns a client
    /// routed through it. Caller is responsible for `DirectoryStubProtocol.reset()`.
    fileprivate func stubClient(_ handler: @escaping @Sendable (URLRequest) -> DirectoryStubProtocol.Stub) -> DirectoryAPIClient {
        DirectoryStubProtocol.install(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectoryStubProtocol.self]
        return DirectoryAPIClient(session: URLSession(configuration: config))
    }

    /// Writes an expired cache entry directly to the isolated suite.
    /// Bypasses `save()` on purpose — the TTL test needs to seed an
    /// on-disk record with a `fetchedAt` outside the TTL window.
    fileprivate func seedExpiredEntry(_ school: DirectorySchool) {
        let expired = OnDiskEntryMirror(
            school: school,
            fetchedAt: Date(timeIntervalSinceNow: -(DirectorySchoolCache.ttlSeconds + 60))
        )
        let data = try? JSONEncoder().encode(expired)
        DirectorySchoolCache.defaults.set(data, forKey: "directory.school.\(school.rne)")
    }

    /// Minimal valid `/schools/:rne` JSON for the stub to return when a
    /// test needs the refresh path to succeed. `nonisolated` so the
    /// `@Sendable` stub handler can call it without a main-actor hop.
    nonisolated static func schoolJSON(rne: String) -> Data {
        Data(#"""
        {
          "rne": "\#(rne)",
          "name": "Test",
          "kind": "college",
          "academy": null,
          "holidayZone": null,
          "website": null,
          "commune": null,
          "ent": null,
          "services": [],
          "mailDomains": []
        }
        """#.utf8)
    }
}

// MARK: - Mirror of the cache's private `CacheEntry`

/// Exact shape of `DirectorySchoolCache.CacheEntry` — kept in sync so
/// the TTL test can seed an expired-looking record directly. The
/// `onDiskFormatMatchesMirror` test guards against drift by round-
/// tripping a real `save()` output through this mirror.
struct OnDiskEntryMirror: Codable {
    let school: DirectorySchool
    let fetchedAt: Date
}
