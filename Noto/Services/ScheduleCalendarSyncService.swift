import Foundation
import EventKit
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "ScheduleCalendarSyncService")

/// Keeps a dedicated EKCalendar ("nōto — <prénom>") in sync with a child's
/// `ScheduleEntry` rows, so a parent gets a live emploi du temps in the
/// Calendar app rather than a one-off export.
///
/// `ScheduleEntry` has no stable external identifier (Pronote/Skolengo/École
/// Directe sync wipes and recreates every `ScheduleEntry` on each pass —
/// see PronoteSyncService.clearExistingData), so events can't be matched
/// to entries by ID across syncs. Matching instead uses (subject, start,
/// end) as a natural key within the dedicated calendar, which only ever
/// contains events nōto itself created.
@MainActor
enum ScheduleCalendarSyncService {
    private static let windowPast: TimeInterval = -7 * 86_400
    private static let windowFuture: TimeInterval = 60 * 86_400

    enum SyncError: LocalizedError {
        case accessDenied
        case calendarUnavailable

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Accès calendrier refusé — autorisez-le dans Réglages iOS."
            case .calendarUnavailable: return "Impossible de créer un calendrier dédié."
            }
        }
    }

    /// Creates the dedicated calendar (if needed), enables sync on the
    /// child, and runs an initial reconciliation.
    static func enable(for child: Child, modelContext: ModelContext) async throws {
        let store = EKEventStore()
        guard try await CalendarAdder.requestAccess(store: store) else {
            throw SyncError.accessDenied
        }

        let calendar: EKCalendar
        if let existingID = child.eventKitCalendarIdentifier,
           let existing = store.calendar(withIdentifier: existingID) {
            calendar = existing
        } else {
            guard let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first else {
                throw SyncError.calendarUnavailable
            }
            let newCalendar = EKCalendar(for: .event, eventStore: store)
            newCalendar.title = "nōto — \(child.firstName)"
            newCalendar.source = source
            try store.saveCalendar(newCalendar, commit: true)
            calendar = newCalendar
        }

        child.eventKitCalendarIdentifier = calendar.calendarIdentifier
        child.scheduleCalendarSyncEnabled = true
        try? modelContext.save()

        await sync(child: child)
    }

    /// Removes the dedicated calendar (and every event in it) and turns
    /// sync off for the child.
    static func disable(for child: Child, modelContext: ModelContext) {
        defer {
            child.eventKitCalendarIdentifier = nil
            child.scheduleCalendarSyncEnabled = false
            try? modelContext.save()
        }
        guard let id = child.eventKitCalendarIdentifier else { return }
        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: id) else { return }
        try? store.removeCalendar(calendar, commit: true)
    }

    /// No-op when sync isn't enabled for this child. Safe to call after
    /// every data sync regardless of opt-in state.
    static func sync(child: Child) async {
        guard child.scheduleCalendarSyncEnabled,
              let calendarID = child.eventKitCalendarIdentifier else { return }

        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            logger.warning("Schedule sync: dedicated calendar missing for \(child.firstName, privacy: .private) — disabling")
            child.scheduleCalendarSyncEnabled = false
            child.eventKitCalendarIdentifier = nil
            return
        }

        let now = Date.now
        let windowStart = now.addingTimeInterval(windowPast)
        let windowEnd = now.addingTimeInterval(windowFuture)

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
        let existingEvents = store.events(matching: predicate)

        let localEntries = child.schedule.filter { $0.start >= windowStart && $0.start <= windowEnd }

        func key(subject: String, start: Date, end: Date) -> String {
            "\(subject)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
        }

        var eventsByKey: [String: EKEvent] = [:]
        for event in existingEvents {
            guard let title = event.title, let start = event.startDate, let end = event.endDate else { continue }
            eventsByKey[key(subject: title, start: start, end: end)] = event
        }

        var matchedKeys: Set<String> = []
        var didWrite = false

        for entry in localEntries {
            let entryTitle = entry.cancelled ? "❌ \(entry.subject) (annulé)" : entry.subject
            let k = key(subject: entry.subject, start: entry.start, end: entry.end)
            matchedKeys.insert(k)

            if let existing = eventsByKey[k] {
                if existing.title != entryTitle || existing.location != entry.room {
                    existing.title = entryTitle
                    existing.location = entry.room
                    existing.notes = entry.teacher
                    try? store.save(existing, span: .thisEvent, commit: false)
                    didWrite = true
                }
            } else {
                let event = EKEvent(eventStore: store)
                event.title = entryTitle
                event.startDate = entry.start
                event.endDate = entry.end
                event.location = entry.room
                event.notes = entry.teacher
                event.calendar = calendar
                try? store.save(event, span: .thisEvent, commit: false)
                didWrite = true
            }
        }

        // Remove events whose ScheduleEntry no longer exists (schedule
        // changed, or the entry fell outside the window on a later sync).
        for (k, event) in eventsByKey where !matchedKeys.contains(k) {
            try? store.remove(event, span: .thisEvent, commit: false)
            didWrite = true
        }

        if didWrite {
            try? store.commit()
        }
    }
}
