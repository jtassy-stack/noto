import Foundation
import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "MeetingTranscriber")

/// Transcribes a recorded meeting entirely on-device. `requiresOnDeviceRecognition`
/// is not an optimization here — it's the privacy requirement: a réunion de
/// parents names other families' children, so the audio/text must never
/// reach Apple's servers or anyone else's.
///
/// Long meetings (1-2h) are transcribed in ~75s segments rather than one
/// `SFSpeechRecognizer` task for the whole file — the on-device recognizer
/// is tuned for shorter utterances, and segmenting also lets the caller
/// show progress instead of waiting on one opaque multi-hour call. Each
/// segment is exported to its own temp file first: `SFSpeechURLRecognitionRequest`
/// always reads a whole file, there's no start/duration trimming on the
/// request itself.
enum MeetingTranscriber {
    struct TranscriptionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func transcribe(
        fileURL: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr_FR")),
              recognizer.isAvailable else {
            throw TranscriptionError(message: "La reconnaissance vocale française n'est pas disponible sur cet appareil.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError(message: "La transcription sur l'appareil n'est pas prise en charge ici — aucune transcription serveur ne sera tentée.")
        }

        let authorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
            throw TranscriptionError(message: "Reconnaissance vocale refusée — activez-la dans Réglages.")
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw TranscriptionError(message: "Fichier audio vide ou illisible.")
        }

        let segmentLength: Double = 75
        var offset: Double = 0
        var fullText = ""

        while offset < duration {
            let length = min(segmentLength, duration - offset)
            let segmentURL = try await exportSegment(asset: asset, start: offset, duration: length)
            defer { try? FileManager.default.removeItem(at: segmentURL) }

            let segmentText = try await transcribeSegment(recognizer: recognizer, fileURL: segmentURL)
            if !segmentText.isEmpty {
                fullText += (fullText.isEmpty ? "" : " ") + segmentText
                onProgress?(fullText)
            }
            offset += segmentLength
        }

        return fullText
    }

    /// Exports `[start, start+duration)` of `asset` to a standalone temp
    /// `.m4a` file. Uses the completion-handler `AVAssetExportSession` API
    /// (not the iOS 18+ `async throws export()`) since deployment target
    /// is iOS 17.
    private static func exportSegment(asset: AVURLAsset, start: Double, duration: Double) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-segment-\(UUID().uuidString).m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError(message: "Export du segment audio impossible.")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSession.error ?? TranscriptionError(message: "Export du segment audio échoué."))
                default:
                    continuation.resume(throwing: TranscriptionError(message: "Export du segment audio dans un état inattendu."))
                }
            }
        }

        return outputURL
    }

    private static func transcribeSegment(recognizer: SFSpeechRecognizer, fileURL: URL) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    // A segment failing shouldn't sink the whole transcript —
                    // log and move on with an empty segment rather than
                    // throwing, so one noisy stretch of the recording
                    // doesn't wipe out an hour of good transcription.
                    logger.warning("Segment transcription failed: \(error.localizedDescription, privacy: .public)")
                    didResume = true
                    continuation.resume(returning: "")
                    return
                }
                if let result, result.isFinal {
                    didResume = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
            _ = task
        }
    }
}
