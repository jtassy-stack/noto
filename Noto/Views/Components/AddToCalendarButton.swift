import SwiftUI
import EventKit
import EventKitUI

/// Reusable "Ajouter à l'agenda" button — permission request, event
/// creation, and the native review sheet, all in one place. Originally
/// lived only in `RecoDetailView.swift`; pulled out so homework, meeting
/// agenda items, and culture recos share one implementation.
struct AddToCalendarButton: View {
    let draft: CalendarEventDraft
    /// Full-width tinted button (RecoDetailView style) vs. a compact icon
    /// (meeting-agenda row, next to an already-visible date).
    var style: Style = .full

    enum Style { case full, iconOnly }

    @State private var showCalendarAlert = false
    @State private var pendingItem: PendingItem?

    private struct PendingItem: Identifiable {
        let id = UUID()
        let event: EKEvent
        let store: EKEventStore
    }

    var body: some View {
        Button {
            Task { await add() }
        } label: {
            switch style {
            case .full:
                Label("Ajouter à l'agenda", systemImage: "calendar.badge.plus")
                    .font(NotoTheme.Typography.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(NotoTheme.Colors.brand.opacity(0.12))
                    .foregroundStyle(NotoTheme.Colors.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .iconOnly:
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(NotoTheme.Colors.cobalt)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajouter à l'agenda")
        .alert("Accès calendrier refusé", isPresented: $showCalendarAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Autorisez l'accès au calendrier dans Réglages iOS pour ajouter cet événement.")
        }
        .sheet(item: $pendingItem) { item in
            EventKitAdder(event: item.event, store: item.store)
        }
    }

    private func add() async {
        switch await CalendarAdder.prepareForInteractiveAdd(draft) {
        case .pendingEdit(let event, let store):
            pendingItem = PendingItem(event: event, store: store)
        case .accessDenied, .error:
            showCalendarAlert = true
        }
    }
}

/// Native event-edit sheet, moved here from `RecoDetailView.swift` so
/// every `AddToCalendarButton` call site shares it.
struct EventKitAdder: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.event = event
        vc.eventStore = store
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
