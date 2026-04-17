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

    private func makeChild(in ctx: ModelContext, level: SchoolLevel = .college) -> Child {
        let c = Child(
            firstName: "Gaston",
            level: level,
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
        seedUnread(count: 5, on: child, ctx: ctx)
        #expect(WellbeingEngine.detect(for: child) == nil)
    }

    @Test("Two factors aligned → .notable severity signal")
    func twoFactorsEmitNotable() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal != nil)
        #expect(signal?.severity == .notable)
        #expect(signal?.factors.count == 2)
    }

    @Test("Three factors aligned → .urgent severity signal")
    func threeFactorsEmitUrgent() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        seedGradeDecline(child: child, ctx: ctx, now: now)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.severity == .urgent)
        #expect(signal?.factors.count == 3)
    }

    // MARK: - WellbeingSignal invariant

    @Test("make() returns nil for fewer than 2 factors")
    func makeEnforcesMinimumFactors() {
        let zero = WellbeingSignal.make(childName: "Test", childLevel: .college, factors: [])
        #expect(zero == nil)
        let one = WellbeingSignal.make(
            childName: "Test",
            childLevel: .college,
            factors: [WellbeingFactor(kind: .unreadBacklog(count: 3))]
        )
        #expect(one == nil)
    }

    @Test("make() returns a valid signal for exactly 2 factors")
    func makeAcceptsExactlyTwoFactors() {
        let factors: [WellbeingFactor] = [
            WellbeingFactor(kind: .unreadBacklog(count: 4)),
            WellbeingFactor(kind: .homeworkBacklog(undone: 3, total: 4))
        ]
        let signal = WellbeingSignal.make(childName: "Gaston", childLevel: .college, factors: factors)
        #expect(signal != nil)
        #expect(signal?.severity == .notable)
    }

    @Test("severity is .urgent for exactly 3 factors (independent of detector pipeline)")
    func severityAtExactlyThreeFactors() {
        let factors: [WellbeingFactor] = [
            WellbeingFactor(kind: .unreadBacklog(count: 4)),
            WellbeingFactor(kind: .homeworkBacklog(undone: 3, total: 4)),
            WellbeingFactor(kind: .sustainedGradeDecline(subjects: ["Maths"], average: 8.0))
        ]
        let signal = WellbeingSignal.make(childName: "Gaston", childLevel: .college, factors: factors)
        #expect(signal?.severity == .urgent)
    }

    // MARK: - Batch API

    @Test("detect(for: []) returns empty — no crash for unenrolled family")
    func detectForEmptyChildren() {
        #expect(WellbeingEngine.detect(for: []).isEmpty)
    }

    @Test("detect(for: children) returns signal only for children with ≥2 factors")
    func detectForChildrenFiltersCorrectly() throws {
        let ctx = try makeContext()
        let now = Date.now
        let loud = makeChild(in: ctx)
        let quiet = makeChild(in: ctx)

        seedUnread(count: 4, on: loud, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: loud)

        let signals = WellbeingEngine.detect(for: [loud, quiet], now: now)
        #expect(signals.count == 1)
        #expect(signals.first?.childName == "Gaston")
    }

    // MARK: - Detector calibration

    @Test("Grade decline needs avg < 10 AND ≥2 difficulty insights")
    func gradeDeclineRequiresBothConditions() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        for i in 0..<4 {
            let g = Grade(subject: "Maths", value: 7.0, outOf: 20, date: daysAgo(i * 3, from: now))
            ctx.insert(g)
            g.child = child
        }
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)

        let insightA = Insight(type: .difficulty, subject: "Maths", value: "en baisse", confidence: 0.8)
        ctx.insert(insightA)
        insightA.child = child
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)

        let insightB = Insight(type: .difficulty, subject: "Histoire", value: "en baisse", confidence: 0.8)
        ctx.insert(insightB)
        insightB.child = child
        let factor = WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now))
        #expect(factor != nil)
        // Structured kind carries the numeric average — no French string parsing needed.
        if case let .sustainedGradeDecline(_, avg) = factor?.kind {
            #expect(avg < 10)
        } else {
            Issue.record("Expected .sustainedGradeDecline kind")
        }
    }

    @Test("Grade decline returns nil for fewer than 3 grades (count boundary)")
    func gradeDeclineCountBoundary() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // 2 grades + 2 difficulty insights — count guard fires first.
        for i in 0..<2 {
            let g = Grade(subject: "Maths", value: 6.0, outOf: 20, date: daysAgo(i * 3, from: now))
            ctx.insert(g)
            g.child = child
        }
        let insightA = Insight(type: .difficulty, subject: "Maths", value: "en baisse", confidence: 0.8)
        let insightB = Insight(type: .difficulty, subject: "Histoire", value: "en baisse", confidence: 0.8)
        ctx.insert(insightA); insightA.child = child
        ctx.insert(insightB); insightB.child = child

        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)

        // Adding the 3rd grade should make it fire.
        let g3 = Grade(subject: "Maths", value: 6.0, outOf: 20, date: daysAgo(9, from: now))
        ctx.insert(g3); g3.child = child
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) != nil)
    }

    @Test("Grade decline uses coefficient-weighted average, not plain mean")
    func gradeDeclineUsesWeightedAverage() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // Low-coefficient bad grades (coeff 1) + high-coefficient good grade (coeff 5).
        // Weighted avg = (6+6+6 + 15*5) / (3 + 5) = 93 / 8 ≈ 11.6 → above threshold.
        // Unweighted avg = (6+6+6+15) / 4 = 8.25 → would fire incorrectly.
        let highCoeff = Grade(subject: "DS", value: 15.0, outOf: 20, coefficient: 5, date: daysAgo(3, from: now))
        ctx.insert(highCoeff); highCoeff.child = child
        for i in 1...3 {
            let g = Grade(subject: "Oral", value: 6.0, outOf: 20, coefficient: 1, date: daysAgo(i * 5, from: now))
            ctx.insert(g); g.child = child
        }
        let insightA = Insight(type: .difficulty, subject: "Maths", value: "en baisse", confidence: 0.8)
        let insightB = Insight(type: .difficulty, subject: "Histoire", value: "en baisse", confidence: 0.8)
        ctx.insert(insightA); insightA.child = child
        ctx.insert(insightB); insightB.child = child

        // Weighted avg > 10 → no factor.
        #expect(WellbeingEngine.detectGradeDecline(child: child, windowStart: daysAgo(28, from: now)) == nil)
    }

    @Test("Homework backlog skips future items, counts only past-due")
    func homeworkBacklogSkipsFutureItems() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        for i in 0..<5 {
            let hw = Homework(subject: "Maths", description: "ex \(i)", dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: now)!)
            ctx.insert(hw)
            hw.child = child
        }
        #expect(WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)

        for i in 0..<4 {
            let hw = Homework(subject: "Maths", description: "past \(i)", dueDate: daysAgo(i + 1, from: now))
            hw.done = (i == 0)
            ctx.insert(hw)
            hw.child = child
        }
        let factor = WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now)
        #expect(factor != nil)
        if case let .homeworkBacklog(undone, total) = factor?.kind {
            #expect(undone == 3)
            #expect(total == 4)
        } else {
            Issue.record("Expected .homeworkBacklog kind")
        }
    }

    @Test("Homework backlog returns nil for exactly 3 past-due items (count boundary)")
    func homeworkBacklogCountBoundary() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        for i in 0..<3 {
            let hw = Homework(subject: "Maths", description: "past \(i)", dueDate: daysAgo(i + 1, from: now))
            hw.done = false
            ctx.insert(hw); hw.child = child
        }
        #expect(WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)
    }

    @Test("Homework backlog returns nil when ratio is exactly 50% (strictly greater than, not ≥)")
    func homeworkBacklogExactHalfRatio() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // 2 undone out of 4 past-due = ratio 0.5 exactly → must not fire.
        for i in 0..<4 {
            let hw = Homework(subject: "Maths", description: "past \(i)", dueDate: daysAgo(i + 1, from: now))
            hw.done = (i < 2)
            ctx.insert(hw); hw.child = child
        }
        #expect(WellbeingEngine.detectHomeworkBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)
    }

    @Test("Unread backlog requires ≥ minimum threshold (default 3)")
    func unreadBacklogThreshold() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        seedUnread(count: 2, on: child, ctx: ctx, now: now)
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)

        seedUnread(count: 1, on: child, ctx: ctx, now: now)
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) != nil)
    }

    @Test("Unread backlog respects custom minimum parameter")
    func unreadBacklogCustomMinimum() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now, minimum: 5) == nil)
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now, minimum: 4) != nil)
    }

    @Test("Stale unread messages outside observation window are excluded")
    func unreadBacklogExcludesStaleMessages() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        // 5 unread messages from 60 days ago (outside the 28-day window).
        for i in 0..<5 {
            let m = Message(
                sender: "Old Prof \(i)",
                subject: "Stale \(i)",
                body: "",
                date: daysAgo(60 + i, from: now),
                source: .pronote
            )
            m.read = false
            ctx.insert(m); m.child = child
        }
        #expect(WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now) == nil)
    }

    // MARK: - WellbeingFactor.Kind structured data

    @Test("Factor kind carries typed associated values, not string blobs")
    func factorKindAssociatedValues() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let now = Date.now
        seedUnread(count: 5, on: child, ctx: ctx, now: now)
        let factor = WellbeingEngine.detectUnreadBacklog(child: child, windowStart: daysAgo(28, from: now), now: now)
        if case let .unreadBacklog(count) = factor?.kind {
            #expect(count == 5)
        } else {
            Issue.record("Expected .unreadBacklog(count:) kind")
        }
    }

    // MARK: - Signal shape

    @Test("Signal subtitle joins factor details with bullet separator")
    func subtitleFormat() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.subtitle.contains(" · ") == true)
    }

    @Test("Title carries the child's first name, not a generic label")
    func titleIsPersonalised() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx)
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        let signal = WellbeingEngine.detect(for: child, now: now)
        #expect(signal?.title.contains("Gaston") == true)
    }

    @Test("Signal childLevel reflects the child's school level")
    func signalCarriesChildLevel() throws {
        let ctx = try makeContext()
        let now = Date.now
        let child = makeChild(in: ctx, level: .lycee)
        seedUnread(count: 4, on: child, ctx: ctx, now: now)
        seedHomeworkBacklog(undone: 3, doneTotal: 2, windowStart: daysAgo(21, from: now), ctx: ctx, child: child)
        #expect(WellbeingEngine.detect(for: child, now: now)?.childLevel == .lycee)
    }

    // MARK: - Helpers (test-scope seeding)

    private func seedUnread(count: Int, on child: Child, ctx: ModelContext, now: Date = .now) {
        for i in 0..<count {
            let m = Message(
                sender: "Prof \(i)",
                subject: "Message \(i)",
                body: "",
                date: Calendar.current.date(byAdding: .day, value: -(i + 1), to: now)!,
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

// MARK: - BriefingEngine integration

@Suite("BriefingEngine+Wellbeing")
@MainActor
struct BriefingEngineWellbeingTests {

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

    /// Verifies that when two factors fire, `buildSchoolCards` emits exactly
    /// one `.wellbeing` card with a non-nil `wellbeing` payload. The non-nil
    /// invariant is load-bearing: `HomeView.handleCardTap` reads `card.wellbeing`
    /// directly — a nil payload silently opens an empty resource sheet.
    @Test("buildBriefing emits .wellbeing card with non-nil payload when two factors fire")
    func wellbeingCardEmittedWithPayload() async throws {
        let ctx = try makeContext()
        let engine = BriefingEngine(modelContext: ctx)
        let child = makeChild(in: ctx)
        let now = Date.now

        // Seed two factors.
        for i in 0..<4 {
            let m = Message(sender: "Prof \(i)", subject: "Msg \(i)", body: "",
                            date: Calendar.current.date(byAdding: .day, value: -(i + 1), to: now)!,
                            source: .pronote)
            m.read = false
            ctx.insert(m); m.child = child
        }
        let windowStart = daysAgo(21, from: now)
        for i in 0..<3 {
            let hw = Homework(subject: "Maths", description: "undone \(i)",
                              dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: windowStart)!)
            hw.done = false
            ctx.insert(hw); hw.child = child
        }
        for i in 0..<2 {
            let hw = Homework(subject: "Français", description: "done \(i)",
                              dueDate: Calendar.current.date(byAdding: .day, value: i + 1, to: windowStart)!)
            hw.done = true
            ctx.insert(hw); hw.child = child
        }

        await engine.buildBriefing(for: child)

        let wellbeingCards = engine.cards.filter { $0.type == .wellbeing }
        #expect(wellbeingCards.count == 1, "Expected exactly one .wellbeing card")
        #expect(wellbeingCards.first?.wellbeing != nil, ".wellbeing card must carry a non-nil WellbeingSignal payload")
        #expect(wellbeingCards.first?.priority == .normal)
    }

    @Test("buildBriefing emits no .wellbeing card when only one factor fires")
    func noWellbeingCardForSingleFactor() async throws {
        let ctx = try makeContext()
        let engine = BriefingEngine(modelContext: ctx)
        let child = makeChild(in: ctx)
        let now = Date.now

        for i in 0..<5 {
            let m = Message(sender: "Prof \(i)", subject: "Msg \(i)", body: "",
                            date: Calendar.current.date(byAdding: .day, value: -(i + 1), to: now)!,
                            source: .pronote)
            m.read = false
            ctx.insert(m); m.child = child
        }

        await engine.buildBriefing(for: child)
        #expect(engine.cards.filter { $0.type == .wellbeing }.isEmpty)
    }
}
