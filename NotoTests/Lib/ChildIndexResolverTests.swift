import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for `ChildIndexResolver`. This is what prevents
/// `HomeView.performFullRefresh` from writing one kid's grades onto
/// another kid whenever SwiftData order diverges from pawnote order.
@Suite("ChildIndexResolver")
struct ChildIndexResolverTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(
        firstName: String,
        pawnoteID: String? = nil,
        in ctx: ModelContext
    ) -> Child {
        let c = Child(
            firstName: firstName,
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "Test",
            pawnoteID: pawnoteID
        )
        ctx.insert(c)
        return c
    }

    private func pc(_ id: String, _ name: String, _ className: String = "3e A") -> PronoteChildResource {
        PronoteChildResource(id: id, name: name, className: className, establishment: "")
    }

    // MARK: - Primary (pawnoteID)

    @Test("pawnoteID match returns its pawnote index")
    func pawnoteIDMatch() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: "pid-2", in: ctx)
        let pawnote = [
            pc("pid-1", "DUPONT Alice"),
            pc("pid-2", "DUPONT Gaston"),
            pc("pid-3", "DUPONT Louis"),
        ]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 1)
    }

    @Test("pawnoteID match wins even if names shift (parent renamed in Settings)")
    func pawnoteIDOverridesName() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gastounet", pawnoteID: "pid-1", in: ctx)
        let pawnote = [pc("pid-1", "DUPONT Gaston")]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 0)
    }

    // MARK: - Fallback (firstName)

    @Test("Nil pawnoteID falls back to firstName match")
    func legacyFallback() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: nil, in: ctx)
        let pawnote = [
            pc("pid-1", "DUPONT Alice"),
            pc("pid-2", "DUPONT Gaston"),
        ]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 1)
    }

    @Test("Empty-string pawnoteID is treated as missing, falls back to name")
    func emptyIDFallback() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: "", in: ctx)
        let pawnote = [pc("pid-x", "DUPONT Gaston")]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 0)
    }

    @Test("Case-insensitive name match")
    func caseInsensitive() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "gaston", pawnoteID: nil, in: ctx)
        let pawnote = [pc("pid-1", "DUPONT GASTON")]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 0)
    }

    @Test("Stored pawnoteID missing from session, falls back to name")
    func staleIDFallback() throws {
        // Stored id is stale (school moved the kid, pawnote session has
        // a fresh id list). Resolver should fall back to name matching
        // rather than return nil and strand the sync.
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: "pid-gone", in: ctx)
        let pawnote = [pc("pid-new", "DUPONT Gaston")]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == 0)
    }

    // MARK: - Miss

    @Test("No match at all returns nil")
    func noMatch() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: "pid-gone", in: ctx)
        let pawnote = [pc("pid-1", "DUPONT Alice")]
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnote) == nil)
    }

    @Test("Empty pawnote list returns nil")
    func emptySession() throws {
        let ctx = try makeContext()
        let child = makeChild(firstName: "Gaston", pawnoteID: "pid-1", in: ctx)
        #expect(ChildIndexResolver.resolve(child: child, pawnoteChildren: []) == nil)
    }

    // MARK: - Ordering regression guard

    @Test("Resolution is stable when SwiftData order diverges from pawnote order")
    func orderDivergence() throws {
        // Canonical bug scenario: SwiftData rows are in insertion order
        // (Alice → Gaston), but pawnote session returned the kids in
        // a different order (Gaston at index 0, Alice at index 1).
        // enumerated() would sync Alice's data into Gaston's row.
        let ctx = try makeContext()
        let alice = makeChild(firstName: "Alice", pawnoteID: "pid-a", in: ctx)
        let gaston = makeChild(firstName: "Gaston", pawnoteID: "pid-g", in: ctx)
        let pawnote = [
            pc("pid-g", "DUPONT Gaston"),
            pc("pid-a", "DUPONT Alice"),
        ]
        #expect(ChildIndexResolver.resolve(child: alice, pawnoteChildren: pawnote) == 1)
        #expect(ChildIndexResolver.resolve(child: gaston, pawnoteChildren: pawnote) == 0)
    }

    // MARK: - firstName transform

    @Test("firstName(from:) drops leading LASTNAME token")
    func firstNameTransform() {
        #expect(ChildIndexResolver.firstName(from: "DUPONT Gaston") == "Gaston")
    }

    @Test("firstName(from:) on single-word input returns the word unchanged")
    func firstNameSingleWord() {
        // Pawnote occasionally returns just the first name for single-child accounts.
        #expect(ChildIndexResolver.firstName(from: "Gaston") == "Gaston")
    }

    @Test("firstName(from:) on compound firstName keeps everything after the first word")
    func firstNameCompound() {
        // "DUPONT Jean Pierre" → "Jean Pierre"
        #expect(ChildIndexResolver.firstName(from: "DUPONT Jean Pierre") == "Jean Pierre")
    }
}
