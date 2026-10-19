import Foundation
import Speech

/// Voice notes → text, on device. Uses the classic recognizer for broad device support (it works on
/// iPhones without Apple Intelligence). TODO (Phase 0 result permitting): prefer SpeechAnalyzer on
/// iOS/macOS 26 where `SpeechTranscriber.isAvailable`, for long-form accuracy.
enum Transcriber {
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    static func transcribe(fileURL: URL, locale: Locale = .current) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw TranscriberError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    enum TranscriberError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available right now." }
    }
}
