import Testing
import Foundation
import SwiftData
@testable import Noto

/// Pins the two `Child` predicates that drive the launch-time initial sync
/// and the "première synchronisation" cards. `needsInitialSync` replaced an
/// "all relationships empty" heuristic that could never become false for
/// ENT children (their sync never writes grades or schedule), so the app
/// re-synced them on every Home appearance.
@Suite("Child sync state")
struct ChildSyncStateTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(in context: ModelContext, schoolType: SchoolType = .ent) -> Child {
        let child = Child(
            firstName: "Test",
            level: .elementaire,
            grade: "CE1",
            schoolType: schoolType,
            establishment: "École Test"
        )
        context.insert(child)
        return child
    }

    @Test("A new child needs its initial sync")
    func newChildNeedsInitialSync() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        #expect(child.lastSyncedAt == nil)
        #expect(child.needsInitialSync)
    }

    @Test("markSynced clears needsInitialSync even with no data")
    func markSyncedClearsPending() throws {
        let context = try makeContext()
        let child = makeChild(in: context)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        child.markSynced(at: stamp)
        #expect(child.lastSyncedAt == stamp)
        #expect(!child.needsInitialSync)
        #expect(child.grades.isEmpty && child.homework.isEmpty && child.schedule.isEmpty)
    }

    @Test("isDirectPronote: QR-login Pronote only")
    func directPronotePredicate() throws {
        let context = try makeContext()

        let qr = makeChild(in: context, schoolType: .pronote)
        #expect(qr.isDirectPronote)

        let viaMonLycee = makeChild(in: context, schoolType: .pronote)
        viaMonLycee.entProvider = .monlycee
        #expect(!viaMonLycee.isDirectPronote)

        let ent = makeChild(in: context, schoolType: .ent)
        ent.entProvider = .pcn
        #expect(!ent.isDirectPronote)

        #expect(!makeChild(in: context, schoolType: .ecoledirecte).isDirectPronote)
        #expect(!makeChild(in: context, schoolType: .skolengo).isDirectPronote)
    }
}
