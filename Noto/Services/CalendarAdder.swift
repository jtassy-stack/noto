import Foundation
import EventKit

/// A single event ready to go into the user's calendar. `isAllDay` covers
/// homework/meeting deadlines (a date, not a time slot); schedule entries
/// use a real start/end instead.
struct CalendarEventDraft {
    let title: String
    let notes: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

/// Shared EventKit plumbing, extracted from the original single-purpose
/// implementation in `RecoDetailView.swift` so homework, meeting-agenda
/// items, and culture recos all go through the same permission/creation
/// path instead of three copies of it.
@MainActor
enum CalendarAdder {
    enum Outcome {
        /// Event created and ready to hand to `EKEventEditViewController`
        /// for the user to review/edit before it's actually saved.
        case pendingEdit(EKEvent, EKEventStore)
        case accessDenied
        case error(String)
    }

    static func prepareForInteractiveAdd(_ draft: CalendarEventDraft) async -> Outcome {
        let store = EKEventStore()
        do {
            guard try await requestAccess(store: store) else { return .accessDenied }
        } catch {
            return .error(error.localizedDescription)
        }

        let event = EKEvent(eventStore: store)
        apply(draft, to: event)
        event.calendar = store.defaultCalendarForNewEvents
        return .pendingEdit(event, store)
    }

    /// Saves every draft directly — no per-event review sheet. Used for
    /// bulk operations where popping N edit sheets would be unusable.
    @discardableResult
    static func saveDirectly(_ drafts: [CalendarEventDraft], to calendar: EKCalendar? = nil) async throws -> Int {
        let store = EKEventStore()
        guard try await requestAccess(store: store) else { return 0 }

        var saved = 0
        for draft in drafts {
            let event = EKEvent(eventStore: store)
            apply(draft, to: event)
            event.calendar = calendar ?? store.defaultCalendarForNewEvents
            do {
                try store.save(event, span: .thisEvent, commit: false)
                saved += 1
            } catch {
                continue
            }
        }
        if saved > 0 {
            try store.commit()
        }
        return saved
    }

    static func requestAccess(store: EKEventStore) async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestWriteOnlyAccessToEvents()
        } else {
            return try await store.requestAccess(to: .event)
        }
    }

    private static func apply(_ draft: CalendarEventDraft, to event: EKEvent) {
        event.title = draft.title
        event.notes = draft.notes
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = draft.isAllDay
    }
}
