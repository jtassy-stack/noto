import Foundation
import SwiftData

/// Local store of the "what was covered" signals (`LessonContent`): cahier de
/// textes lessons and homework kept across syncs. Written by the sync
/// services on the main actor, read by `ProgrammePositionTracker` (through
/// `LessonContentSnapshot`) on the same device.
///
/// Privacy: rows never leave the device. Nothing here talks to the network.
@MainActor
enum LessonContentStore {
    /// Window kept and fetched: 42 days back, plus today and the future (homework).
    static let lookbackDays = 42

    /// Lesson contents are re-fetched at most once per this interval.
    static let refreshInterval: TimeInterval = 24 * 3600

    struct Incoming: Sendable {
        let subject: String
        let date: Date
        let title: String
        let text: String
        let themes: [String]
        let source: LessonContentSource
        let externalID: String?

        init(subject: String, date: Date, title: String, text: String, themes: [String] = [],
             source: LessonContentSource, externalID: String? = nil) {
            self.subject = subject
            self.date = date
            self.title = title
            self.text = text
            self.themes = themes
            self.source = source
            self.externalID = externalID
        }
    }

    /// True when the cahier de textes fetch can be skipped (fetched < 24 h ago).
    static func isFresh(_ child: Child, now: Date = .now) -> Bool {
        guard let last = child.lessonContentsFetchedAt else { return false }
        return now.timeIntervalSince(last) < refreshInterval && last <= now
    }

    /// Upsert by (child, dedupKey). On a hit it refreshes text / themes /
    /// fetchedAt (existing non-empty themes are kept when the incoming row
    /// carries none: a homework capture must not wipe Pronote teacher tags).
    /// Rows whose title and text are both empty after trimming are skipped.
    static func upsert(_ items: [Incoming], for child: Child, in context: ModelContext,
                       calendar: Calendar = .current, now: Date = .now) {
        guard !items.isEmpty else { return }
        var byKey: [String: LessonContent] = [:]
        for row in rows(of: child, in: context) where byKey[row.dedupKey] == nil {
            byKey[row.dedupKey] = row
        }
        for item in items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !text.isEmpty else { continue }
            let key = LessonDedupKey.make(subject: item.subject, date: item.date,
                                          text: LessonDedupKey.body(title: title, text: text), calendar: calendar)
            let themes = item.themes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let existing = byKey[key] {
                existing.text = text
                if !themes.isEmpty { existing.themes = themes }
                if existing.externalID == nil { existing.externalID = item.externalID }
                // A lesson source outranks a homework capture of the same text.
                if item.source.isLesson && !existing.source.isLesson { existing.sourceRaw = item.source.rawValue }
                existing.fetchedAt = now
                continue
            }
            let row = LessonContent(child: child, subject: item.subject, date: item.date, title: title, text: text,
                                    themes: themes, source: item.source, externalID: item.externalID,
                                    calendar: calendar, fetchedAt: now)
            context.insert(row)
            row.child = child
            byKey[key] = row
        }
    }

    /// Turns the live `Homework` rows into `.homework` rows.
    /// Call this BEFORE the connector wipes `child.homework` (keeps homework
    /// that leaves the fetch window, e.g. past due), and again after the
    /// re-insert (adds the new rows) — `recordSync` does the latter.
    static func captureHomework(of child: Child, in context: ModelContext, calendar: Calendar = .current,
                                now: Date = .now) {
        let incoming = child.homework
            .filter { !$0.isDeleted }
            .map { Incoming(subject: $0.subject, date: $0.dueDate, title: "", text: $0.descriptionText,
                            source: .homework) }
        upsert(incoming, for: child, in: context, calendar: calendar, now: now)
    }

    /// Purge:
    ///  (a) date < start of the current school year (1 Sept, Europe/Paris);
    ///  (b) all rows when the child's canonical level changed since the last
    ///      purge, tracked in `Child.programmeLevel`.
    static func purge(for child: Child, in context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        let level = CurriculumService.canonicalLevel(child.grade)
        let levelChanged = child.programmeLevel.map { $0 != level } ?? false
        let yearStart = schoolYearStart(for: now)
        for row in rows(of: child, in: context) where levelChanged || row.date < yearStart {
            context.delete(row)
        }
        if levelChanged { child.lessonContentsFetchedAt = nil }
        child.programmeLevel = level
    }

    /// Capture after the re-insert, then purge. One call per sync service,
    /// right before `child.markSynced()`.
    static func recordSync(of child: Child, in context: ModelContext, now: Date = .now,
                           calendar: Calendar = .current) {
        captureHomework(of: child, in: context, calendar: calendar, now: now)
        purge(for: child, in: context, now: now, calendar: calendar)
    }

    /// The child's live rows: the relationship plus a context fetch, so rows
    /// inserted earlier in the same sync (not saved yet, inverse possibly not
    /// reflected) are found too. A few hundred rows at most: cheap.
    private static func rows(of child: Child, in context: ModelContext) -> [LessonContent] {
        var seen = Set<PersistentIdentifier>()
        let fetched = ((try? context.fetch(FetchDescriptor<LessonContent>())) ?? [])
            .filter { $0.child?.persistentModelID == child.persistentModelID }
        return (child.lessonContents + fetched).filter { !$0.isDeleted && seen.insert($0.persistentModelID).inserted }
    }

    /// 1 September 00:00 Europe/Paris of the school year containing `now`.
    static func schoolYearStart(for now: Date) -> Date {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let parts = paris.dateComponents([.year, .month], from: now)
        let year = (parts.month ?? 9) >= 9 ? (parts.year ?? 2000) : (parts.year ?? 2000) - 1
        return paris.date(from: DateComponents(year: year, month: 9, day: 1)) ?? .distantPast
    }
}
