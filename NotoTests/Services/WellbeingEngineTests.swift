import Testing
import Foundation
import SwiftData
@testable import Noto

/// Coverage for `WellbeingEngine`. Every test exercises the pure
/// detection logic via an in-memory SwiftData container — the engine
/// never hits the network.
///
/// The load-bearing invariant is the **two-factor threshold**: a single
/// bad week must not emit a signal, because the downstream UI is a
/// resource sheet that would feel heavy-handed otherwise.
@Suite("WellbeingEngine")
@MainActor
struct WellbeingEngineTests {

    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Grade.self, Homework.self, Message.self, Insight.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(in ctx: ModelContext) -> Child {
        let c = Child(
            firstName: "Gaston",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "Collège Test"
        )
        ctx.insert(c)
        return c
    }

    private func daysAgo(_ n: Int, from ref: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: ref) ?? ref
    }

    // MARK: - Threshold behaviour

    @Test("Zero factors → nil signal (no false positive)")
    func noFactorsYieldsNil() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        #expect(WellbeingEngine.detect(for: child) == nil)
    }

    @Test("Single factor → nil signal (threshold guard)")
    func singleFactorBelowThreshold() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        // Seed only unread backlog — 1 factor.
        seedUnread(count: 5, on: child, ctx: ctx)
        #expect(WellbeingEngine.detect(for: child) == nil)
    }

    @Test("Two factors aligned → .normal severity signal")
    func twoFactorsEmitNormal() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal != nil)
        #expect(signal?.severity == .normal)
        #expect(signal?.factors.count == 2)
    }

    @Test("Three factors aligned → .urgent severity signal")
    func threeFactorsEmitUrgent() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        seedGradeDecline(child: child, ctx: ctx, now: now)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.severity == .urgent)
        #expect(signal?.factors.count == 3)
    }

    // MARK: - Detector calibration

    @Test("Grade decline needs avg < 10 AND ≥2 difficulty insights")
    func gradeDeclineRequiresBothConditions() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // Low average alone (no difficulty insights) → nothing.
        for i in 0..<4 {
            let g = Grade(subject: "Maths", value: 7.0, outOf: 20, date: daysAgo(i * 3, from: now))
            ctx.insert(g)
            g.child = child
        }
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)

        // Add one difficulty insight — still one subject, below threshold.
        let insightA = Insight(type: .difficulty, subject: "Maths", value: "en baisse", confidence: 0.8)
        ctx.insert(insightA)
        insightA.child = child
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)

        // Second difficulty subject → factor fires.
        let insightB = Insight(type: .difficulty, subject: "Histoire", value: "en baisse", confidence: 0.8)
        ctx.insert(insightB)
        insightB.child = child
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) != nil)
    }

    @Test("Homework backlog needs >50% undone on past-due items only")
    func homeworkBacklogSkipsFutureItems() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // 5 future items — all undone but due in future → must be ignored.
        for i in 0..<5 {
            let hw = Homework(subject: "Maths", description: "ex \(i)", dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: now)!)
            ctx.insert(hw)
            hw.child = child
        }
        #expect(WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)

        // Add 4 past-due, 3 undone → ratio 0.75 > 0.5 → factor fires.
        for i in 0..<4 {
            let hw = Homework(subject: "Maths", description: "past \(i)", dueDate: daysAgo(i + 1, from: now))
            hw.done = (i == 0)  // only the first is done
            ctx.insert(hw)
            hw.child = child
        }
        #expect(WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) != nil)
    }

    @Test("Unread backlog requires ≥ minimum threshold (default 3)")
    func unreadBacklogThreshold() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        seedUnread(count: 2, on: child, ctx: ctx)
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, now: .now) == nil)

        seedUnread(count: 1, on: child, ctx: ctx)  // total 3
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, now: .now) != nil)
    }

    // MARK: - Signal shape

    @Test("Signal subtitle joins factor details with bullet separator")
    func subtitleFormat() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.subtitle.contains(" · ") == true)
    }

    @Test("Title carries the child's first name, not a generic label")
    func titleIsPersonalised() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.title.contains("Gaston") == true)
    }

    // MARK: - Helpers (test-scope seeding)

    private func seedUnread(count: Int, on child: Child, ctx: ModelContext) {
        for i in 0..<count {
            let m = Message(
                sender: "Prof \(i)",
                subject: "Message \(i)",
                body: "",
                date: .now,
                source: .pronote
            )
            m.read = false
            ctx.insert(m)
            m.child = child
        }
    }

    private func seedHomeworkBacklog(undone: Int, doneTotal: Int, windowStart: Date, ctx: ModelContext, child: Child) {
        for i in 0..<undone {
            let hw = Homework(
                subject: "Maths",
                description: "undone \(i)",
                dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: windowStart)!
            )
            hw.done = false
            ctx.insert(hw)
            hw.child = child
        }
        for i in 0..<doneTotal {
            let hw = Homework(
                subject: "Français",
                description: "done \(i)",
                dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: windowStart)!
            )
            hw.done = true
            ctx.insert(hw)
            hw.child = child
        }
    }

    private func seedGradeDecline(child: Child, ctx: ModelContext, now: Date) {
        for i in 0..<4 {
            let g = Grade(subject: "Maths", value: 6.0, outOf: 20, date: daysAgo(i * 3, from: now))
            ctx.insert(g)
            g.child = child
        }
        let insightA = Insight(type: .difficulty, subject: "Maths", value: "en baisse", confidence: 0.8)
        let insightB = Insight(type: .difficulty, subject: "Histoire", value: "en baisse", confidence: 0.8)
        ctx.insert(insightA)
        ctx.insert(insightB)
        insightA.child = child
        insightB.child = child
    }
}
