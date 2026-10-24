import Foundation
import SwiftData

/// Writes the MonLycée news captured at login (`MonLyceeNewsStore`) into a
/// child's messages. School data (homework, grades, timetable) of a MonLycée
/// child comes from the Pronote session the ENT login opens — the logbook
/// snapshot that used to feed it is no longer stored.
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
