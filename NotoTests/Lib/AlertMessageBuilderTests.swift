import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for the parent-facing alert strings. The builder drives the
/// only non-binary signal on the Home banner, so pluralisation,
/// ordering, and boundary behavior need to be pinned.
@Suite("AlertMessageBuilder")
struct AlertMessageBuilderTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Family.self,
            Child.self,
            Grade.self,
            Homework.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(_ name: String = "Gaston", in context: ModelContext) -> Child {
        let child = Child(
            firstName: name,
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "Test"
        )
        context.insert(child)
        return child
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Empty

    @Test("No children → empty")
    func empty() {
        #expect(AlertMessageBuilder.messages(for: [], now: now).isEmpty)
    }

    @Test("Child with nothing → empty")
    func childWithNothing() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        #expect(AlertMessageBuilder.messages(for: [child], now: now).isEmpty)
    }

    // MARK: - Homework pluralisation

    @Test("1 urgent homework → singular line")
    func singularHomework() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let hw = Homework(subject: "maths", description: "Ex", dueDate: now.addingTimeInterval(3600))
        hw.child = child
        ctx.insert(hw)

        let msgs = AlertMessageBuilder.messages(for: [child], now: now)
        #expect(msgs == ["Gaston a 1 devoir de Maths pour demain"])
    }

    @Test("3 urgent homeworks → plural line, first 3 subjects listed")
    func threeHomeworks() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        for (idx, subject) in ["maths", "français", "histoire"].enumerated() {
            let hw = Homework(
                subject: subject,
                description: "Ex",
                dueDate: now.addingTimeInterval(Double(idx + 1) * 3600)
            )
            hw.child = child
            ctx.insert(hw)
        }

        let msgs = AlertMessageBuilder.messages(for: [child], now: now)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("Gaston a 3 devoirs pour demain"))
        #expect(msgs[0].contains("Maths"))
        #expect(msgs[0].contains("Français"))
        #expect(msgs[0].contains("Histoire"))
    }

    @Test("5 urgent homeworks → count is 5, only first 3 subjects shown")
    func fiveHomeworks() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        for (idx, subject) in ["maths", "français", "histoire", "svt", "anglais"].enumerated() {
            let hw = Homework(
                subject: subject,
                description: "Ex",
                dueDate: now.addingTimeInterval(Double(idx + 1) * 3600)
            )
            hw.child = child
            ctx.insert(hw)
        }

        let msgs = AlertMessageBuilder.messages(for: [child], now: now)
        #expect(msgs.count == 1)
        #expect(msgs[0].contains("5 devoirs"))
        // The prefix(3) cap means SVT and Anglais should NOT appear in the
        // subject preview — pinning current behavior.
        #expect(!msgs[0].contains("Svt"))
        #expect(!msgs[0].contains("Anglais"))
    }

    @Test("Done homework does not count as urgent")
    func doneHomeworkIgnored() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let hw = Homework(subject: "maths", description: "Ex", dueDate: now.addingTimeInterval(3600))
        hw.done = true
        hw.child = child
        ctx.insert(hw)

        #expect(AlertMessageBuilder.messages(for: [child], now: now).isEmpty)
    }

    // MARK: - Grade pluralisation

    @Test("1 recent low grade → singular 'note'")
    func singularLowGrade() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let g = Grade(subject: "maths", value: 7, outOf: 20, date: now.addingTimeInterval(-86_400))
        g.child = child
        ctx.insert(g)

        let msgs = AlertMessageBuilder.messages(for: [child], now: now)
        #expect(msgs == ["Gaston a 1 note sous 10 cette semaine"])
    }

    @Test("3 recent low grades → plural 'notes'")
    func pluralLowGrades() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        for v in [5.0, 7.0, 8.5] {
            let g = Grade(subject: "maths", value: v, outOf: 20, date: now.addingTimeInterval(-86_400))
            g.child = child
            ctx.insert(g)
        }
        let msgs = AlertMessageBuilder.messages(for: [child], now: now)
        #expect(msgs == ["Gaston a 3 notes sous 10 cette semaine"])
    }

    @Test("Grade older than 7 days excluded")
    func oldGradeIgnored() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let g = Grade(subject: "maths", value: 5, outOf: 20, date: now.addingTimeInterval(-10 * 86_400))
        g.child = child
        ctx.insert(g)
        #expect(AlertMessageBuilder.messages(for: [child], now: now).isEmpty)
    }

    // MARK: - Ordering (stability)

    @Test("Ordering: all homework lines before any grade lines")
    func stableOrdering() throws {
        let ctx = try makeContext()
        let a = makeChild("Alice", in: ctx)
        let b = makeChild("Bob", in: ctx)

        let hwA = Homework(subject: "maths", description: "Ex", dueDate: now.addingTimeInterval(3600))
        hwA.child = a
        ctx.insert(hwA)

        let gB = Grade(subject: "maths", value: 5, outOf: 20, date: now.addingTimeInterval(-86_400))
        gB.child = b
        ctx.insert(gB)

        let msgs = AlertMessageBuilder.messages(for: [a, b], now: now)
        #expect(msgs.count == 2)
        #expect(msgs[0].contains("Alice") && msgs[0].contains("devoir"))
        #expect(msgs[1].contains("Bob") && msgs[1].contains("note"))
    }
}
