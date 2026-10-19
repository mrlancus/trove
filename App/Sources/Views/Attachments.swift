import AVFoundation
import PDFKit
import SwiftUI
import TroveCore

enum PDFThumbnail {
    static func make(_ data: Data) -> PlatformImage? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
    }
}

/// Shows an attachment inline: images, PDFs (incl. GoodNotes notebooks), audio, or a file row.
struct AttachmentView: View {
    let attachment: Attachment
    @Environment(AppModel.self) private var model
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let data {
                if attachment.mime.hasPrefix("image/"), let image = PlatformImage(data: data) {
                    Image(platformImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                } else if attachment.mime == "application/pdf" {
                    PDFKitView(data: data).frame(minHeight: 420).clipShape(RoundedRectangle(cornerRadius: 14))
                } else if attachment.mime.hasPrefix("audio/") {
                    AudioPlayerView(data: data)
                } else {
                    FileRow(attachment: attachment, data: data)
                }
            } else if failed {
                Label("Couldn't load \(attachment.name). It may still be syncing.", systemImage: "icloud.slash").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: attachment.id) {
            do { data = try await model.library?.attachmentData(attachment) } catch { failed = true }
        }
    }
}

struct FileRow: View {
    let attachment: Attachment
    let data: Data
    var body: some View {
        HStack {
            Image(systemName: "doc").font(.title2)
            VStack(alignment: .leading) {
                Text(attachment.name).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: TemporaryFile(name: attachment.name, data: data).url) { Image(systemName: "square.and.arrow.up") }
        }
        .padding()
        .card(cornerRadius: 14)
    }
}

struct TemporaryFile {
    let url: URL
    init(name: String, data: Data) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
    }
}

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#else
struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#endif

struct AudioPlayerView: View {
    let data: Data
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if player == nil { player = try? AVAudioPlayer(data: data) }
                guard let player else { return }
                if player.isPlaying { player.pause() } else { player.play() }
                playing = player.isPlaying
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Voice note").font(.headline)
                if let d = player?.duration ?? (try? AVAudioPlayer(data: data))?.duration {
                    Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .card(cornerRadius: 14)
    }
}
