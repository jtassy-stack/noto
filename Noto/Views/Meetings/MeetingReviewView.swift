import SwiftUI
import SwiftData

/// Relecture obligatoire avant qu'un `ExtractedItem` ne devienne visible
/// ailleurs dans l'app (`BriefingEngine` ne lit que les items où
/// `confirmedByUser == true`). Les items à faible confiance sont affichés
/// en premier dans chaque section.
struct MeetingReviewView: View {
    @Bindable var meetingNote: MeetingNote
    @Environment(\.modelContext) private var modelContext

    private var itemsByKind: [(ExtractedItemKind, [ExtractedItem])] {
        let kinds: [ExtractedItemKind] = [.agenda, .contact, .policy]
        return kinds.map { kind in
            let items = meetingNote.items
                .filter { $0.kind == kind }
                .sorted { $0.confidence < $1.confidence }
            return (kind, items)
        }
    }

    var body: some View {
        List {
            if meetingNote.items.isEmpty {
                Section {
                    Text("Aucune information n'a pu être extraite automatiquement. Le transcript complet reste consultable ci-dessous.")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }

            ForEach(itemsByKind, id: \.0) { kind, items in
                if !items.isEmpty {
                    Section(title(for: kind)) {
                        ForEach(items) { item in
                            ExtractedItemRow(item: item)
                        }
                    }
                }
            }

            Section("Transcript complet") {
                Text(meetingNote.rawTranscript)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
        .navigationTitle(meetingNote.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? modelContext.save()
        }
    }

    private func title(for kind: ExtractedItemKind) -> String {
        switch kind {
        case .agenda: return "Agenda"
        case .contact: return "Contacts"
        case .policy: return "À retenir"
        }
    }
}

private struct ExtractedItemRow: View {
    @Bindable var item: ExtractedItem

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Titre", text: $item.title)
                        .font(NotoTheme.Typography.headline)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .lineLimit(3)
                    }
                    if item.kind == .agenda, let dueDate = item.dueDate {
                        HStack(spacing: NotoTheme.Spacing.xs) {
                            Text(dueDate.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.cobalt)
                            AddToCalendarButton(
                                draft: CalendarEventDraft(
                                    title: item.title,
                                    notes: item.detail,
                                    startDate: dueDate,
                                    endDate: dueDate,
                                    isAllDay: true
                                ),
                                style: .iconOnly
                            )
                        }
                    }
                }
                Spacer()
                Toggle("", isOn: $item.confirmedByUser)
                    .labelsHidden()
            }

            if item.confidence < 0.5 {
                Label("À vérifier — extraction automatique peu sûre", systemImage: "exclamationmark.triangle")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.amber)
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }
}
