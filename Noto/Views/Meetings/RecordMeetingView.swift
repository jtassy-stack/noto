import SwiftUI
import SwiftData

/// Records a meeting, transcribes it on-device, extracts candidate items,
/// then hands off to `MeetingReviewView` — nothing here is confirmed yet.
struct RecordMeetingView: View {
    let children: [Child]
    var onFinished: (MeetingNote) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = MeetingRecorder()

    @AppStorage("meeting.consentAcknowledged") private var consentAcknowledged = false
    @State private var showConsent = false
    @State private var title = ""
    @State private var selectedChildIDs: Set<PersistentIdentifier> = []
    @State private var keepAudio = false
    @State private var isProcessing = false
    @State private var processingLabel = ""
    @State private var errorMessage: String?
    @State private var audioURL: URL?
    @State private var meetingID = UUID()

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.lg) {
            if isProcessing {
                ProgressView(processingLabel)
                    .padding(.top, NotoTheme.Spacing.xxl)
            } else {
                Form {
                    Section("Réunion") {
                        TextField("Titre (ex. Plénière 6e — rentrée)", text: $title)
                    }

                    Section("Concerne") {
                        ForEach(children) { child in
                            Button {
                                toggle(child)
                            } label: {
                                HStack {
                                    Text(child.firstName)
                                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                                    Spacer()
                                    if selectedChildIDs.contains(child.persistentModelID) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(NotoTheme.Colors.brand)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Toggle("Garder l'enregistrement audio", isOn: $keepAudio)
                    } footer: {
                        Text("Par défaut, l'audio est supprimé dès que la transcription est terminée. Seul le texte reste.")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(NotoTheme.Colors.danger)
                        }
                    }
                }

                VStack(spacing: NotoTheme.Spacing.md) {
                    if recorder.state == .recording {
                        Text(elapsedLabel)
                            .font(NotoTheme.Typography.dataLarge)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                    }

                    Button {
                        handlePrimaryTap()
                    } label: {
                        Text(recorder.state == .recording ? "Arrêter l'enregistrement" : "Démarrer l'enregistrement")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.state == .recording ? NotoTheme.Colors.danger : NotoTheme.Colors.brand)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.horizontal, NotoTheme.Spacing.md)
                }
                .padding(.bottom, NotoTheme.Spacing.md)
            }
        }
        .navigationTitle("Enregistrer une réunion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler") { dismiss() }
            }
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(onAcknowledge: {
                consentAcknowledged = true
                showConsent = false
                Task { await startRecording() }
            })
        }
    }

    private var elapsedLabel: String {
        let minutes = Int(recorder.elapsed) / 60
        let seconds = Int(recorder.elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func toggle(_ child: Child) {
        if selectedChildIDs.contains(child.persistentModelID) {
            selectedChildIDs.remove(child.persistentModelID)
        } else {
            selectedChildIDs.insert(child.persistentModelID)
        }
    }

    private func handlePrimaryTap() {
        if recorder.state == .recording {
            recorder.stop()
            if case .stopped(let url) = recorder.state {
                audioURL = url
                Task { await processRecording(url: url) }
            }
            return
        }

        if consentAcknowledged {
            Task { await startRecording() }
        } else {
            showConsent = true
        }
    }

    private func startRecording() async {
        errorMessage = nil
        meetingID = UUID()
        let url = MeetingStorage.newAudioURL(id: meetingID)
        await recorder.start(to: url)
        if case .failed(let message) = recorder.state {
            errorMessage = message
        }
    }

    private func processRecording(url: URL) async {
        isProcessing = true
        defer { isProcessing = false }

        processingLabel = "Transcription en cours…"
        let transcript: String
        do {
            transcript = try await MeetingTranscriber.transcribe(fileURL: url) { partial in
                Task { @MainActor in processingLabel = "Transcription… (\(partial.count) caractères)" }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let selectedChildren = children.filter { selectedChildIDs.contains($0.persistentModelID) }

        processingLabel = "Extraction des informations…"
        let items = await MeetingExtractionService.extract(
            transcript: transcript,
            childNames: selectedChildren.map(\.firstName)
        )

        let note = MeetingNote(
            title: title.trimmingCharacters(in: .whitespaces),
            date: .now,
            children: selectedChildren,
            rawTranscript: transcript
        )
        note.items = items
        note.audioRetained = keepAudio
        modelContext.insert(note)
        try? modelContext.save()

        if !keepAudio {
            MeetingStorage.deleteAudio(id: meetingID)
        }

        onFinished(note)
    }
}

private struct ConsentSheet: View {
    var onAcknowledge: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.lg) {
            Image(systemName: "mic.circle")
                .font(.system(size: 40))
                .foregroundStyle(NotoTheme.Colors.brand)

            Text("Avant d'enregistrer")
                .font(NotoTheme.Typography.title)

            Text("Cet enregistrement reste entièrement sur votre appareil — la transcription se fait sur le téléphone, rien n'est envoyé à un serveur. Si possible, informez les personnes présentes que la réunion est enregistrée.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)

            Button("J'ai compris, démarrer") {
                onAcknowledge()
            }
            .buttonStyle(.borderedProminent)
            .tint(NotoTheme.Colors.brand)

            Button("Annuler") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.xl)
        .presentationDetents([.medium])
    }
}
