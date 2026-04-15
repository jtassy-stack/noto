import Testing
import Foundation
import SwiftData
@testable import Noto

/// Truth table for the `Child.hasAlert` rule that now drives both
/// `ChildSelectorBar` and `ChildStoryRing` alert dots. If this rule
/// drifts (e.g. someone relaxes the 24h window or the <10 threshold),
/// both surfaces silently show wrong state — exactly the binary
/// "everything OK?" signal Sophie M. relies on.
@Suite("Child.hasAlert")
struct ChildHasAlertTests {

    // MARK: - Container

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Family.self,
            Child.self,
            Grade.self,
            ScheduleEntry.self,
            Homework.self,
            Message.self,
            SchoolPhoto.self,
            Insight.self,
            CultureReco.self,
            Curriculum.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeChild(in context: ModelContext) -> Child {
        let child = Child(
            firstName: "Test",
            level: .college,
            grade: "3e",
            schoolType: .pronote,
            establishment: "Test"
        )
        context.insert(child)
        return child
    }

    // MARK: - Baseline

    @Test("Empty child has no alert")
    func empty() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        #expect(child.hasAlert == false)
    }

    // MARK: - Homework

    @Test("Undone homework due in < 24h triggers alert")
    func urgentHomework() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let hw = Homework(subject: "Maths", description: "Ex", dueDate: .now.addingTimeInterval(12 * 3600))
        hw.child = child
        ctx.insert(hw)
        #expect(child.hasAlert == true)
    }

    @Test("Done homework due soon does not trigger alert")
    func doneHomework() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let hw = Homework(subject: "Maths", description: "Ex", dueDate: .now.addingTimeInterval(12 * 3600))
        hw.done = true
        hw.child = child
        ctx.insert(hw)
        #expect(child.hasAlert == false)
    }

    @Test("Homework due beyond 24h does not trigger alert")
    func distantHomework() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let hw = Homework(subject: "Maths", description: "Ex", dueDate: .now.addingTimeInterval(48 * 3600))
        hw.child = child
        ctx.insert(hw)
        #expect(child.hasAlert == false)
    }

    // MARK: - Messages

    @Test("Unread message triggers alert")
    func unreadMessage() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let msg = Message(sender: "Prof", subject: "Hi", body: "", date: .now, source: .pronote)
        // Message.init sets read = false by default
        msg.child = child
        ctx.insert(msg)
        #expect(child.hasAlert == true)
    }

    @Test("All messages read: no alert")
    func allMessagesRead() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let msg = Message(sender: "Prof", subject: "Hi", body: "", date: .now, source: .pronote)
        msg.read = true
        msg.child = child
        ctx.insert(msg)
        #expect(child.hasAlert == false)
    }

    // MARK: - Grades

    @Test("Recent grade < 10 triggers alert")
    func recentLowGrade() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let grade = Grade(subject: "Maths", value: 8, outOf: 20, date: .now.addingTimeInterval(-3 * 86_400))
        grade.child = child
        ctx.insert(grade)
        #expect(child.hasAlert == true)
    }

    @Test("Recent grade exactly at 10 does not trigger alert")
    func boundaryGrade10() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        // Strict < 10 per the rule
        let grade = Grade(subject: "Maths", value: 10, outOf: 20, date: .now)
        grade.child = child
        ctx.insert(grade)
        #expect(child.hasAlert == false)
    }

    @Test("Low grade older than 7 days does not trigger alert")
    func oldLowGrade() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        let grade = Grade(subject: "Maths", value: 5, outOf: 20, date: .now.addingTimeInterval(-8 * 86_400))
        grade.child = child
        ctx.insert(grade)
        #expect(child.hasAlert == false)
    }

    @Test("Low grade on a non-/20 scale still normalizes (6/10 = 12/20, no alert)")
    func scaleNormalization() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        // 6/10 normalizes to 12/20 — above the < 10 threshold
        let grade = Grade(subject: "Maths", value: 6, outOf: 10, date: .now)
        grade.child = child
        ctx.insert(grade)
        #expect(child.hasAlert == false)
    }

    // MARK: - Combined

    @Test("Multiple signals: any one is enough")
    func anyTriggersAlert() throws {
        let ctx = try makeContext()
        let child = makeChild(in: ctx)
        // Only an unread message, no homework or grades
        let msg = Message(sender: "Prof", subject: "Hi", body: "", date: .now, source: .ent)
        msg.child = child
        ctx.insert(msg)
        #expect(child.hasAlert == true)
    }
}
