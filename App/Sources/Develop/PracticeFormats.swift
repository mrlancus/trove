import AVFoundation
import SwiftUI
import TroveCore

/// Practice that isn't a written exam question (learn-pivot plan §C3): do it away from the app and rate it, or say
/// it aloud. Both are self-marked evidence, like any self-marked attempt.
struct RatedPracticeCard: View {
    let develop: DevelopModel
    let problem: Problem
    let finished: (Double, String) -> Void
    @State private var started: Date?
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(problem.format == .rated ? "Do it, then rate how it went." : "Rate how it went.").font(.headline)
            HStack {
                Button(started == nil ? "Start the timer" : "Stop") {
                    if let s = started { elapsed += Date().timeIntervalSince(s); started = nil } else { started = Date() }
                }
                .buttonStyle(.bordered)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let total = elapsed + (started.map { context.date.timeIntervalSince($0) } ?? 0)
                    Text(Duration.seconds(total).formatted(.time(pattern: .minuteSecond))).font(.title3.monospacedDigit())
                }
            }
            RatingButtons { rating in finished(PracticeFormat.score(rating: rating), "Rated \(PracticeFormat.ratings[rating - 1].lowercased()).") }
        }
        .padding(Theme.Space.l)
        .card(cornerRadius: Theme.Radius.large)
    }
}

/// Say it aloud: recorded on the device, written down there (Transcriber), shown beside the answer, then rated.
struct SpokenPracticeCard: View {
    let develop: DevelopModel
    let problem: Problem
    let finished: (Double, String) -> Void
    @State private var recorder: AVAudioRecorder?
    @State private var url: URL?
    @State private var said: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Say your answer aloud.").font(.headline)
            Button {
                if recorder != nil { Task { await stop() } } else { Task { await start() } }
            } label: {
                Label(recorder != nil ? "Stop" : "Record", systemImage: recorder != nil ? "stop.circle.fill" : "mic.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
            if working { ProgressView("Writing down what you said…").controlSize(.small) }
            if let said {
                Text("You said").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(said).font(.callout)
            }
            if let answer = develop.scheme(of: problem), said != nil {
                Text("The answer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(answer).font(.callout)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if said != nil {
                RatingButtons { rating in finished(PracticeFormat.score(rating: rating), "Said aloud, self-checked: \(PracticeFormat.ratings[rating - 1].lowercased()).") }
            }
        }
        .padding(Theme.Space.l)
        .card(cornerRadius: Theme.Radius.large)
    }

    private func start() async {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try? session.setActive(true)
        guard await AVAudioApplication.requestRecordPermission() else { error = "Microphone access is off (Settings → Trove)."; return }
        #endif
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        guard let r = try? AVAudioRecorder(url: file, settings: settings), r.record() else { error = "Couldn't start recording."; return }
        recorder = r
        url = file
    }

    private func stop() async {
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let url else { return }
        working = true
        defer { working = false; try? FileManager.default.removeItem(at: url) }
        guard await Transcriber.requestPermission() else { error = "Speech recognition is off (Settings → Trove)."; return }
        do { said = try await Transcriber.transcribe(fileURL: url) } catch { self.error = error.localizedDescription }
    }
}

private struct RatingButtons: View {
    let rate: (Int) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(1...4, id: \.self) { r in
                Button(PracticeFormat.ratings[r - 1]) { rate(r) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
    }
}
