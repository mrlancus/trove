import PhotosUI
import SwiftUI
import TroveCore
import UniformTypeIdentifiers

/// A file picker request: what can be picked, and what happens with the picked files.
struct FilePick {
    var types: [UTType]
    var multiple: Bool
    var done: @MainActor ([URL]) -> Void
}

extension EnvironmentValues {
    /// Opens the file picker. One picker serves the whole window: on iPhone and iPad SwiftUI
    /// presents only one `.fileImporter` per view tree (an ancestor's wins), so a second one further
    /// down, like the Import screen's own, silently never opened.
    @Entry var pickFiles: (FilePick) -> Void = { _ in }
    /// Opens the Photos picker (iPhone and iPad): photos and videos, several at once.
    @Entry var pickPhotos: () -> Void = {}
    /// Opens the document scanner (iPhone and iPad).
    @Entry var scanDocument: () -> Void = {}
}

/// The window's pickers: files (any kind, several, folders too), Photos and the document scanner.
/// Applied once at the root of a window or sheet; views ask for them through the environment.
struct ImportPickers: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var filesOpen = false
    @State private var pick = FilePick(types: [.item], multiple: true, done: { _ in })
    @State private var photosOpen = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var scanning = false

    func body(content: Content) -> some View {
        content
            .environment(\.pickFiles, { request in
                pick = request
                filesOpen = true
            })
            .environment(\.showImporter, {
                pick = FilePick(types: [.item, .folder], multiple: true) { urls in
                    model.selection = .importer // the progress ring shows there
                    Task { await model.importFiles(urls) }
                }
                filesOpen = true
            })
            .environment(\.pickPhotos, { photosOpen = true })
            .environment(\.scanDocument, { scanning = true })
            .fileImporter(isPresented: $filesOpen, allowedContentTypes: pick.types, allowsMultipleSelection: pick.multiple) { result in
                let request = pick
                if case .success(let urls) = result, !urls.isEmpty { request.done(urls) }
            }
            .background { photoPicker }
            #if os(iOS)
            .background { scanner }
            #endif
    }

    /// On its own view, so its presentation doesn't share a view with the file picker's.
    private var photoPicker: some View {
        Color.clear
            .photosPicker(isPresented: $photosOpen, selection: $photos, maxSelectionCount: nil, selectionBehavior: .ordered,
                          matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                photos = []
                Task { await model.importPhotos(picked) }
            }
    }

    #if os(iOS)
    private var scanner: some View {
        Color.clear
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { pdf in
                    scanning = false
                    guard let pdf else { return }
                    Task { await model.addScan(pdf) }
                }
                .ignoresSafeArea()
            }
    }
    #endif
}

extension View {
    func importPickers() -> some View { modifier(ImportPickers()) }
}

/// A photo or video from the Photos picker, as a file (its original, when Photos has it).
struct PickedMedia: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia(copying: received.file) }
        FileRepresentation(importedContentType: .image) { received in try PickedMedia(copying: received.file) }
    }

    /// The picker's file is only there during the call: copied to a folder of its own.
    init(copying file: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: target)
        url = target
    }

    init(url: URL) { self.url = url }
}

extension AppModel {
    /// Photos and videos from the Photos picker, imported like files (with the Import screen's progress).
    func importPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for (i, item) in items.enumerated() {
            if let media = try? await item.loadTransferable(type: PickedMedia.self) {
                urls.append(media.url)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                // No file from Photos: the picture's data, under a made-up name.
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("Photo \(i + 1).\(ext)")
                if (try? data.write(to: file)) != nil { urls.append(file) }
            }
        }
        guard !urls.isEmpty else { toast = "Couldn't read those from Photos"; return }
        selection = .importer
        await importFiles(urls)
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// A scanned document (a PDF made by the scanner) as a new item.
    func addScan(_ pdf: Data) async {
        guard let library else { return }
        _ = try? await library.addFile(pdf, name: "Scan.pdf", mime: "application/pdf", kind: .pdf, source: .scan,
                                       title: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))")
        await reload()
        await enrichSoon()
        toast = "Scan saved"
    }
}
