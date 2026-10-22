import PDFKit
import QuickLook
import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A file opened with Open: which item and attachment, the page to start on, and whether to start in Edit.
struct FileTarget: Identifiable, Hashable, Codable {
    var itemId: String
    var attachmentId: String
    var title: String
    var startPage = 0
    var edit = false
    var id: String { itemId + "/" + attachmentId }
}

/// Trove's own viewer for a file: full screen on iPhone/iPad, a window of its own on the Mac.
/// View-only until Edit: then Trove's pen (the ink editor on the file), highlights and the form
/// (PDFs), and Apple's Markup (iPhone/iPad; saved as a new version). Done goes back to view-only,
/// everything saved. Print prints the file (PDFs with or without Trove's ink and highlights).
struct FileViewer: View {
    let target: FileTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Bool
    /// The attachment shown: Markup's new version replaces it.
    @State private var attachmentId: String
    @State private var data: Data?
    @State private var failed = false
    @State private var pdfTool = PDFEditTool.pen
    @State private var quickLook: URL?
    #if os(iOS)
    @State private var markupURL: URL?
    #endif

    enum PDFEditTool: Hashable { case pen, marks }

    init(target: FileTarget) {
        self.target = target
        _editing = State(initialValue: target.edit)
        _attachmentId = State(initialValue: target.attachmentId)
    }

    private var item: Item? { model.items.first { $0.id == target.itemId } }
    private var attachment: Attachment? { item?.attachments.first { $0.id == attachmentId } }
    private var isPDF: Bool { attachment?.mime == "application/pdf" }
    private var canEdit: Bool { attachment.map(AppModel.canInk) ?? false }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.gray.opacity(0.12))
        .task(id: attachmentId) {
            data = nil
            failed = false
            guard let attachment else { failed = true; return }
            do { data = try await model.library?.attachmentData(attachment) } catch { failed = true }
        }
        .quickLookPreview($quickLook)
        #if os(iOS)
        .sheet(item: $markupURL) { url in
            MarkupSheet(url: url) { edited in Task { await saveMarkup(edited) } }
                .ignoresSafeArea()
        }
        #else
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }

    // MARK: The toolbar

    private var bar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(editing ? nil : .cancelAction)
                .help("Close (anything edited is saved)")
            Text(attachment?.name ?? target.title).font(.headline).lineLimit(1)
            if editing {
                // Which mode it's in, at a glance (the bar is tinted too).
                Label("Editing", systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 8)
            if editing, isPDF {
                Picker("Edit with", selection: $pdfTool) {
                    Text("Pen").tag(PDFEditTool.pen)
                    Text("Highlight & fill").tag(PDFEditTool.marks)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Draw with Trove's pen, or highlight text and fill in the form")
            }
            #if os(iOS)
            if editing, canMarkup {
                Button { Task { markupURL = await markupCopy() } } label: { Label("Markup", systemImage: "signature") }
                    .help("Apple's Markup: sign or scribble. Saved as a new version; the original stays under Versions.")
            }
            #endif
            if let item, let attachment, FilePrinter.isPrintable(attachment) {
                FilePrintButton(item: item, attachment: attachment)
            }
            if canEdit {
                if editing {
                    Button("Done") { editing = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Edit") { editing = true }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("e", modifiers: .command)
                        .help("Draw, highlight and fill in the form; Done goes back to view-only")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(editing ? Color.accentColor.opacity(0.16) : Color.clear)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: editing)
    }

    // MARK: What's shown

    @ViewBuilder
    private var content: some View {
        if let item, let attachment, let data {
            if editing, AppModel.canInk(attachment), !(isPDF && pdfTool == .marks) {
                // Trove's pen: the ink editor on the file (saved and synced as you go).
                InkEditorView(target: InkTarget(itemId: item.id, layer: attachment.id, title: attachment.name, startPage: target.startPage),
                              app: model, embedded: true)
                    .id("ink-\(attachment.id)")
            } else if isPDF {
                PDFReaderView(item: item, attachment: attachment, data: data, fullScreen: true, editable: editing, startPage: target.startPage)
                    .id("pdf-\(attachment.id)")
            } else if AppModel.canInk(attachment) {
                FilePagesView(item: item, attachment: attachment, data: data, startPage: target.startPage)
                    .id("pages-\(attachment.id)")
            } else if attachment.mime.hasPrefix("audio/") {
                AudioPlayerView(data: data).padding(24).frame(maxWidth: 520)
            } else {
                // Types Trove can't show itself: Quick Look.
                VStack(spacing: 16) {
                    AttachmentView(attachment: attachment, item: item).frame(maxWidth: 640)
                    Button { Task { quickLook = await model.temporaryFile(attachment) } } label: { Label("Quick Look", systemImage: "eye") }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
        } else if failed {
            EmptyState(symbol: "icloud.slash", title: "Can't open it", message: "It may still be syncing, or it was deleted.")
        } else {
            ProgressView("Opening…")
        }
    }

    // MARK: Markup (iPhone/iPad)

    #if os(iOS)
    /// Markup changes the file itself, so it's offered for the item's main file (which gets versions).
    private var canMarkup: Bool {
        guard let item, let attachment else { return false }
        return item.attachments.first?.id == attachment.id && (attachment.mime == "application/pdf" || attachment.mime.hasPrefix("image/"))
    }

    private func markupCopy() async -> URL? {
        guard let attachment else { return nil }
        return await model.temporaryFile(attachment)
    }

    /// Markup's copy becomes the file's new version (the one before is kept under Versions).
    private func saveMarkup(_ url: URL) async {
        guard let item else { return }
        await model.replaceFile(item, with: url)
        model.toast = "Markup saved as a new version. The original is under Versions."
        if let first = model.items.first(where: { $0.id == item.id })?.attachments.first { attachmentId = first.id }
    }
    #endif
}

/// A file Trove draws itself (pictures, GoodNotes notebooks) with its ink, as vector PDF pages in
/// PDFKit's view: scroll and zoom, nothing changes.
struct FilePagesView: View {
    let item: Item
    let attachment: Attachment
    let data: Data
    var startPage = 0
    @Environment(AppModel.self) private var model
    @State private var document: PDFDocument?

    var body: some View {
        Group {
            if let document {
                ZoomablePDFView(document: document, startPage: startPage)
            } else {
                ProgressView()
            }
        }
        .task(id: model.inkRevision) { await render() }
    }

    private func render() async {
        guard let library = model.library else { return }
        let data = data, mime = attachment.mime, name = attachment.name
        let specs = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime, name: name) }.value
        var input: [(spec: InkPageSpec, content: InkContent, bounds: InkGeometry.Rect?)] = []
        for spec in specs {
            let (content, _) = await SketchSection.page(library, itemId: item.id, layer: attachment.id, spec: spec)
            input.append((spec, content, nil))
        }
        let pages = input
        if let pdf = await Task.detached(priority: .userInitiated, operation: { InkRenderer.pdf(pages: pages) }).value {
            document = PDFDocument(data: pdf)
        }
    }
}

#if os(iOS)
struct ZoomablePDFView: UIViewRepresentable {
    let document: PDFDocument
    var startPage = 0
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        if startPage > 0, let page = document.page(at: startPage) { view.go(to: page) }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Apple's Markup on a copy of the file (Quick Look's editor); the edited copy is handed back.
struct MarkupSheet: UIViewControllerRepresentable {
    let url: URL
    let onSave: @MainActor @Sendable (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onSave: onSave) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate, @unchecked Sendable {
        let url: URL
        let onSave: @MainActor @Sendable (URL) -> Void
        init(url: URL, onSave: @escaping @MainActor @Sendable (URL) -> Void) { self.url = url; self.onSave = onSave }

        nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
        nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .createCopy }

        nonisolated func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
            // The edited copy is only there for now: keep it under the file's own name.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Markup-\(UUID().uuidString)", isDirectory: true)
            let out = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: modifiedContentsURL, to: out)
            } catch { return }
            let onSave = onSave
            Task { @MainActor in onSave(out) }
        }
    }
}
#else
struct ZoomablePDFView: NSViewRepresentable {
    let document: PDFDocument
    var startPage = 0
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        if startPage > 0, let page = document.page(at: startPage) { view.go(to: page) }
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif

// MARK: Printing

/// Prints a file straight away: the system's print panel (UIPrintInteractionController on
/// iPhone/iPad, PDFKit's print operation on the Mac). PDFs print with Trove's ink, highlights and
/// form values (as annotations, `PDFReaderModel.annotated`) or as the original.
@MainActor
enum FilePrinter {
    static func isPrintable(_ a: Attachment) -> Bool {
        if a.mime == "application/pdf" || (a.mime.hasPrefix("image/") && a.mime != "image/svg+xml") { return true }
        #if os(iOS)
        if let type = UTType(mimeType: a.mime) ?? UTType(filenameExtension: (a.name as NSString).pathExtension) {
            return UIPrintInteractionController.printableUTIs.contains(type.identifier)
        }
        #endif
        return false
    }

    static func print(_ item: Item, _ a: Attachment, withMarks: Bool, model: AppModel) async {
        guard let library = model.library, var data = try? await library.attachmentData(a) else { model.toast = "Couldn't print \(a.name)"; return }
        var name = a.name
        if withMarks, a.mime == "application/pdf" {
            let strokes = await library.strokes(on: item.id, layer: a.id)
            let elements = await library.elements(on: item.id, layer: a.id)
            let original = data
            if let out = await Task.detached(priority: .userInitiated, operation: { PDFReaderModel.annotated(original, strokes: strokes, elements: elements) }).value {
                data = out
                let base = (a.name as NSString).deletingPathExtension
                name = (base.isEmpty ? "Document" : base) + " (with ink).pdf"
            }
        }
        #if os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = name
        info.outputType = a.mime.hasPrefix("image/") ? .photo : .general
        controller.printInfo = info
        controller.printingItem = TemporaryFile(name: name, data: data).url
        controller.present(animated: true)
        #else
        let document: PDFDocument?
        if a.mime == "application/pdf" {
            document = PDFDocument(data: data)
        } else if let image = NSImage(data: data), let page = PDFPage(image: image) {
            let d = PDFDocument()
            d.insert(page, at: 0)
            document = d
        } else {
            document = nil
        }
        guard let document, let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
            model.toast = "Couldn't print \(a.name)"
            return
        }
        operation.jobTitle = name
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        #endif
    }
}

/// Print: for a PDF, with your ink and highlights or the original; anything else as it is.
struct FilePrintButton: View {
    let item: Item
    let attachment: Attachment
    @Environment(AppModel.self) private var model

    var body: some View {
        if attachment.mime == "application/pdf" {
            Menu {
                FilePrintItems(item: item, attachment: attachment)
            } label: { Label("Print", systemImage: "printer") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Print")
        } else {
            Button { Task { await FilePrinter.print(item, attachment, withMarks: false, model: model) } } label: { Label("Print", systemImage: "printer") }
                .help("Print")
        }
    }
}

/// The print choices, for menus.
struct FilePrintItems: View {
    let item: Item
    let attachment: Attachment
    @Environment(AppModel.self) private var model

    var body: some View {
        if attachment.mime == "application/pdf" {
            Button { Task { await FilePrinter.print(item, attachment, withMarks: true, model: model) } } label: {
                Label("Print with my ink and highlights", systemImage: "printer")
            }
            Button { Task { await FilePrinter.print(item, attachment, withMarks: false, model: model) } } label: {
                Label("Print the original", systemImage: "doc")
            }
        } else {
            Button { Task { await FilePrinter.print(item, attachment, withMarks: false, model: model) } } label: { Label("Print", systemImage: "printer") }
        }
    }
}
