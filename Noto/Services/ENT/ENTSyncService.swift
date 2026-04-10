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

        do { conversations = try await client.fetchConversations() }
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

        // Only proceed if we got at least some data
        let hasData = !conversations.isEmpty || !words.isEmpty || !homework.isEmpty
        guard hasData || fetchErrors.isEmpty else {
            throw ENTError.invalidResponse("Aucune donnée récupérée (\(fetchErrors.joined(separator: ", ")))")
        }

        // Now safe to delete old data and insert new
        for msg in child.messages { modelContext.delete(msg) }
        for hw in child.homework { modelContext.delete(hw) }
        // Keep existing photos not in new set to avoid re-download; only add new ones
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
