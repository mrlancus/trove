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
    @State private var penOptions = false
    /// The second row under the tools (the chosen tool's colours, sizes and modes), like GoodNotes.
    @State private var showOptions = true
    @State private var elementsOpen = false
    @State private var savingElement = false
    @State private var elementName = ""
    @State private var elementFolder = ""

    init(target: InkTarget, app: AppModel) {
        _editor = State(initialValue: InkEditorModel(target: target, app: app))
    }

    // The canvas, zoom pill and undo buttons are their own views, each watching only what it shows:
    // a stroke then redraws the canvas, not the whole editor with its toolbar.
    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            toolbar
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
                if let selection = editor.selection { selectionBar(selection).padding(.bottom, 52) } // above the zoom pill
                if editor.loaded { InkZoomCorner(editor: editor) }
                if let p = editor.palette {
                    GeometryReader { geo in
                        // Tap anywhere else to close it.
                        Color.black.opacity(0.001).onTapGesture { editor.palette = nil }
                        // The arcs' centre on the Pencil's tip, kept on screen.
                        InkPalette(editor: editor)
                            .position(x: min(max(p.x, InkPalette.width / 2 + 8), geo.size.width - InkPalette.width / 2 - 8),
                                      y: min(max(p.y - (InkPalette.centre.y - InkPalette.height / 2), InkPalette.height / 2 + 8), geo.size.height - InkPalette.height / 2 - 8))
                    }
                    .transition(.opacity)
                }
            }
            // The options row lies over the top of the canvas, so showing or hiding it doesn't change
            // the canvas's size (that refitted the pages and moved the sketch).
            .overlay(alignment: .top) {
                if showOptions, hasOptions { optionsBar }
            }
            .clipped()
            if showsPageBar { pageBar }
        }
        .task { await editor.load() }
        .task(id: app.inkPulledRevision) { if editor.loaded { await editor.reloadInk() } }
        .onAppear { app.drawingOpen += 1 }
        .onDisappear { app.drawingOpen = max(0, app.drawingOpen - 1) }
        .inspector(isPresented: $editor.showPages) { InkPagesPanel(editor: editor, confirmDelete: $confirmDeletePage) }
        .sheet(item: $editor.aiResult) { result in InkAIResultSheet(result: result, editor: editor) }
        .alert("Save as element", isPresented: $savingElement) {
            TextField("Name", text: $elementName)
            TextField("Folder (optional)", text: $elementFolder)
            Button("Save") { editor.saveSelectionAsElement(name: elementName, folder: elementFolder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved elements are on every device, in the Elements library.")
        }
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

    private static let tools: [InkEditorTool] = [.pen, .ballpoint, .pencil, .fountain, .brush, .marker, .highlighter, .eraser, .lasso, .shape, .text, .laser, .tape]

    private var toolbar: some View {
        @Bindable var editor = editor
        // Undo and redo on the left and the page, settings, export and Done on the right stay put;
        // only the tools between them scroll.
        return HStack(spacing: 0) {
            InkUndoButtons(editor: editor)
                .padding(.leading, 12)
                .padding(.trailing, 6)
            Divider().frame(height: 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    HStack(spacing: 2) {
                        ForEach(Self.tools) { t in
                            Button {
                                // Tapping the chosen tool again shows or hides its options, like GoodNotes.
                                if editor.tool == t { showOptions.toggle() } else { editor.select(t); showOptions = true }
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
                                    .inkTapArea()
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
                        Button { elementsOpen = true } label: { Image(systemName: "square.grid.2x2").font(.title3).frame(width: 34, height: 34).inkTapArea() }
                            .buttonStyle(.plain)
                            .help("Elements: stickers, arrows, checkboxes and what you saved")
                            .accessibilityLabel("Elements")
                            .popover(isPresented: $elementsOpen) { InkElementsLibrary(editor: editor) { elementsOpen = false }.frame(minWidth: 320, idealWidth: 380, minHeight: 360) }
                        InkGuideButtons(editor: editor)
                    }
                    if !editor.inkSettings.favourites.isEmpty {
                        Divider().frame(height: 26)
                        InkFavouritesRow(editor: editor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
                    Toggle("Smaller drawings (every device up to date)", isOn: Binding(get: { editor.inkSettings.compactPoints }, set: { editor.setCompactPoints($0) }))
                    if !editor.inkSettings.favourites.isEmpty {
                        Menu("Remove a favourite pen") {
                            ForEach(Array(editor.inkSettings.favourites.enumerated()), id: \.offset) { i, f in
                                Button("\(i + 1): \(InkEditorTool(rawValue: f.tool.rawValue)?.label ?? "Pen"), \(f.color), size \(f.width.formatted())") { editor.removeFavourite(f) }
                            }
                        }
                    }
                    Picker("When a drawing opens", selection: $editor.fitWholePage) {
                        Text("Show the whole page").tag(true)
                        Text("Fit the page width").tag(false)
                    }
                } label: { Label("Settings", systemImage: "gearshape") }
                .menuIndicator(.hidden)
                .fixedSize()
                if editor.isSketch {
                    Button { editor.darkPage.toggle() } label: {
                        Label(editor.darkPage ? "Light page" : "Dark page", systemImage: editor.darkPage ? "sun.max" : "moon")
                    }
                    .help(editor.darkPage ? "Show the page light" : "Show the page dark (black page, black and white ink swapped; only on this device)")
                }
                Button { editor.exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                    .disabled(editor.exporting)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3)
            .padding(.leading, 10)
            .fixedSize()
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

    /// The shape tool's shapes.
    private var shapeKinds: some View {
        HStack(spacing: 2) {
            ForEach(InkShapeKind.allCases) { kind in
                Button { editor.shapeKind = kind } label: {
                    Image(systemName: kind.symbol)
                        .frame(width: 32, height: 30)
                        .foregroundStyle(editor.shapeKind == kind ? Color.accentColor : Color.primary)
                        .background(editor.shapeKind == kind ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .inkTapArea()
                }
                .buttonStyle(.plain)
                .help(kind.label)
                .accessibilityLabel(kind.label)
                .accessibilityAddTraits(editor.shapeKind == kind ? .isSelected : [])
            }
        }
    }

    /// The chosen tool's colours, sizes and modes.
    static let optionsHeight: CGFloat = 48
    static let toolNameWidth: CGFloat = 108

    private var optionsBar: some View {
        @Bindable var editor = editor
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Every tool's name takes the same room, so its options always start in one place.
                Text(editor.tool.label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: Self.toolNameWidth, alignment: .leading)
                Divider().frame(height: 26)
                if editor.tool.hasColor { InkColorPresets(editor: editor) }
                if editor.tool == .shape { shapeKinds }
                if editor.tool == .text || editor.textEdit != nil || editor.selectionHasText { InkTextStyleBar(editor: editor) }
                if editor.tool.ink != nil || editor.tool == .shape {
                    Button(editor.tool == .shape ? "Line options" : "Pen options") { penOptions = true }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $penOptions) {
                            // A Form in a popover has no height of its own: sized to show everything.
                            InkPenOptions(editor: editor)
                                .frame(minWidth: 340, idealWidth: 380, maxWidth: 420, minHeight: editor.tool.ink != nil ? 440 : 260, idealHeight: editor.tool.ink != nil ? 480 : 280)
                                .presentationCompactAdaptation(.popover)
                        }
                    if editor.tool != .shape {
                        Button("Save pen") { editor.saveFavourite() }
                            .buttonStyle(.bordered)
                            .help("Keep this pen, colour and size as a favourite (on every device)")
                    }
                }
                if editor.tool.hasSize {
                    InkSizePresets(editor: editor)
                    Slider(value: $editor.width, in: editor.sizeRange(editor.tool))
                        .frame(width: 110)
                    Text(InkSizeUnit.label(editor.width, tool: editor.tool))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                }
                if editor.tool == .eraser {
                    Picker("Eraser", selection: $editor.eraserMode) {
                        ForEach(InkEraserMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Toggle("Highlighter only", isOn: $editor.highlighterOnly).fixedSize()
                    // Off (the default): the eraser rubs out tape as well as ink.
                    Toggle("Protect tape", isOn: Binding(get: { !editor.eraseTape }, set: { editor.eraseTape = !$0 }))
                        .fixedSize()
                        .help("Keep tape when erasing (off: the eraser rubs tape out too)")
                }
                if editor.tool == .laser {
                    Picker("Laser", selection: $editor.laserDot) {
                        Text("Line").tag(false)
                        Text("Dot").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("A glowing line that fades, or just a glowing dot where the pen is")
                }
                if editor.tool == .lasso {
                    Picker("Picks", selection: $editor.lassoKinds) {
                        ForEach(InkLassoKinds.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text(editor.selection == nil ? "Draw a loop around what to select" : "Drag to move, corners to resize, the knob on top to turn")
                        .font(.callout).foregroundStyle(.secondary)
                    if editor.selection != nil {
                        HStack(spacing: 6) {
                            ForEach(InkEditorModel.colors, id: \.self) { c in
                                Button { editor.recolourSelection(c) } label: { Circle().fill(Color(inkHex: c)).frame(width: 20, height: 20).frame(width: 28, height: 32).inkTapArea() }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Recolour \(c)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            // One height for every tool's row (the eraser's segmented picker made it thinner).
            .frame(height: Self.optionsHeight)
        }
        .frame(height: Self.optionsHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The lasso's actions while something is selected, in two compact rows: arranging (turn, flip,
    /// front/back, straighten, group, duplicate), then copy, copy as image, convert to text, Ask AI,
    /// save as element, cut and delete.
    private func selectionBar(_ selection: InkSelection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("\(selection.count)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .accessibilityLabel("\(selection.count) selected")
                InkSelectionArrangeButtons(editor: editor)
                selectionIcon(editor.selectionGroup.isEmpty ? "square.on.square.squareshape.controlhandles" : "square.on.square.dashed",
                              editor.selectionGroup.isEmpty ? "Group" : "Ungroup") { editor.toggleGroup() }
                    .disabled(editor.selectionGroup.isEmpty && selection.count < 2)
                selectionIcon("plus.square.on.square", "Duplicate") { editor.duplicateSelection() }
                selectionIcon("xmark", "Deselect") { editor.clearSelection() }
            }
            HStack(spacing: 4) {
                Button("Copy") { editor.copySelection() }
                Button("Image") { editor.copySelectionAsImage() }.help("Copy as image")
                if !selection.strokes.isEmpty { Button("Text") { editor.convertSelectionToText() }.help("Convert to text") }
                if app.noteAIAvailable {
                    Menu {
                        ForEach(InkAIAction.allCases) { action in
                            Button { editor.askAI(action) } label: { Label(action.label, systemImage: action.symbol) }
                        }
                    } label: {
                        if editor.aiBusy { ProgressView().controlSize(.small) } else { Label("AI", systemImage: "sparkles") }
                    }
                    .fixedSize()
                    .disabled(editor.aiBusy)
                    .help("Ask AI")
                }
                Button("Save") { elementName = ""; elementFolder = ""; savingElement = true }.help("Save as element")
                Button("Cut") { editor.cutSelection() }
                Button(role: .destructive) { editor.deleteSelection() } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .fixedSize()
    }

    private func selectionIcon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 22, minHeight: 22) }
            .help(label)
            .accessibilityLabel(label)
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
                     tool: editor.tool, color: editor.color, width: editor.width, zoomRequest: editor.zoomRequest, dark: editor.darkPage && editor.isSketch,
                     textEdit: editor.textEdit)
            .ignoresSafeArea(edges: .bottom)
        #else
        if let page = editor.currentPage {
            MouseInkCanvas(editor: editor, page: page, pageIndex: editor.page, pagesRevision: editor.pagesRevision, revision: editor.revision,
                           overlayRevision: editor.overlayRevision, tool: editor.tool, color: editor.color, width: editor.width, zoomRequest: editor.zoomRequest,
                           textEdit: editor.textEdit, dark: editor.darkPage && editor.isSketch)
        }
        #endif
    }
}

/// Undo, redo and paste: their own view, since every stroke changes whether they're enabled.
struct InkUndoButtons: View {
    let editor: InkEditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward").frame(minWidth: 34, minHeight: 34).inkTapArea() }
                .disabled(!editor.canUndo).keyboardShortcut("z", modifiers: .command)
            Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward").frame(minWidth: 34, minHeight: 34).inkTapArea() }
                .disabled(!editor.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            if editor.canPaste {
                Button { editor.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard").frame(minWidth: 34, minHeight: 34).inkTapArea() }
                    .keyboardShortcut("v", modifiers: .command)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .frame(height: 34)
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
        // In the real bottom-left corner: past the safe area (the home indicator is in the middle).
        .padding(.leading, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

// MARK: - The page panel

/// A sketch's pages: tap to go to one, drag to reorder, and per page: add after, duplicate, delete,
/// paper and colour.
struct InkPagesPanel: View {
    let editor: InkEditorModel
    @Binding var confirmDelete: String?
    @State private var thumbs: [String: InkImage] = [:]
    /// The pages the thumbnails were made for (`pagesRevision`): then every page is redrawn, else only the one being drawn on.
    @State private var thumbsFor = -1

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
                        .inkTapArea()
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
        .task(id: "\(editor.revision)-\(editor.pagesRevision)") { await renderThumbs(all: editor.pagesRevision != thumbsFor) }
        .inspectorColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private func renderThumbs(all: Bool) async {
        // Wait for a pause in the drawing (a new stroke cancels this and starts again).
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        // Ink changes where you draw: the page in view (and any without a picture yet). Every page only when the pages changed.
        if all { thumbsFor = editor.pagesRevision }
        for page in editor.pages where !page.infinite && (all || page.key == editor.currentKey || thumbs[page.key] == nil) {
            let content = editor.display(page.key)
            if let image = await Task.detached(priority: .utility, operation: { InkRenderer.render(page, content: content, pixelWidth: 160).map(InkImage.init) }).value {
                thumbs[page.key] = image
            }
        }
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

extension View {
    /// The whole frame takes a tap, not just what's drawn in it. Plain buttons only answer where
    /// their label has pixels: a finger's touch is wide enough to land on some, a Pencil tap is a
    /// single point and often fell in a gap ("pressing items with Apple Pencil doesn't register").
    func inkTapArea() -> some View { contentShape(Rectangle()) }
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
    /// What each page's picture was drawn from: only pages whose ink changed are drawn again.
    @State private var drawn: [String: String] = [:]
    /// How wide a page shows (points): pictures are drawn for that at the screen's resolution.
    @State private var shownWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    private var pages: [InkPageSpec] { InkRenderer.sketchPages(item) }
    private var pixelWidth: Int { InkPreviewSize.pixels(shownWidth, scale: displayScale) }

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
                                if let image = images[page.key] { Image(decorative: image.image, scale: displayScale).resizable().scaledToFit() }
                            }
                            .aspectRatio(page.infinite ? 4 / 3 : page.width / page.height, contentMode: .fit)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shownWidth = max(shownWidth, $0) }
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
        .task(id: "\(model.inkRevision)-\(item.record.updatedHLC)-\(model.inkTarget == nil)-\(pixelWidth)") { await render() }
    }

    private func render() async {
        // Behind the open editor nobody sees these: redraw once it closes.
        guard model.inkTarget == nil, let library = model.library else { return }
        let width = pixelWidth
        for page in pages {
            let (content, made) = await Self.page(library, itemId: item.id, layer: "", spec: page)
            let sig = "\(made)@\(width)"
            guard drawn[page.key] != sig || images[page.key] == nil else { continue }
            var area: InkGeometry.Rect?
            if page.infinite {
                let b = await library.inkBounds(on: item.id, pageKey: page.key) ?? InkGeometry.Rect(x: 0, y: 0, width: 800, height: 600)
                area = InkGeometry.Rect(x: b.x - 24, y: b.y - 24, width: max(300, b.width + 48), height: max(225, b.height + 48))
            }
            let box = area
            images[page.key] = await Task.detached(priority: .utility) { InkRenderer.render(page, content: content, pixelWidth: width, area: box).map(InkImage.init) }.value
            drawn[page.key] = sig
        }
    }

    /// A page's ink with its pictures, for previews, and a signature of what it was made from (closing
    /// a sketch used to redraw every page of every preview on screen; ROADMAP §3.7 item 9).
    static func page(_ library: Library, itemId: String, layer: String, spec: InkPageSpec) async -> (InkContent, String) {
        var c = InkContent()
        let strokes = await library.strokes(on: itemId, layer: layer, pageKey: spec.key)
        c.strokes = strokes.map(InkLine.init)
        let elements = await library.elements(on: itemId, layer: layer, pageKey: spec.key)
        c.elements = elements.map(InkBox.init)
        let newestStroke = strokes.map(\.record.updatedHLC).max() ?? ""
        let newestElement = elements.map(\.record.updatedHLC).max() ?? ""
        let sig = "\(strokes.count)-\(newestStroke)-\(elements.count)-\(newestElement)-\(spec)"
        for e in elements {
            if let att = e.image, let data = try? await library.attachmentData(att), let image = InkRenderer.cgImage(data) { c.pictures[att.id] = image }
        }
        return (c, sig)
    }
}

/// How many pixels wide a preview is drawn: as wide as it shows on this screen (sharp, not one
/// size for all), in steps so a small resize doesn't draw it again.
enum InkPreviewSize {
    static func pixels(_ points: CGFloat, scale: CGFloat) -> Int {
        let wanted = max(320, points * max(1, scale))
        let stepped = (wanted / 160).rounded(.up) * 160
        return Int(min(4096, stepped))
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
    @State private var drawn: [String: String] = [:]
    @State private var shownWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    private var pixelWidth: Int { InkPreviewSize.pixels(shownWidth, scale: displayScale) }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(pages.enumerated()), id: \.element.key) { index, page in
                ZStack {
                    Color.white
                    if let image = images[page.key] { Image(decorative: image.image, scale: displayScale).resizable() } else { ProgressView() }
                }
                .aspectRatio(page.width / page.height, contentMode: .fit)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shownWidth = max(shownWidth, $0) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .onTapGesture { model.inkTarget = InkTarget(itemId: item.id, layer: attachment.id, title: attachment.name, startPage: index) }
            }
        }
        .task(id: "\(model.inkRevision)-\(model.inkTarget == nil)-\(pixelWidth)") { await render() }
    }

    private func render() async {
        // Behind the open editor (iPhone, iPad) nobody sees these: redraw once it closes.
        guard model.inkTarget == nil, let library = model.library else { return }
        let data = data, mime = attachment.mime, name = attachment.name
        if pages.isEmpty { pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime, name: name) }.value }
        for page in pages {
            let width = pixelWidth
            let (content, made) = await SketchSection.page(library, itemId: item.id, layer: attachment.id, spec: page)
            let sig = "\(made)@\(width)"
            guard drawn[page.key] != sig || images[page.key] == nil else { continue }
            // The first picture is waited for; redraws after an edit can take their time.
            let priority: TaskPriority = images[page.key] == nil ? .userInitiated : .utility
            images[page.key] = await Task.detached(priority: priority) { InkRenderer.render(page, content: content, pixelWidth: width).map(InkImage.init) }.value
            drawn[page.key] = sig
        }
    }
}

/// Favourite pens: one tap brings back the tool, colour and size (the toolbar and the squeeze palette).
struct InkFavouritesRow: View {
    let editor: InkEditorModel
    var close: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(editor.inkSettings.favourites.enumerated()), id: \.offset) { i, f in
                Button { editor.use(f); close?() } label: {
                    Circle().fill(Color(inkHex: f.color))
                        .frame(width: min(20, max(8, f.width * 1.6 + 4)), height: min(20, max(8, f.width * 1.6 + 4)))
                        .opacity(f.tool == .highlighter ? 0.6 : 1)
                        .frame(width: 28, height: 28)
                        .background(editor.isCurrent(f) ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                        .inkTapArea()
                }
                .buttonStyle(.plain)
                .help("\(InkEditorTool(rawValue: f.tool.rawValue)?.label ?? "Pen"), size \(f.width.formatted())")
                .accessibilityLabel("Favourite \(i + 1): \(InkEditorTool(rawValue: f.tool.rawValue)?.label ?? "Pen"), \(f.color), size \(f.width.formatted())")
            }
        }
    }
}

/// A pen's feel (every device: smoothing, pressure, lightest touch) and lines (this device: dashes,
/// arrows on straight lines, fill for closed shapes), like the website's Pen options.
struct InkPenOptions: View {
    let editor: InkEditorModel

    private var ink: InkTool { editor.tool.ink ?? .pen }

    var body: some View {
        let feel = editor.penSettings(ink)
        Form {
            if editor.tool.ink != nil {
            Section("\(editor.tool.label): on every device") {
                VStack(alignment: .leading) {
                    Text("Smoothing \(feel.smoothing)")
                    Slider(value: Binding(get: { Double(feel.smoothing) }, set: { v in
                        var next = feel
                        next.smoothing = Int(v.rounded())
                        editor.setPenSettings(next, for: ink)
                    }), in: 0...100, step: 1)
                }
                if ink.usesPressure {
                    Picker("Pressure", selection: Binding(get: { feel.curve }, set: { c in
                        var next = feel
                        next.curve = c
                        editor.setPenSettings(next, for: ink)
                    })) {
                        Text("Soft").tag(PenSettings.Curve.soft)
                        Text("Normal").tag(PenSettings.Curve.normal)
                        Text("Firm").tag(PenSettings.Curve.firm)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text("Lightest touch \(feel.minWidth) %")
                        Slider(value: Binding(get: { Double(feel.minWidth) }, set: { v in
                            var next = feel
                            next.minWidth = Int(v.rounded())
                            editor.setPenSettings(next, for: ink)
                        }), in: 0...100, step: 1)
                    }
                }
            }
            }
            Section("Lines (this device)") {
                Picker("Line", selection: Binding(get: { editor.dash(for: editor.tool) ?? "solid" }, set: { editor.setDash($0 == "solid" ? nil : $0, for: editor.tool) })) {
                    Text("Solid").tag("solid")
                    Text("Dashes").tag("dash")
                    Text("Dots").tag("dot")
                }
                .pickerStyle(.segmented)
                Picker("Arrows on straight lines", selection: Binding(get: { editor.arrow ?? "none" }, set: { editor.arrow = $0 == "none" ? nil : $0 })) {
                    Text("None").tag("none")
                    Text("End").tag("end")
                    Text("Both ends").tag("both")
                }
                Picker("Fill closed shapes", selection: Binding(get: { editor.fill ?? "none" }, set: { editor.fill = $0 == "none" ? nil : $0 })) {
                    Text("No fill").tag("none")
                    ForEach(InkEditorModel.colors + ["#ffffff"], id: \.self) { c in Text(c).tag(c) }
                }
            }
        }
        #if os(macOS)
        .padding()
        #endif
    }
}
