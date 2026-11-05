import AVFoundation
import Foundation
import Speech

/// Voice notes and lecture recordings → text, on the device (learn-pivot plan §6).
/// - iOS/macOS 26: SpeechAnalyzer with SpeechTranscriber, made for long, distant audio such as lectures, when the
///   locale is supported and its speech asset is on the device (checked at runtime, not only by `#available`;
///   installed on first use).
/// - Otherwise the classic recognizer, which works on iPhones without Apple Intelligence. It can stop early on long
///   files, so a recording over about a minute is transcribed in pieces of a minute each and joined.
/// Unverified on the Intel Mac.
enum Transcriber {
    /// Pieces for the classic recognizer, in seconds.
    static let piece: Double = 60

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    static func transcribe(fileURL: URL, locale: Locale = .current) async throws -> String {
        if #available(iOS 26, macOS 26, *), let text = try? await analyze(fileURL, locale: locale), !text.isEmpty {
            return text
        }
        return try await inPieces(fileURL, locale: locale)
    }

    // MARK: SpeechAnalyzer (iOS/macOS 26)

    @available(iOS 26, macOS 26, *)
    static func analyze(_ url: URL, locale: Locale) async throws -> String? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        // The speech model for the locale has to be on the device.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return nil }
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        async let text: String = transcriber.results.reduce(into: "") { out, result in
            out += String(result.text.characters)
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The classic recognizer, a minute at a time

    static func inPieces(_ url: URL, locale: Locale) async throws -> String {
        let pieces = try split(url)
        defer { for p in pieces where p != url { try? FileManager.default.removeItem(at: p) } }
        var out: [String] = []
        for p in pieces {
            let text = try await once(p, locale: locale)
            if !text.isEmpty { out.append(text) }
        }
        return out.joined(separator: " ")
    }

    /// The file itself when it's short, else pieces of `piece` seconds as uncompressed temporary files.
    static func split(_ url: URL) throws -> [URL] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let perPiece = AVAudioFrameCount(rate * piece)
        guard file.length > AVAudioFramePosition(Double(perPiece) * 1.25) else { return [url] }
        var out: [URL] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: perPiece) else { break }
            try file.read(into: buffer, frameCount: perPiece)
            if buffer.frameLength == 0 { break }
            let pieceURL = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString).caf")
            let writer = try AVAudioFile(forWriting: pieceURL, settings: file.processingFormat.settings,
                                         commonFormat: file.processingFormat.commonFormat, interleaved: file.processingFormat.isInterleaved)
            try writer.write(from: buffer)
            out.append(pieceURL)
        }
        return out
    }

    static func once(_ fileURL: URL, locale: Locale) async throws -> String {
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
