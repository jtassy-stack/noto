import Foundation
import SwiftData

/// Syncs data from MonLycée's /logbook endpoint into SwiftData.
/// The logbook aggregates Pronote data (homework, grades, absences) per child.
@MainActor
final class MonLyceeSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Sync from stored logbook JSON (captured during web login)
    func syncFromStoredLogbook(for child: Child) {
        guard let jsonStr = UserDefaults.standard.string(forKey: "monlycee_logbook"),
              let data = jsonStr.data(using: .utf8),
              let logbook = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        syncLogbook(logbook, for: child)

        // Sync news
        if let newsStr = UserDefaults.standard.string(forKey: "monlycee_news"),
           let newsData = newsStr.data(using: .utf8),
           let news = try? JSONSerialization.jsonObject(with: newsData) as? [[String: Any]] {
            syncNews(news, for: child)
        }

        try? modelContext.save()
    }

    /// Sync logbook data for a specific child
    func syncLogbook(_ logbook: [String: Any], for child: Child) {
        guard let structures = logbook["structures"] as? [[String: Any]] else { return }

        // Find this child's data in the logbook
        for structure in structures {
            guard let individuals = structure["individuals"] as? [[String: Any]] else { continue }
            for individual in individuals {
                let firstName = individual["firstName"] as? String ?? ""
                let id = individual["id"] as? String ?? ""

                // Match by entChildId or firstName
                guard id == child.entChildId || firstName == child.firstName else { continue }

                // Clear existing data
                for hw in child.homework { modelContext.delete(hw) }
                for grade in child.grades { modelContext.delete(grade) }

                // Sync homework from work.notebook
                if let work = individual["work"] as? [String: Any],
                   let notebook = work["notebook"] as? [[String: Any]] {
                    syncHomework(notebook, for: child)
                }

                // Sync grades from notation.grades
                if let notation = individual["notation"] as? [String: Any],
                   let grades = notation["grades"] as? [[String: Any]] {
                    syncGrades(grades, for: child)
                }

                return
            }
        }
    }

    // MARK: - Homework

    private func syncHomework(_ notebook: [[String: Any]], for child: Child) {
        for entry in notebook {
            let subject = entry["subject"] as? String ?? "?"
            guard let workToDo = entry["workToDo"] as? [[String: Any]] else { continue }

            for work in workToDo {
                let description = stripHTML(work["description"] as? String ?? "")
                let dateStr = work["dateForThe"] as? String ?? ""
                let dueDate = parseDate(dateStr) ?? .now

                let hw = Homework(subject: subject, description: description, dueDate: dueDate)
                hw.child = child
                modelContext.insert(hw)
            }
        }
    }

    // MARK: - Grades

    private func syncGrades(_ grades: [[String: Any]], for child: Child) {
        for entry in grades {
            let subject = entry["subject"] as? String ?? "?"
            let gradeStr = (entry["grade"] as? String ?? "0").replacingOccurrences(of: ",", with: ".")
            let scaleStr = (entry["scale"] as? String ?? "20").replacingOccurrences(of: ",", with: ".")
            let dateStr = entry["date"] as? String ?? ""

            guard let value = Double(gradeStr),
                  let outOf = Double(scaleStr) else { continue }

            let grade = Grade(
                subject: subject,
                value: value,
                outOf: outOf,
                coefficient: 1,
                date: parseDate(dateStr) ?? .now
            )
            grade.child = child
            modelContext.insert(grade)
        }
    }

    // MARK: - News → Messages

    private func syncNews(_ news: [[String: Any]], for child: Child) {
        for entry in news {
            let title = entry["title"] as? String ?? ""
            let author = entry["author"] as? String ?? ""
            let dateStr = entry["date"] as? String ?? ""
            let link = entry["link"] as? String
            let date = parseISO(dateStr) ?? .now

            // Check if already exists (avoid duplicates)
            let exists = child.messages.contains { $0.subject == title && $0.source == .ent }
            guard !exists else { continue }

            let msg = Message(
                sender: author,
                subject: title,
                body: "",
                date: date,
                source: .ent,
                kind: .conversation,
                link: link
            )
            msg.read = true  // News are read-only announcements
            msg.child = child
            modelContext.insert(msg)
        }
    }

    // MARK: - Helpers

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
