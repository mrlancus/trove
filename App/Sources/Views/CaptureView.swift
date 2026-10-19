import AVFoundation
import SwiftUI
import TroveCore
#if os(iOS)
import VisionKit
#endif

/// Quick capture: paste a link or type a thought. ⌘⇧N in the app, ⌘⇧Space anywhere on the Mac.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Capture", systemImage: "tray.and.arrow.down").font(.headline)
                Spacer()
                if let url = Pasteboard.url, text.isEmpty {
                    Button { text = url.absoluteString } label: { Label("Paste link", systemImage: "doc.on.clipboard") }
                        .buttonStyle(.bordered)
                }
            }
            TextEditor(text: $text)
                .focused($focused)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 140)
                .card(cornerRadius: 14)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // Same font and inset as the editor's first line, so it sits right at the caret.
                        Text("A link, an idea, a #tagged thought…")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10 + Self.editorInset.width)
                            .padding(.top, 10 + Self.editorInset.height)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(kindHint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = text
                    dismiss()
                    Task { await model.capture(t) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear { focused = true }
    }

    /// Where a TextEditor draws its first character: the text view's line padding (5pt) plus its
    /// top inset (none on the Mac, 8pt on iOS).
    #if os(macOS)
    static let editorInset = CGSize(width: 5, height: 0)
    #else
    static let editorInset = CGSize(width: 5, height: 8)
    #endif

    private var kindHint: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "⌘↩ to save" }
        if URL(string: t)?.scheme?.hasPrefix("http") == true, !t.contains(" ") { return "Saves as a link. Trove will fetch the page." }
        return "Saves as a note"
    }
}

/// Records a voice note, saves the audio, and transcribes it on-device into the note body.
struct VoiceNoteButton: View {
    @Environment(AppModel.self) private var model
    @State private var recorder: AVAudioRecorder?
    @State private var fileURL: URL?

    var body: some View {
        Button {
            if recorder?.isRecording == true { stop() } else { Task { await start() } }
        } label: {
            Label(recorder?.isRecording == true ? "Stop recording" : "Voice note", systemImage: recorder?.isRecording == true ? "stop.circle" : "mic")
        }
    }

    private func start() async {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try? session.setActive(true)
        guard await AVAudioApplication.requestRecordPermission() else { model.toast = "Microphone access is off"; return }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        fileURL = url
        model.toast = "Recording… tap again to stop"
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        guard let url = fileURL, let data = try? Data(contentsOf: url), let library = model.library else { return }
        Task {
            let id = try? await library.addFile(data, name: "Voice note.m4a", mime: "audio/m4a", kind: .audio, source: .voice,
                                                title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))")
            await model.reload()
            model.toast = "Voice note saved, transcribing…"
            if let id, await Transcriber.requestPermission(), let text = try? await Transcriber.transcribe(fileURL: url) {
                await library.setBody(id, text)
                await model.reload()
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

#if os(iOS)
/// Scans paper documents into a searchable PDF.
struct ScanDocumentButton: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false

    var body: some View {
        Button { scanning = true } label: { Label("Scan document", systemImage: "doc.viewfinder") }
            .disabled(!VNDocumentCameraViewController.isSupported)
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { pdf in
                    scanning = false
                    guard let pdf, let library = model.library else { return }
                    Task {
                        _ = try? await library.addFile(pdf, name: "Scan.pdf", mime: "application/pdf", kind: .pdf, source: .scan,
                                                       title: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))")
                        await model.reload()
                        await model.enrichSoon()
                    }
                }
                .ignoresSafeArea()
            }
    }
}

struct DocumentScanner: UIViewControllerRepresentable {
    var completion: (Data?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Data?) -> Void
        init(completion: @escaping (Data?) -> Void) { self.completion = completion }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, .zero, nil)
            for i in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: i)
                let rect = CGRect(origin: .zero, size: image.size)
                UIGraphicsBeginPDFPageWithInfo(rect, nil)
                image.draw(in: rect)
            }
            UIGraphicsEndPDFContext()
            completion(data as Data)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(nil) }
    }
}
#endif

/// Ask Trove: answers from your own items (on-device AI, optional cloud), with sources.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer: String?
    @State private var sources: [Item] = []
    @State private var thinking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Ask anything about what you've saved…", text: $question)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit(ask)
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(question.isEmpty || thinking)
                }
                .padding(14)
                .glass(cornerRadius: 20)
                if thinking { ProgressView("Looking through your Trove…") }
                if let answer {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(answer).font(.body).textSelection(.enabled)
                            if !sources.isEmpty {
                                Text("Sources").font(.headline)
                                ForEach(sources) { item in
                                    Button {
                                        model.selectedItemID = item.id
                                        dismiss()
                                    } label: {
                                        Label(item.displayTitle, systemImage: ItemStyle.symbol(for: item))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Spacer()
                Text(model.aiStatus).font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationTitle("Ask Trove")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func ask() {
        let q = question
        guard !q.isEmpty else { return }
        thinking = true
        Task {
            let result = await model.ask(q)
            answer = result.answer
            sources = result.sources
            thinking = false
        }
    }
}
