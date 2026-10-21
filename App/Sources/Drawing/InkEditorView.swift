import PhotosUI
import SwiftUI
import TroveCore
import UniformTypeIdentifiers

/// The drawing editor: a sketch's pages (or endless canvas), or a PDF or image to write on. Pens,
/// the eraser, the lasso, shapes, text and pictures; colours and sizes; undo and redo; a page panel;
/// export to PDF. The same tools as the website's (web/public/draw.js).
struct InkEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editor: InkEditorModel
    @State private var importingPicture = false
    @State private var photo: PhotosPickerItem?
    @State private var exportFile: PDFFile?
    @State private var confirmDeletePage: String?
    @State private var pageSettings = false
    /// The second row under the tools (the chosen tool's colours, sizes and modes), like GoodNotes.
    @State private var showOptions = true

    init(target: InkTarget, app: AppModel) {
        _editor = State(initialValue: InkEditorModel(target: target, app: app))
    }

    // The canvas, zoom pill and undo buttons are their own views, each watching only what it shows:
    // a stroke then redraws the canvas, not the whole editor with its toolbar.
    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            toolbar
            if showOptions, hasOptions { optionsBar }
            Divider()
            ZStack(alignment: .bottom) {
                Color.gray.opacity(0.18).ignoresSafeArea()
                if editor.loaded, editor.currentPage != nil {
                    InkCanvasHost(editor: editor)
                } else if let failed = editor.failed {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Can't draw here", message: failed)
                } else {
                    ProgressView("Opening…")
                }
                if let selection = editor.selection { selectionBar(selection).padding(.bottom, 16) }
                if editor.loaded { InkZoomCorner(editor: editor) }
                if let p = editor.palette {
                    GeometryReader { geo in
                        // Tap anywhere else to close it.
                        Color.black.opacity(0.001).onTapGesture { editor.palette = nil }
                        InkPalette(editor: editor)
                            .position(x: min(max(p.x, InkPalette.width / 2 + 8), geo.size.width - InkPalette.width / 2 - 8),
                                      y: min(max(p.y - 70, 60), geo.size.height - 60))
                    }
                    .transition(.opacity)
                }
            }
            if showsPageBar { pageBar }
        }
        .task { await editor.load() }
        .task(id: app.inkRevision) { if editor.loaded { await editor.reloadInk() } }
        .onAppear { app.drawingOpen += 1 }
        .onDisappear { app.drawingOpen = max(0, app.drawingOpen - 1) }
        .inspector(isPresented: $editor.showPages) { InkPagesPanel(editor: editor, confirmDelete: $confirmDeletePage) }
        .sheet(item: $editor.textEdit) { edit in InkTextSheet(edit: edit) { editor.commitText($0) } }
        .fileImporter(isPresented: $importingPicture, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { editor.insertPicture(data, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png") }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    editor.insertPicture(data, mime: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg")
                }
            }
        }
        .onChange(of: editor.exportedPDF) { _, data in
            if let data { exportFile = PDFFile(data: data); editor.exportedPDF = nil }
        }
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }), document: exportFile,
                      contentType: .pdf, defaultFilename: editor.target.title) { _ in exportFile = nil }
        .confirmationDialog("Delete this page and everything on it?", isPresented: Binding(get: { confirmDeletePage != nil }, set: { if !$0 { confirmDeletePage = nil } })) {
            Button("Delete page", role: .destructive) { if let key = confirmDeletePage { editor.deletePage(key) }; confirmDeletePage = nil }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear { Task { await editor.finish() } } // closing the window counts as Done
        #endif
    }

    /// Page by page with arrows: files and flipping (and on the Mac, which shows one page at a time).
    private var showsPageBar: Bool {
        #if os(macOS)
        return editor.pages.count > 1 || (editor.isSketch && !editor.isInfinite)
        #else
        return editor.layout == .flip && !editor.isInfinite && (editor.pages.count > 1 || editor.isSketch)
        #endif
    }

    // MARK: Toolbar: the tools on top, the chosen one's options underneath

    private static let tools: [InkEditorTool] = [.pen, .pencil, .fountain, .brush, .marker, .highlighter, .eraser, .lasso, .text, .laser]

    private var toolbar: some View {
        @Bindable var editor = editor
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    InkUndoButtons(editor: editor)
                    Divider().frame(height: 26)
                    HStack(spacing: 2) {
                        ForEach(Self.tools) { t in
                            Button {
                                // Tapping the chosen tool again shows or hides its options, like GoodNotes.
                                if editor.tool == t { withAnimation(.snappy(duration: 0.2)) { showOptions.toggle() } } else { editor.select(t); showOptions = true }
                            } label: {
                                Image(systemName: t.symbol)
                                    .font(.title3)
                                    .frame(width: 38, height: 34)
                                    .foregroundStyle(editor.tool == t ? Color.accentColor : Color.primary)
                                    .background(editor.tool == t ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(alignment: .bottom) {
                                        // The pen's colour under its icon.
                                        if t.ink != nil { Capsule().fill(Color(inkHex: editor.color(for: t))).frame(width: 14, height: 3).offset(y: 1) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(t.label)
                            .accessibilityLabel(t.label)
                            .accessibilityAddTraits(editor.tool == t ? .isSelected : [])
                        }
                        Toggle(isOn: $editor.shapeMode) { Image(systemName: "triangle") }
                            .toggleStyle(.button)
                            .help("Shapes: lines and shapes come out clean (or hold the pen still at the end of one)")
                            .accessibilityLabel("Shapes")
                        Menu {
                            #if os(iOS)
                            PhotosPicker(selection: $photo, matching: .images) { Label("From Photos", systemImage: "photo") }
                            #endif
                            Button { importingPicture = true } label: { Label("From Files…", systemImage: "folder") }
                        } label: { Image(systemName: "photo.badge.plus").font(.title3) }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Insert a picture")
                        .accessibilityLabel("Picture")
                    }
                    Divider().frame(height: 26)
                    HStack(spacing: 6) {
                        Button { pageSettings = true } label: { Label(editor.isSketch ? "Page" : "View", systemImage: "doc.richtext") }
                            .popover(isPresented: $pageSettings) { InkPageSettings(editor: editor).frame(minWidth: 320, idealWidth: 360, minHeight: 420) }
                        if editor.isSketch && !editor.isInfinite {
                            Button { editor.showPages.toggle() } label: { Label("Pages", systemImage: "rectangle.stack") }
                                .help("All pages")
                        }
                        Menu {
                            Toggle("Scribble to erase", isOn: $editor.scribbleToErase)
                            Toggle("Shapes come out clean", isOn: $editor.shapeMode)
                            Picker("When a drawing opens", selection: $editor.fitWholePage) {
                                Text("Show the whole page").tag(true)
                                Text("Fit the page width").tag(false)
                            }
                        } label: { Label("Settings", systemImage: "gearshape") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button { editor.exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                            .disabled(editor.exporting)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                    Text(editor.target.title).font(.headline).lineLimit(1).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Button("Done") { Task { await editor.finish() }; dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 12)
        }
        .background(.bar)
        // The lasso's keys (the Mac and iPad keyboards).
        .background {
            Group {
                Button("Select all") { editor.selectAll() }.keyboardShortcut("a", modifiers: .command)
                Button("Copy") { editor.copySelection() }.keyboardShortcut("c", modifiers: .command).disabled(editor.selection == nil)
                Button("Cut") { editor.cutSelection() }.keyboardShortcut("x", modifiers: .command).disabled(editor.selection == nil)
                Button("Duplicate") { editor.duplicateSelection() }.keyboardShortcut("d", modifiers: .command).disabled(editor.selection == nil)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private var hasOptions: Bool { editor.tool.hasColor || editor.tool.hasSize || editor.tool == .lasso }

    /// The chosen tool's colours, sizes and modes.
    private var optionsBar: some View {
        @Bindable var editor = editor
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Text(editor.tool.label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                if editor.tool.hasColor {
                    HStack(spacing: 6) {
                        ForEach(InkEditorModel.colors, id: \.self) { c in
                            Button { editor.color = c } label: {
                                Circle().fill(Color(inkHex: c)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                    .overlay(Circle().strokeBorder(editor.color == c ? Color.accentColor : .gray.opacity(0.4), lineWidth: editor.color == c ? 2 : 1).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(c)")
                        }
                        ColorPicker("Any colour", selection: Binding(get: { Color(inkHex: editor.color) }, set: { editor.color = $0.inkHex }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                if editor.tool.hasSize {
                    InkSizePresets(editor: editor)
                    Slider(value: $editor.width, in: editor.tool == .eraser && editor.eraserMode == .precise ? 0.5...12 : 1...(editor.tool == .text ? 72 : 60))
                        .frame(width: 110)
                }
                if editor.tool == .eraser {
                    Picker("Eraser", selection: $editor.eraserMode) {
                        ForEach(InkEraserMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Toggle("Highlighter only", isOn: $editor.highlighterOnly).fixedSize()
                }
                if editor.tool == .lasso {
                    Text(editor.selection == nil ? "Draw a loop around what to select" : "Drag to move, corners to resize")
                        .font(.callout).foregroundStyle(.secondary)
                    if editor.selection != nil {
                        HStack(spacing: 6) {
                            ForEach(InkEditorModel.colors, id: \.self) { c in
                                Button { editor.recolourSelection(c) } label: { Circle().fill(Color(inkHex: c)).frame(width: 20, height: 20) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Recolour \(c)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The lasso's actions while something is selected.
    private func selectionBar(_ selection: InkSelection) -> some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
            Button("Duplicate") { editor.duplicateSelection() }
            Button("Copy") { editor.copySelection() }
            Button("Cut") { editor.cutSelection() }
            Button("Delete", role: .destructive) { editor.deleteSelection() }
            Button { editor.clearSelection() } label: { Image(systemName: "xmark") }.accessibilityLabel("Deselect")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var pageBar: some View {
        HStack(spacing: 16) {
            Button { editor.page = max(0, editor.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(editor.page == 0)
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Text("Page \(editor.page + 1) of \(max(1, editor.pages.count))").font(.callout.monospacedDigit())
            Button { editor.page = min(editor.pages.count - 1, editor.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(editor.page >= editor.pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: .command)
            if editor.isSketch {
                Button { editor.addPage(after: editor.currentKey) } label: { Label("Page", systemImage: "plus") }.buttonStyle(.bordered)
                Button { editor.showPages.toggle() } label: { Label("Pages", systemImage: "rectangle.stack") }.buttonStyle(.bordered)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The drawing surface. Only this view watches the ink's revisions, so drawing doesn't redraw the toolbar.
struct InkCanvasHost: View {
    let editor: InkEditorModel

    var body: some View {
        #if os(iOS)
        PencilCanvas(editor: editor, pages: editor.pages, current: editor.page, layout: editor.isInfinite ? .vertical : editor.layout,
                     pagesRevision: editor.pagesRevision, revision: editor.revision, overlayRevision: editor.overlayRevision,
                     tool: editor.tool, color: editor.color, width: editor.width, zoomRequest: editor.zoomRequest)
            .ignoresSafeArea(edges: .bottom)
        #else
        if let page = editor.currentPage {
            MouseInkCanvas(editor: editor, page: page, pageIndex: editor.page, pagesRevision: editor.pagesRevision, revision: editor.revision,
                           overlayRevision: editor.overlayRevision, tool: editor.tool, color: editor.color, width: editor.width, zoomRequest: editor.zoomRequest)
        }
        #endif
    }
}

/// Undo, redo and paste: their own view, since every stroke changes whether they're enabled.
struct InkUndoButtons: View {
    let editor: InkEditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!editor.canUndo).keyboardShortcut("z", modifiers: .command)
            Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!editor.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            if editor.canPaste {
                Button { editor.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: .command)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .frame(height: 34)
    }
}

/// Three quick sizes for the chosen tool (small, medium, large), like GoodNotes.
struct InkSizePresets: View {
    let editor: InkEditorModel

    static func sizes(_ tool: InkEditorTool, precise: Bool) -> [Double] {
        if tool == .eraser && precise { return [1, 3, 6] }
        let d = tool.defaultWidth
        return [d * 0.5, d, d * 2].map { ($0 * 2).rounded() / 2 }
    }

    var body: some View {
        let sizes = Self.sizes(editor.tool, precise: editor.eraserMode == .precise)
        HStack(spacing: 4) {
            ForEach(Array(sizes.enumerated()), id: \.offset) { i, w in
                Button { editor.width = w } label: {
                    Circle()
                        .fill(editor.tool == .eraser ? Color.secondary : Color(inkHex: editor.color))
                        .frame(width: CGFloat(6 + i * 5), height: CGFloat(6 + i * 5))
                        .frame(width: 30, height: 30)
                        .background(abs(editor.width - w) < 0.01 ? Color.accentColor.opacity(0.16) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Thin", "Medium", "Thick"][i])
            }
        }
    }
}

/// Bottom left: the zoom (10 % to 1000 %, back to 100 %) and which page this is. Its own view, since
/// the zoom changes on every frame of a pinch.
struct InkZoomCorner: View {
    let editor: InkEditorModel

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Reset to 100%") { editor.requestZoom(.scale(1)) }
                if !editor.isInfinite {
                    Button("Whole page") { editor.requestZoom(.wholePage) }
                    Button("Page width") { editor.requestZoom(.pageWidth) }
                }
                Divider()
                ForEach([0.1, 0.25, 0.5, 2, 4, 10], id: \.self) { z in Button("\(Int(z * 100))%") { editor.requestZoom(.scale(z)) } }
                Divider()
                Button { editor.requestZoom(.scale(editor.zoom * 1.25)) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                Button { editor.requestZoom(.scale(editor.zoom / 1.25)) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
            } label: {
                Text("\(Int((editor.zoom * 100).rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(minWidth: 58, minHeight: 32)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.gray.opacity(0.25)))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Zoom \(Int((editor.zoom * 100).rounded())) percent")
            if editor.pages.count > 1, !editor.isInfinite {
                Text("\(editor.page + 1) / \(editor.pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - The page panel

/// A sketch's pages: tap to go to one, drag to reorder, and per page: add after, duplicate, delete,
/// paper and colour.
struct InkPagesPanel: View {
    let editor: InkEditorModel
    @Binding var confirmDelete: String?
    @State private var thumbs: [String: InkImage] = [:]

    var body: some View {
        List {
            Section("Pages") {
                ForEach(Array(editor.pages.enumerated()), id: \.element.key) { index, page in
                    Button { editor.page = index } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Color.white
                                if let t = thumbs[page.key] { Image(decorative: t.image, scale: 2).resizable() }
                            }
                            .aspectRatio(page.width / page.height, contentMode: .fit)
                            .frame(width: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(index == editor.page ? Color.accentColor : .gray.opacity(0.3), lineWidth: index == editor.page ? 2 : 1))
                            Text("\(index + 1)").font(.callout.monospacedDigit())
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { editor.addPage(after: page.key) } label: { Label("Add page after", systemImage: "plus") }
                        Button { editor.duplicatePage(page.key) } label: { Label("Duplicate page", systemImage: "plus.square.on.square") }
                        if editor.pages.count > 1 {
                            Button(role: .destructive) { confirmDelete = page.key } label: { Label("Delete page", systemImage: "trash") }
                        }
                    }
                }
                .onMove { from, to in
                    guard let first = from.first else { return }
                    let key = editor.pages[first].key
                    editor.movePage(key, to: to > first ? to - 1 : to)
                }
            }
            if let page = editor.currentPage, case .paper(let paper, let color) = page.background {
                Section("This page") {
                    Picker("Paper", selection: Binding(get: { paper }, set: { editor.setPage(page.key, paper: $0) })) {
                        ForEach(InkPaper.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    HStack(spacing: 8) {
                        ForEach(InkPage.colors, id: \.self) { c in
                            Button { editor.setPage(page.key, color: c == "#ffffff" ? "" : c) } label: {
                                Circle().fill(Color(inkHex: c)).frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder((color ?? "#ffffff") == c ? Color.accentColor : .gray.opacity(0.4), lineWidth: (color ?? "#ffffff") == c ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Page colour \(c)")
                        }
                    }
                    Button { editor.addPage(after: page.key) } label: { Label("Add page after", systemImage: "plus") }
                    Button { editor.duplicatePage(page.key) } label: { Label("Duplicate page", systemImage: "plus.square.on.square") }
                    if editor.pages.count > 1 {
                        Button(role: .destructive) { confirmDelete = page.key } label: { Label("Delete page", systemImage: "trash") }
                    }
                }
            }
        }
        .task(id: "\(editor.revision)-\(editor.pagesRevision)") { await renderThumbs() }
        .inspectorColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private func renderThumbs() async {
        // Wait for a pause in the drawing (a new stroke cancels this and starts again).
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        for page in editor.pages where !page.infinite {
            let content = editor.display(page.key)
            if let image = await Task.detached(priority: .utility, operation: { InkRenderer.render(page, content: content, pixelWidth: 160).map(InkImage.init) }).value {
                thumbs[page.key] = image
            }
        }
    }
}

// MARK: - Text boxes

/// Typing in a text box: its words, size and colour.
struct InkTextSheet: View {
    @State var edit: InkTextEdit
    var done: (InkTextEdit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $edit.text)
                    .font(.system(size: min(28, max(13, edit.size * 0.8))))
                    .foregroundStyle(Color(inkHex: edit.color))
                    .frame(minHeight: 140)
                LabeledContent("Size") {
                    Slider(value: $edit.size, in: 8...72)
                }
                ColorPicker("Colour", selection: Binding(get: { Color(inkHex: edit.color) }, set: { edit.color = $0.inkHex }), supportsOpacity: false)
                if edit.elementId != nil {
                    Text("Delete all the text to remove the box.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(edit.elementId == nil ? "New text" : "Edit text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { done(edit); dismiss() } }
            }
        }
        #if os(macOS)
        .sheetSize(width: 480, height: 400)
        #endif
    }
}

/// An exported drawing, for the save panel.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension Color {
    init(inkHex hex: String) {
        let (r, g, b) = InkStroke.rgb(hex)
        self.init(red: r, green: g, blue: b)
    }

    /// "#rrggbb" for the editor's colours.
    var inkHex: String {
        #if os(iOS)
        return PencilCanvas.hex(UIColor(self))
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        #endif
    }
}

// MARK: - Previews in the item view

/// A sketch's pages in its item view: tap one to draw on it.
struct SketchSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var images: [String: InkImage] = [:]

    private var pages: [InkPageSpec] { InkRenderer.sketchPages(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.isInfiniteCanvas ? "Endless canvas" : "\(item.sketchPages) page\(item.sketchPages == 1 ? "" : "s")", systemImage: "scribble.variable").font(.headline)
                Spacer()
                Button { model.draw(on: item) } label: { Label("Draw", systemImage: "pencil.tip") }
                    .buttonStyle(.borderedProminent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: item.isInfiniteCanvas ? 280 : 140), spacing: 12)], spacing: 12) {
                ForEach(Array(pages.enumerated()), id: \.element.key) { index, page in
                    Button { model.draw(on: item, page: index) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Color.white
                                if let image = images[page.key] { Image(decorative: image.image, scale: 2).resizable().scaledToFit() }
                            }
                            .aspectRatio(page.infinite ? 4 / 3 : page.width / page.height, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            if pages.count > 1 { Text("\(index + 1)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let text = item.inkText, !text.isEmpty {
                Label("Handwriting read for search: \(text.prefix(140))\(text.count > 140 ? "…" : "")", systemImage: "text.viewfinder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
        .task(id: "\(model.inkRevision)-\(item.record.updatedHLC)-\(model.inkTarget == nil)") { await render() }
    }

    private func render() async {
        // Behind the open editor nobody sees these: redraw once it closes.
        guard model.inkTarget == nil, let library = model.library else { return }
        for page in pages {
            let content = await Self.content(library, itemId: item.id, layer: "", key: page.key)
            var area: InkGeometry.Rect?
            if page.infinite {
                let b = await library.inkBounds(on: item.id, pageKey: page.key) ?? InkGeometry.Rect(x: 0, y: 0, width: 800, height: 600)
                area = InkGeometry.Rect(x: b.x - 24, y: b.y - 24, width: max(300, b.width + 48), height: max(225, b.height + 48))
            }
            let box = area
            images[page.key] = await Task.detached(priority: .utility) { InkRenderer.render(page, content: content, pixelWidth: 480, area: box).map(InkImage.init) }.value
        }
    }

    /// A page's ink with its pictures, for previews.
    static func content(_ library: Library, itemId: String, layer: String, key: String) async -> InkContent {
        var c = InkContent()
        c.strokes = await library.strokes(on: itemId, layer: layer, pageKey: key).map(InkLine.init)
        let elements = await library.elements(on: itemId, layer: layer, pageKey: key)
        c.elements = elements.map(InkBox.init)
        for e in elements {
            if let att = e.image, let data = try? await library.attachmentData(att), let image = InkRenderer.cgImage(data) { c.pictures[att.id] = image }
        }
        return c
    }
}

/// A PDF or image with ink on it, page by page.
struct InkedFileView: View {
    let item: Item
    let attachment: Attachment
    let data: Data
    @Environment(AppModel.self) private var model
    @State private var pages: [InkPageSpec] = []
    @State private var images: [String: InkImage] = [:]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(pages.enumerated()), id: \.element.key) { index, page in
                ZStack {
                    Color.white
                    if let image = images[page.key] { Image(decorative: image.image, scale: 2).resizable() } else { ProgressView() }
                }
                .aspectRatio(page.width / page.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .onTapGesture { model.inkTarget = InkTarget(itemId: item.id, layer: attachment.id, title: attachment.name, startPage: index) }
            }
        }
        .task(id: model.inkRevision) { await render() }
    }

    private func render() async {
        guard let library = model.library else { return }
        let data = data, mime = attachment.mime, name = attachment.name
        if pages.isEmpty { pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime, name: name) }.value }
        for page in pages {
            let content = await SketchSection.content(library, itemId: item.id, layer: attachment.id, key: page.key)
            let width = Int(min(2400, page.width * 2))
            images[page.key] = await Task.detached(priority: .userInitiated) { InkRenderer.render(page, content: content, pixelWidth: width).map(InkImage.init) }.value
        }
    }
}
