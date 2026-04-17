import Foundation
import SwiftData

/// Syncs ENT/PCN data into SwiftData models.
@MainActor
final class ENTSyncService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Full sync for an ENT child: schoolbook, messages, homework, photos.
    /// Fetches all data first, then deletes old data and inserts new — no data loss on partial failure.
    func sync(child: Child, client: ENTClient, entChildId: String) async throws {
        // Fetch all data BEFORE deleting anything — partial failure keeps old data intact
        var conversations: [ENTConversation] = []
        var words: [ENTSchoolbookWord] = []
        var homework: [ENTHomework] = []
        var photos: [ENTPhotoAttachment] = []
        var fetchErrors: [String] = []

        do {
            let list = try await client.fetchConversations()
            // The list endpoint returns summaries — bodies are absent. Fetch each message
            // individually to populate the body. Failures are soft: a missing body is
            // better than losing the whole message thread.
            conversations = await withBodyFetch(list, client: client, fetchErrors: &fetchErrors)
        }
        catch { fetchErrors.append("messages: \(error.localizedDescription)") }

        do { words = try await client.fetchSchoolbook(childId: entChildId) }
        catch { fetchErrors.append("carnet: \(error.localizedDescription)") }

        do { homework = try await client.fetchHomework() }
        catch { fetchErrors.append("devoirs: \(error.localizedDescription)") }

        // Photos: blog posts + schoolbook word attachments
        do {
            photos += try await fetchAllPhotos(client: client, words: words)
            NSLog("[noto] fetchAllPhotos OK — %d attachments for %@", photos.count, child.firstName)
        } catch {
            NSLog("[noto][error] fetchAllPhotos failed for %@: %@", child.firstName, error.localizedDescription)
            fetchErrors.append("photos: \(error.localizedDescription)")
        }

        // Decide whether to wipe-and-insert, preserve, or fail.
        // Extracted as a pure function (`ENTSyncGate.decide`) so every
        // branch has behavioural test coverage — the old inline guard
        // silently wiped local data when PCN returned 200-with-empty
        // lists (stale session cookie that the server didn't 401).
        let hasData = !conversations.isEmpty || !words.isEmpty || !homework.isEmpty
        switch ENTSyncGate.decide(hasData: hasData, fetchErrors: fetchErrors) {
        case .proceed:
            break
        case .preserve:
            NSLog("[noto][warn] ENT sync for %@ returned empty payload — preserving existing local data", child.firstName)
            return
        case .fail(let detail):
            throw ENTError.invalidResponse("Aucune donnée récupérée (\(detail))")
        }

        // Now safe to delete old data and insert new
        for msg in child.messages { modelContext.delete(msg) }
        for hw in child.homework { modelContext.delete(hw) }
        // Keep existing photos not in new set to avoid re-download; only add new ones.
        // Exception: delete entries that are NOT in the fresh sync AND never successfully cached
        // (these are bad entries — e.g. audio/video paths captured by a previous overly-broad regex).
        let freshPaths = Set(photos.map(\.path))
        var toDelete: [SchoolPhoto] = []
        for existing in child.photos {
            guard !freshPaths.contains(existing.entPath) else { continue }
            let neverCached = await !ENTPhotoCache.shared.isCached(existing.entPath)
            if neverCached { toDelete.append(existing) }
        }
        for stale in toDelete { modelContext.delete(stale) }
        let existingPaths = Set(child.photos.map(\.entPath))
        let newPhotos = photos.filter { !existingPaths.contains($0.path) }

        syncMessages(conversations, for: child)
        await syncSchoolbook(words, for: child)
        syncHomework(homework, for: child)
        syncPhotos(newPhotos, for: child)

        try modelContext.save()
    }

    // MARK: - Photos

    private func fetchAllPhotos(client: ENTClient, words: [ENTSchoolbookWord]) async throws -> [ENTPhotoAttachment] {
        var photos: [ENTPhotoAttachment] = []

        // Blog photos via timeline — fetchBlogPosts uses /timeline/lastNotifications to get blog IDs,
        // then fetches posts via /blog/post/list/all/<id> (parent-accessible on PCN).
        do {
            let blogs = try await client.fetchBlogPosts()
            NSLog("[noto] fetchBlogPosts → %d blogs", blogs.count)
            for blog in blogs {
                do {
                    let attachments = try await client.fetchBlogPhotoAttachments(blogId: blog.id)
                    NSLog("[noto] blog %@ → %d photo attachments", blog.id, attachments.count)
                    photos += attachments
                } catch {
                    NSLog("[noto][error] fetchBlogPhotoAttachments %@ failed: %@", blog.id, error.localizedDescription)
                }
            }
        } catch {
            NSLog("[noto][error] fetchBlogPosts failed: %@", error.localizedDescription)
        }

        // Actualités photos — supplemental source (embedded images in news posts)
        do {
            let actPhotos = try await client.fetchActualitesPhotos()
            if !actPhotos.isEmpty {
                NSLog("[noto] fetchActualitesPhotos → %d photos", actPhotos.count)
                photos += actPhotos
            }
        } catch {
            NSLog("[noto][error] fetchActualitesPhotos failed: %@", error.localizedDescription)
        }

        // Schoolbook word photo attachments (images embedded in words or attached)
        for word in words {
            do {
                photos += try await client.fetchSchoolbookPhotoAttachments(
                    wordId: word.id,
                    wordTitle: word.title,
                    wordDate: word.date,
                    authorName: word.ownerName
                )
            } catch {
                NSLog("[noto][error] fetchSchoolbookPhotoAttachments %@ failed: %@", word.id, error.localizedDescription)
            }
        }

        return photos
    }

    private func syncPhotos(_ photos: [ENTPhotoAttachment], for child: Child) {
        for photo in photos {
            let p = SchoolPhoto(
                entPath: photo.path,
                source: photo.source,
                title: photo.title,
                authorName: photo.authorName,
                date: photo.date
            )
            p.child = child
            modelContext.insert(p)
        }
        NSLog("[noto] ENT synced \(photos.count) new photos for \(child.firstName)")
    }

    // MARK: - Body fetch

    /// Enrich conversation summaries with their full body by calling GET /conversation/message/<id>
    /// per conversation. Sequential (not concurrent) to avoid hammering the ENT API.
    /// A failure to fetch a body is logged and silently ignored — the message is still stored
    /// with an empty body rather than dropped entirely.
    private func withBodyFetch(_ conversations: [ENTConversation], client: ENTClient, fetchErrors: inout [String]) async -> [ENTConversation] {
        var enriched: [ENTConversation] = []
        enriched.reserveCapacity(conversations.count)
        var bodyFailures = 0
        let needsBody = conversations.filter { $0.body == nil || $0.body?.isEmpty == true }.count
        for conv in conversations {
            guard conv.body == nil || conv.body?.isEmpty == true else {
                enriched.append(conv)
                continue
            }
            do {
                if let detail = try await client.fetchMessage(id: conv.id), let body = detail.body {
                    enriched.append(ENTConversation(
                        id: conv.id,
                        subject: conv.subject,
                        from: conv.from,
                        date: conv.date,
                        body: body,
                        unread: conv.unread,
                        groupNames: conv.groupNames
                    ))
                } else {
                    enriched.append(conv)
                }
            } catch {
                NSLog("[noto][warn] fetchMessage(%@) body fetch failed: %@ — storing without body", conv.id, error.localizedDescription)
                bodyFailures += 1
                enriched.append(conv)
            }
        }
        if needsBody > 0 && bodyFailures * 2 >= needsBody {
            fetchErrors.append("messages (corps): \(bodyFailures)/\(needsBody) échecs")
        }
        return enriched
    }

    // MARK: - Messages

    private func syncMessages(_ conversations: [ENTConversation], for child: Child) {
        let filtered = filterByChild(conversations, child: child)
        for conv in filtered {
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

    /// Filter conversations relevant to a child based on their ENT class name.
    /// Mirrors React Native's filterMessagesByChild logic.
    private func filterByChild(_ conversations: [ENTConversation], child: Child) -> [ENTConversation] {
        guard let className = child.entClassName, !className.isEmpty else {
            return conversations // No class info → show all
        }
        // Strip teacher name: "CM1 - CM2 A - M. Lucas TOLOTTA" → "CM1 - CM2 A"
        let classParts = className.components(separatedBy: " - ").dropLast().joined(separator: " - ")
        let classKey = classParts.isEmpty ? className : classParts

        return conversations.filter { conv in
            if conv.groupNames.isEmpty { return true } // Direct message → show to all
            return conv.groupNames.contains { group in
                group.contains("POLY") || group.contains("école") || group.contains(classKey)
            }
        }
    }

    // MARK: - Schoolbook

    private func syncSchoolbook(_ words: [ENTSchoolbookWord], for child: Child) async {
        for word in words {
            let msg = Message(
                sender: word.ownerName,
                subject: word.title,
                body: word.text,   // raw HTML — stripped only for display in SchoolbookRow
                date: word.date,
                source: .ent,
                kind: .schoolbook
            )
            msg.read = word.acknowledged
            msg.link = word.id    // word ID for acknowledgment
            msg.child = child
            modelContext.insert(msg)

            // Notify parent for new unsigned carnet entries
            await NotificationService.shared.scheduleCarnetNotification(
                for: child,
                subject: word.title,
                wordId: word.id
            )
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

// MARK: - Sync decision gate

/// Decides what to do after an ENT fetch round. Split from `sync(...)`
/// so every branch has test coverage — the previous inline guard
/// silently wiped local data when PCN returned 200-with-empty lists.
enum ENTSyncGate {
    enum Decision: Equatable {
        /// Fresh data arrived — safe to wipe local rows and insert new ones.
        case proceed
        /// No data and no errors — treat as a no-op to avoid losing local state.
        case preserve
        /// No data and at least one error — fail loudly so the caller can retry.
        case fail(String)
    }

    static func decide(hasData: Bool, fetchErrors: [String]) -> Decision {
        if hasData { return .proceed }
        if !fetchErrors.isEmpty { return .fail(fetchErrors.joined(separator: ", ")) }
        return .preserve
    }
}
