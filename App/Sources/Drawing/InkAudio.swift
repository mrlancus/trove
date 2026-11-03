import AVFoundation
import Foundation
import TroveCore

/// Audio synced to ink in the sketch editor (docs/MASTER_PLAN.md G4). Record while writing; play
/// back with the strokes written at that moment marked on the page; lasso a stroke and play from
/// it. Light on battery: AAC mono at 32 kbps while recording, nothing redrawn while recording, and
/// during playback the marks update 4 times a second (only while playing).
@MainActor
@Observable
final class InkAudioController {
    private weak var editor: InkEditorModel?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStart: Date?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private(set) var playing: InkRecording?
    private(set) var position: Double = 0
    var isRecording: Bool { recorder?.isRecording == true }
    var error: String?

    init(editor: InkEditorModel) { self.editor = editor }

    // MARK: Recording

    func startRecording() async {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        guard await AVAudioApplication.requestRecordPermission() else { error = "Microphone access is off (Settings → Trove)."; return }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32_000]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { error = "Couldn't start recording."; return }
        recorder = r
        recordingURL = url
        recordingStart = Date()
    }

    func stopRecording() async {
        guard let recorder, let url = recordingURL, let start = recordingStart, let editor, let library = editor.app?.library else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        let itemId = editor.target.itemId
        guard let rec = try? await library.addRecording(data, to: itemId, start: start.timeIntervalSince1970 * 1000, duration: duration) else {
            error = "Couldn't save the recording."
            return
        }
        editor.app?.inkChanged()
        await editor.reloadRecordings()
        // What was said, on the device, so it's searchable (in the background).
        Task.detached(priority: .utility) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString).m4a")
            guard (try? data.write(to: tmp)) != nil, await Transcriber.requestPermission(),
                  let text = try? await Transcriber.transcribe(fileURL: tmp), !text.isEmpty else { return }
            try? FileManager.default.removeItem(at: tmp)
            await library.setTranscript(text, for: rec.id, on: itemId)
        }
    }

    // MARK: Playback

    func play(_ rec: InkRecording, from offset: Double = 0) async {
        guard let editor, let library = editor.app?.library else { return }
        stop()
        guard let data = try? await library.attachmentData(rec.attachment), let p = try? AVAudioPlayer(data: data) else {
            error = "This recording isn't on this device yet."
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        p.currentTime = max(0, min(offset, p.duration))
        p.play()
        player = p
        playing = rec
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(50))
                guard let self, let p = self.player else { return }
                if !p.isPlaying { self.stop(); return }
                self.position = p.currentTime
                self.markWritten()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        playing = nil
        editor?.highlight([:], goTo: nil)
    }

    /// Plays from where the first selected stroke was written (lasso → Play from here).
    func playFromSelection() async {
        guard let editor, let sel = editor.selection else { return }
        let lines = (editor.content[sel.pageKey]?.strokes ?? []).filter { sel.strokes.contains($0.id) }
        let times = lines.compactMap(\.createdAt).sorted()
        guard let t = times.first else { return }
        for rec in editor.recordings { if let off = rec.offset(of: t) { await play(rec, from: max(0, off - 1)); return } }
        error = "Nothing was being recorded when that was written."
    }

    /// Marks the strokes written in the last moment of the audio.
    private func markWritten() {
        guard let editor, let rec = playing else { return }
        var rects: [String: [InkGeometry.Rect]] = [:]
        var page: String?
        for spec in editor.pages {
            let strokes = editor.content[spec.key]?.strokes ?? []
            let ids = Set(rec.written(at: position, strokes: strokes.compactMap { s in s.createdAt.map { (id: s.id, createdAt: $0) } }))
            for s in strokes where ids.contains(s.id) {
                if let b = InkGeometry.bounds(s.points, pad: s.width / 2) { rects[spec.key, default: []].append(b) }
            }
            if page == nil, rects[spec.key] != nil { page = spec.key }
        }
        editor.highlight(rects, goTo: page)
    }
}
