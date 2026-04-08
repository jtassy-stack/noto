import Foundation
import SwiftData

/// Syncs ENT/PCN data into SwiftData models.
@MainActor
final class ENTSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync for an ENT child: schoolbook, messages, homework, timeline.
    /// Fetches all data first, then deletes old data and inserts new — no data loss on partial failure.
    func sync(child: Child, client: ENTClient, entChildId: String) async throws {
        // Fetch all data BEFORE deleting anything — partial failure keeps old data intact
        var conversations: [ENTConversation] = []
        var words: [ENTSchoolbookWord] = []
        var homework: [ENTHomework] = []
        var fetchErrors: [String] = []

        do { conversations = try await client.fetchConversations() }
        catch { fetchErrors.append("messages: \(error.localizedDescription)") }

        do { words = try await client.fetchSchoolbook(childId: entChildId) }
        catch { fetchErrors.append("carnet: \(error.localizedDescription)") }

        do { homework = try await client.fetchHomework() }
        catch { fetchErrors.append("devoirs: \(error.localizedDescription)") }

        // Only proceed if we got at least some data
        let hasData = !conversations.isEmpty || !words.isEmpty || !homework.isEmpty
        guard hasData || fetchErrors.isEmpty else {
            // All fetches failed — don't delete old data, throw
            throw ENTError.invalidResponse("Aucune donnée récupérée (\(fetchErrors.joined(separator: ", ")))")
        }

        // Now safe to delete old data and insert new
        for msg in child.messages { modelContext.delete(msg) }
        for hw in child.homework { modelContext.delete(hw) }

        syncMessages(conversations, for: child)
        syncSchoolbook(words, for: child)
        syncHomework(homework, for: child)

        try modelContext.save()
    }

    // MARK: - Messages

    private func syncMessages(_ conversations: [ENTConversation], for child: Child) {
        for conv in conversations {
            let msg = Message(
                sender: conv.from,
                subject: conv.subject,
                body: conv.body ?? "",
                date: conv.date,
                source: .ent
            )
            msg.read = !conv.unread
            msg.child = child
            modelContext.insert(msg)
        }
    }

    // MARK: - Schoolbook

    private func syncSchoolbook(_ words: [ENTSchoolbookWord], for child: Child) {
        for word in words {
            let msg = Message(
                sender: word.ownerName,
                subject: word.title,
                body: word.text,
                date: word.date,
                source: .ent,
                kind: .schoolbook
            )
            msg.read = word.acknowledged
            msg.child = child
            modelContext.insert(msg)
        }
    }

    // MARK: - Homework

    private func syncHomework(_ entHomework: [ENTHomework], for child: Child) {
        for hw in entHomework {
            let homework = Homework(
                subject: hw.subject,
                description: hw.description,
                dueDate: hw.dueDate
            )
            homework.child = child
            modelContext.insert(homework)
        }
    }
}
