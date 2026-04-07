import Foundation

/// Tools that Apple FoundationModels can call during briefing generation.
/// Each tool provides structured school/culture data to the on-device LLM.
///
/// On iOS 26+, FoundationModels supports @Generable tool calling:
/// the model can request data mid-generation and incorporate it naturally.

// MARK: - Tool Definitions

/// Tool: Get today's schedule for a child
struct ScheduleTool {
    let child: Child

    func call() -> ScheduleToolResult {
        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let todayLessons = child.schedule
            .filter { $0.start >= today && $0.start < tomorrow }
            .sorted { $0.start < $1.start }

        return ScheduleToolResult(
            lessonCount: todayLessons.count,
            cancelledCount: todayLessons.filter(\.cancelled).count,
            lessons: todayLessons.map { lesson in
                LessonSummary(
                    subject: lesson.subject,
                    start: lesson.start,
                    end: lesson.end,
                    cancelled: lesson.cancelled,
                    room: lesson.room,
                    chapter: lesson.chapter
                )
            }
        )
    }
}

struct ScheduleToolResult: Codable {
    let lessonCount: Int
    let cancelledCount: Int
    let lessons: [LessonSummary]
}

struct LessonSummary: Codable {
    let subject: String
    let start: Date
    let end: Date
    let cancelled: Bool
    let room: String?
    let chapter: String?
}

/// Tool: Get recent grades and trends for a child
struct GradesTool {
    let child: Child

    func call() -> GradesToolResult {
        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: .now)!

        let recentGrades = child.grades
            .filter { $0.date >= twoWeeksAgo }
            .sorted { $0.date > $1.date }

        let insights = child.insights
            .filter { $0.type == .difficulty || $0.type == .strength || $0.type == .trend }

        return GradesToolResult(
            recentGrades: recentGrades.prefix(10).map { grade in
                GradeSummary(
                    subject: grade.subject,
                    value: grade.normalizedValue,
                    date: grade.date,
                    chapter: grade.chapter
                )
            },
            difficulties: insights.filter { $0.type == .difficulty }.map {
                InsightSummary(subject: $0.subject, description: $0.value)
            },
            strengths: insights.filter { $0.type == .strength }.map {
                InsightSummary(subject: $0.subject, description: $0.value)
            },
            trends: insights.filter { $0.type == .trend }.map {
                InsightSummary(subject: $0.subject, description: $0.value)
            }
        )
    }
}

struct GradesToolResult: Codable {
    let recentGrades: [GradeSummary]
    let difficulties: [InsightSummary]
    let strengths: [InsightSummary]
    let trends: [InsightSummary]
}

struct GradeSummary: Codable {
    let subject: String
    let value: Double
    let date: Date
    let chapter: String?
}

struct InsightSummary: Codable {
    let subject: String
    let description: String
}

/// Tool: Get upcoming homework
struct HomeworkTool {
    let child: Child

    func call() -> HomeworkToolResult {
        let upcoming = child.homework
            .filter { !$0.done && $0.dueDate >= .now }
            .sorted { $0.dueDate < $1.dueDate }

        return HomeworkToolResult(
            totalPending: upcoming.count,
            items: upcoming.prefix(5).map { hw in
                HomeworkSummary(
                    subject: hw.subject,
                    description: hw.descriptionText,
                    dueDate: hw.dueDate
                )
            }
        )
    }
}

struct HomeworkToolResult: Codable {
    let totalPending: Int
    let items: [HomeworkSummary]
}

struct HomeworkSummary: Codable {
    let subject: String
    let description: String
    let dueDate: Date
}

/// Tool: Get unread messages
struct MessagesTool {
    let child: Child

    func call() -> MessagesToolResult {
        let unread = child.messages
            .filter { !$0.read }
            .sorted { $0.date > $1.date }

        return MessagesToolResult(
            unreadCount: unread.count,
            recent: unread.prefix(3).map { msg in
                MessageSummary(
                    sender: msg.sender,
                    subject: msg.subject,
                    date: msg.date
                )
            }
        )
    }
}

struct MessagesToolResult: Codable {
    let unreadCount: Int
    let recent: [MessageSummary]
}

struct MessageSummary: Codable {
    let sender: String
    let subject: String
    let date: Date
}

/// Tool: Get culture recommendations (from cached CultureReco)
struct CultureRecoTool {
    let child: Child
    let familyRecos: [CultureReco]

    func call() -> CultureRecoToolResult {
        let childRecos = (child.family?.children ?? [])
            .flatMap { _ in [CultureReco]() } // TODO: query from SwiftData
        let relevant = familyRecos.filter { !$0.isFamily || $0.matchedChildrenNames.contains(child.firstName) }

        return CultureRecoToolResult(
            recommendations: relevant.prefix(3).map { reco in
                RecoSummary(
                    type: reco.type.rawValue,
                    title: reco.title,
                    linkedSubject: reco.linkedSubject,
                    linkedTheme: reco.linkedTheme,
                    isDifficultyBased: reco.linkedDifficulty
                )
            }
        )
    }
}

struct CultureRecoToolResult: Codable {
    let recommendations: [RecoSummary]
}

struct RecoSummary: Codable {
    let type: String
    let title: String
    let linkedSubject: String?
    let linkedTheme: String?
    let isDifficultyBased: Bool
}
