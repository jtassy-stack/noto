import Foundation
import SwiftData

/// Writes what the MonLycée login captured into SwiftData: the logbook
/// (`MonLyceeLogbookStore`: homework, grades and class of each child, as the
/// TestFlight builds did) and the school's news (`MonLyceeNewsStore`). When
/// a Pronote session is open, `PronoteSyncService` refreshes the same child
/// with Pronote's own data instead.
@MainActor
final class MonLyceeSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// One announcement of the school, as the MonLycée home page lists it.
    struct NewsItem: Equatable, Sendable {
        let title: String
        let author: String
        let date: Date?
        let link: String?
    }

    /// Syncs `child` from the logbook captured at the last MonLycée login,
    /// plus the stored news. Returns `false` when no logbook is stored or it
    /// does not list this child: callers must not treat that as a sync.
    @discardableResult
    func syncFromStoredLogbook(for child: Child) -> Bool {
        guard let logbook = MonLyceeLogbookStore.load(),
              syncLogbook(logbook, for: child) else { return false }
        syncNews(MonLyceeNewsStore.load(), for: child)
        // No lesson contents here (the logbook is a login-time snapshot);
        // it only feeds the homework capture.
        LessonContentStore.recordSync(of: child, in: modelContext)
        child.markSynced()
        try? modelContext.save()
        return true
    }

    /// Applies the logbook entry of `child` (matched by ENT id, else first
    /// name). Returns `true` when the child was found.
    @discardableResult
    func syncLogbook(_ logbook: [String: Any], for child: Child) -> Bool {
        guard let individual = Self.individual(in: logbook, entChildId: child.entChildId, firstName: child.firstName) else {
            return false
        }

        // Class read from the logbook: fills an empty grade or a new school
        // year's, never erases one (manual pick included).
        if let className = MonLyceeClassReader.className(in: individual),
           let refreshed = GradeInference.refreshedGrade(current: child.grade, className: className) {
            child.grade = refreshed.grade
            child.level = refreshed.level
            child.entClassName = className
        }

        // Replace homework (kept in LessonContent first) and grades.
        LessonContentStore.captureHomework(of: child, in: modelContext)
        for hw in child.homework { modelContext.delete(hw) }
        for grade in child.grades { modelContext.delete(grade) }

        for item in Self.homeworkItems(in: individual) {
            let hw = Homework(subject: item.subject, description: item.description, dueDate: item.dueDate ?? .now)
            hw.child = child
            modelContext.insert(hw)
        }
        for item in Self.gradeItems(in: individual) {
            let grade = Grade(subject: item.subject, value: item.value, outOf: item.outOf, coefficient: 1, date: item.date ?? .now)
            grade.child = child
            modelContext.insert(grade)
        }
        return true
    }

    // MARK: - Pure logbook parsing

    struct HomeworkItem: Equatable, Sendable {
        let subject: String
        let description: String
        let dueDate: Date?
    }

    struct GradeItem: Equatable, Sendable {
        let subject: String
        let value: Double
        let outOf: Double
        let date: Date?
    }

    /// The logbook entry of one child: `structures[].individuals[]`, matched
    /// by id first, then by first name.
    nonisolated static func individual(in logbook: [String: Any], entChildId: String?, firstName: String) -> [String: Any]? {
        let individuals = (logbook["structures"] as? [[String: Any]] ?? [])
            .flatMap { $0["individuals"] as? [[String: Any]] ?? [] }
        if let id = entChildId, !id.isEmpty,
           let byId = individuals.first(where: { ($0["id"] as? String) == id }) {
            return byId
        }
        return individuals.first { ($0["firstName"] as? String) == firstName }
    }

    /// `work.notebook[].workToDo[]`: subject, description (HTML stripped),
    /// due date (`dateForThe`, yyyy-MM-dd).
    nonisolated static func homeworkItems(in individual: [String: Any]) -> [HomeworkItem] {
        let notebook = (individual["work"] as? [String: Any])?["notebook"] as? [[String: Any]] ?? []
        return notebook.flatMap { entry -> [HomeworkItem] in
            let subject = entry["subject"] as? String ?? "?"
            return (entry["workToDo"] as? [[String: Any]] ?? []).map { work in
                HomeworkItem(
                    subject: subject,
                    description: stripHTML(work["description"] as? String ?? ""),
                    dueDate: parseDay(work["dateForThe"] as? String ?? "")
                )
            }
        }
    }

    /// `notation.grades[]`: decimal commas accepted, scale defaults to 20,
    /// unreadable values (Abs, Disp…) dropped.
    nonisolated static func gradeItems(in individual: [String: Any]) -> [GradeItem] {
        let grades = (individual["notation"] as? [String: Any])?["grades"] as? [[String: Any]] ?? []
        return grades.compactMap { entry in
            let gradeStr = (entry["grade"] as? String ?? "").replacingOccurrences(of: ",", with: ".")
            let scaleStr = (entry["scale"] as? String ?? "20").replacingOccurrences(of: ",", with: ".")
            guard let value = Double(gradeStr), let outOf = Double(scaleStr), outOf > 0 else { return nil }
            return GradeItem(
                subject: entry["subject"] as? String ?? "?",
                value: value,
                outOf: outOf,
                date: parseDay(entry["date"] as? String ?? "")
            )
        }
    }

    nonisolated static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func parseDay(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(string.prefix(10)))
    }

    /// Adds the stored news as read `.ent` messages of `child`. Returns
    /// `false` when no news is stored (nothing was captured at login).
    @discardableResult
    func syncStoredNews(for child: Child) -> Bool {
        let news = MonLyceeNewsStore.load()
        guard !news.isEmpty else { return false }
        syncNews(news, for: child)
        try? modelContext.save()
        return true
    }

    /// News → Messages. Idempotent: an announcement already present (same
    /// title, ENT source) is not inserted twice.
    func syncNews(_ news: [[String: Any]], for child: Child) {
        for item in Self.newsItems(from: news) {
            let exists = child.messages.contains { $0.subject == item.title && $0.source == .ent }
            guard !exists else { continue }

            let msg = Message(
                sender: item.author,
                subject: item.title,
                body: "",
                date: item.date ?? .now,
                source: .ent,
                kind: .conversation,
                link: item.link
            )
            msg.read = true  // News are read-only announcements
            msg.child = child
            modelContext.insert(msg)
        }
    }

    /// Pure parsing of the news payload the login web view returns; entries
    /// without a title are dropped.
    nonisolated static func newsItems(from news: [[String: Any]]) -> [NewsItem] {
        news.compactMap { entry in
            let title = (entry["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let link = entry["link"] as? String
            return NewsItem(
                title: title,
                author: entry["author"] as? String ?? "",
                date: parseISO(entry["date"] as? String ?? ""),
                link: (link?.isEmpty ?? true) ? nil : link
            )
        }
    }

    nonisolated static func parseISO(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
