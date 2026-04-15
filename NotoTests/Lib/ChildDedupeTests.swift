import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for `ChildDedupe.match`. This rule is what stops QR
/// re-login from silently duplicating every kid in a family every
/// time a parent rescans — regression here would go unnoticed until
/// someone spotted "Gaston Gaston Gaston" in the child selector.
@Suite("ChildDedupe")
struct ChildDedupeTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(
        _ name: String,
        pawnoteID: String? = nil,
        schoolType: SchoolType = .pronote,
        in ctx: ModelContext
    ) -> Child {
        let c = Child(
            firstName: name,
            level: .college,
            grade: "3e",
            schoolType: schoolType,
            establishment: "Test",
            pawnoteID: pawnoteID
        )
        ctx.insert(c)
        return c
    }

    // MARK: - Empty / miss

    @Test("Empty family → nil")
    func emptyFamily() {
        let hit = ChildDedupe.match(
            in: [],
            pawnoteID: "abc",
            firstName: "Gaston",
            schoolType: .pronote
        )
        #expect(hit == nil)
    }

    @Test("Unrelated rows → nil")
    func noMatch() throws {
        let ctx = try makeContext()
        let a = makeChild("Alice", pawnoteID: "A", in: ctx)
        let hit = ChildDedupe.match(
            in: [a],
            pawnoteID: "B",
            firstName: "Bob",
            schoolType: .pronote
        )
        #expect(hit == nil)
    }

    // MARK: - pawnoteID (primary key)

    @Test("pawnoteID match wins even if firstName differs")
    func pawnoteIDOverridesName() throws {
        let ctx = try makeContext()
        // Scenario: parent edited firstName in Settings after onboarding.
        // pawnoteID is still the same → we reuse the row, preserving
        // grades/homework history.
        let existing = makeChild("Gaston", pawnoteID: "pid-1", in: ctx)
        let hit = ChildDedupe.match(
            in: [existing],
            pawnoteID: "pid-1",
            firstName: "Gastón",
            schoolType: .pronote
        )
        #expect(hit === existing)
    }

    @Test("Different pawnoteIDs → nil even if name matches")
    func differentIDs() throws {
        let ctx = try makeContext()
        // Twin brothers, same first name, different pawnote ids.
        let existing = makeChild("Jean", pawnoteID: "pid-twin-a", in: ctx)
        let hit = ChildDedupe.match(
            in: [existing],
            pawnoteID: "pid-twin-b",
            firstName: "Jean",
            schoolType: .pronote
        )
        #expect(hit == nil)
    }

    // MARK: - Composite fallback

    @Test("No pawnoteID on input → composite match on legacy row")
    func compositeFallback() throws {
        let ctx = try makeContext()
        // First run after app upgrade: existing row has no pawnoteID,
        // synthetic re-entry arrives without one either.
        let existing = makeChild("Gaston", pawnoteID: nil, in: ctx)
        let hit = ChildDedupe.match(
            in: [existing],
            pawnoteID: nil,
            firstName: "Gaston",
            schoolType: .pronote
        )
        #expect(hit === existing)
    }

    @Test("Empty string pawnoteID is treated as missing")
    func emptyStringID() throws {
        let ctx = try makeContext()
        // JS bridge can hand back "" when the field is missing — do not
        // let that match every row with a nil/empty stored id.
        let existing = makeChild("Gaston", pawnoteID: "", in: ctx)
        let hit = ChildDedupe.match(
            in: [existing],
            pawnoteID: "",
            firstName: "Gaston",
            schoolType: .pronote
        )
        // Composite still matches on name — that's the intended fallback.
        #expect(hit === existing)
    }

    @Test("Composite is case-insensitive on firstName")
    func caseInsensitive() throws {
        let ctx = try makeContext()
        let existing = makeChild("gaston", pawnoteID: nil, in: ctx)
        let hit = ChildDedupe.match(
            in: [existing],
            pawnoteID: nil,
            firstName: "GASTON",
            schoolType: .pronote
        )
        #expect(hit === existing)
    }

    @Test("Composite is scoped by schoolType")
    func schoolTypeScope() throws {
        let ctx = try makeContext()
        let entGaston = makeChild("Gaston", schoolType: .ent, in: ctx)
        let hit = ChildDedupe.match(
            in: [entGaston],
            pawnoteID: nil,
            firstName: "Gaston",
            schoolType: .pronote
        )
        #expect(hit == nil)
    }

    @Test("Composite fallback skips rows that already have a different pawnoteID")
    func compositeRespectsExistingID() throws {
        let ctx = try makeContext()
        // A row already identified with pawnote id "pid-1" must not
        // absorb a no-id composite hit — that would overwrite a real kid
        // with a synthetic one.
        let claimed = makeChild("Gaston", pawnoteID: "pid-1", in: ctx)
        let hit = ChildDedupe.match(
            in: [claimed],
            pawnoteID: nil,
            firstName: "Gaston",
            schoolType: .pronote
        )
        #expect(hit == nil)
    }

    @Test("Multiple legacy rows, composite picks the first match")
    func multipleLegacyRows() throws {
        let ctx = try makeContext()
        // Pre-existing duplication from before the fix. Dedupe picks
        // one — the fix stops *new* inserts from compounding the mess.
        // Data migration is intentionally out of scope (backlog note).
        let a = makeChild("Gaston", pawnoteID: nil, in: ctx)
        _ = makeChild("Gaston", pawnoteID: nil, in: ctx)
        let hit = ChildDedupe.match(
            in: [a, makeChild("Gaston", pawnoteID: nil, in: ctx)],
            pawnoteID: nil,
            firstName: "Gaston",
            schoolType: .pronote
        )
        #expect(hit === a)
    }
}
