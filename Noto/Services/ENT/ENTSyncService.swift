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
    func sync(child: Child, client: ENTClient, entChildId: String) async throws {
        async let conversationsResult = client.fetchConversations()
        async let schoolbookResult = client.fetchSchoolbook(childId: entChildId)
        async let homeworkResult = client.fetchHomework()
        async let timelineResult = client.fetchTimeline()

        let (conversations, words, homework, _) = try await (
            conversationsResult, schoolbookResult, homeworkResult, timelineResult
        )

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

    // MARK: - Schoolbook → Messages (treated as messages in the UI)

    private func syncSchoolbook(_ words: [ENTSchoolbookWord], for child: Child) {
        for word in words {
            let msg = Message(
                sender: word.ownerName,
                subject: word.title,
                body: word.text,
                date: word.date,
                source: .ent
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
