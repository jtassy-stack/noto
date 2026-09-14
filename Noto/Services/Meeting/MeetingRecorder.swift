import Foundation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "MeetingRecorder")

/// Records a meeting to a local `.m4a` file. Deliberately writes to disk
/// as it goes rather than buffering in memory — a réunion de rentrée runs
/// 1-2 hours, and nothing here is ever uploaded, so there's no reason to
/// hold the whole thing in RAM.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case stopped(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    /// Requests mic permission and starts writing to a new file in the
    /// caller-provided directory. Caller owns lifecycle of that directory
    /// (see `MeetingStorage`).
    func start(to fileURL: URL) async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            state = .failed("Impossible d'activer le micro : \(error.localizedDescription)")
            return
        }

        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            state = .failed("Micro refusé — activez-le dans Réglages pour enregistrer une réunion.")
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("Le micro n'a pas pu démarrer l'enregistrement.")
                return
            }
            self.recorder = recorder
            self.startedAt = .now
            self.state = .recording
            startTimer()
        } catch {
            logger.error("Failed to start recorder: \(error.localizedDescription, privacy: .public)")
            state = .failed("Impossible de démarrer l'enregistrement : \(error.localizedDescription)")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard let recorder else {
            state = .failed("Aucun enregistrement en cours.")
            return
        }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        state = .stopped(url)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            Task { @MainActor in
                self.elapsed = Date.now.timeIntervalSince(startedAt)
            }
        }
    }
}

/// Where meeting audio/transcripts live on disk, and the one place that
/// deletes them. Files live under Application Support, excluded from
/// iCloud backup — this is recorded speech from a room of other parents,
/// not something to sync to a backup service by default.
enum MeetingStorage {
    static func newAudioURL(id: UUID) -> URL {
        let dir = directory()
        return dir.appendingPathComponent("\(id.uuidString).m4a")
    }

    static func deleteAudio(id: UUID) {
        let url = newAudioURL(id: id)
        try? FileManager.default.removeItem(at: url)
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MeetingAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutableDir = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDir.setResourceValues(values)
        }
        return dir
    }
}
