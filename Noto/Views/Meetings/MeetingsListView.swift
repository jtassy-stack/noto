import SwiftUI
import SwiftData

struct MeetingsListView: View {
    let children: [Child]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeetingNote.date, order: .reverse) private var meetings: [MeetingNote]
    @State private var newMeeting: MeetingNote?

    var body: some View {
        List {
            if meetings.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                        Text("Aucune réunion enregistrée")
                            .font(NotoTheme.Typography.headline)
                        Text("Enregistrez une réunion parents-professeurs pour en garder l'agenda, les contacts et les règles importantes — tout reste sur votre téléphone.")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    .padding(.vertical, NotoTheme.Spacing.sm)
                }
            } else {
                Section {
                    ForEach(meetings) { meeting in
                        NavigationLink(value: meeting) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(NotoTheme.Typography.headline)
                                Text(meetingSubtitle(meeting))
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationDestination(for: MeetingNote.self) { meeting in
            MeetingReviewView(meetingNote: meeting)
        }
        .navigationTitle("Réunions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    RecordMeetingView(children: children, onFinished: { newMeeting = $0 })
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(children.isEmpty)
            }
        }
        .navigationDestination(item: $newMeeting) { meeting in
            MeetingReviewView(meetingNote: meeting)
        }
    }

    private func meetingSubtitle(_ meeting: MeetingNote) -> String {
        let date = meeting.date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR")))
        let names = meeting.children.map(\.firstName).joined(separator: ", ")
        return names.isEmpty ? date : "\(date) · \(names)"
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let meeting = meetings[index]
            MeetingStorage.deleteAudio(id: meeting.id)
            modelContext.delete(meeting)
        }
        try? modelContext.save()
    }
}
