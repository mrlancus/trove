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
    @State private var goodNotesFile: GoodNotesFile?
    @State private var confirmDeletePage: String?
    @State private var pageSettings = false
    /// Ask this notebook (StudyPanel, MASTER_PLAN G14).
    @State private var asking = false
    @State private var penOptions = false
    /// The chosen tool's tray (tap the tool again).
    @State private var trayOpen = false
    @State private var choosingPhoto = false
    @State private var elementsOpen = false
    @State private var savingElement = false
    @State private var elementName = ""
    @State private var elementFolder = ""

    /// Inside the file viewer's Edit: the viewer has the Done button, and leaving saves.
    let embedded: Bool

    init(target: InkTarget, app: AppModel, embedded: Bool = false) {
        _editor = State(initialValue: InkEditorModel(target: target, app: app))
        self.embedded = embedded
    }

    // The canvas, zoom pill and undo buttons are their own views, each watching only what it shows:
    // a stroke then redraws the canvas, not the whole editor with its toolbar.
    var body: some View { perfBody.perfWorkflow("Notebook") }

    @ViewBuilder private var perfBody: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            if !editor.presenting {
                toolbar
                Divider()
            }
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
                if editor.loaded, !editor.presenting { InkZoomCorner(editor: editor) }
                if editor.presenting {
                    Button { editor.presenting = false } label: { Label("End presentation", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).font(.title) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(16)
                        .keyboardShortcut(.cancelAction)
                }
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
            .clipped()
            if showsPageBar, !editor.presenting { pageBar }
        }
        .task { await editor.load() }
        .task(id: app.inkPulledRevision) { if editor.loaded { await editor.reloadInk() } }
        .onAppear { app.drawingOpen += 1 }
        .onDisappear { app.drawingOpen = max(0, app.drawingOpen - 1) }
        // One side panel: the pages, or Ask this notebook.
        .inspector(isPresented: Binding(get: { editor.showPages || asking }, set: { if !$0 { editor.showPages = false; asking = false } })) {
            if asking {
                StudyPanel(editor: editor)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            } else {
                InkPagesPanel(editor: editor, confirmDelete: $confirmDeletePage)
            }
        }
        .onChange(of: asking) { _, on in if on { editor.showPages = false } }
        .onChange(of: editor.showPages) { _, on in if on { asking = false } }
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
        #if os(iOS)
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        #endif
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
        .onChange(of: editor.exportedGoodNotes) { _, data in
            if let data { goodNotesFile = GoodNotesFile(data: data); editor.exportedGoodNotes = nil }
        }
        .fileExporter(isPresented: Binding(get: { goodNotesFile != nil }, set: { if !$0 { goodNotesFile = nil } }), document: goodNotesFile,
                      contentType: GoodNotesFile.type, defaultFilename: editor.target.title) { _ in
            goodNotesFile = nil
            if let notes = editor.goodNotesReport?.notes, !notes.isEmpty { app.toast = notes.joined(separator: "; ") }
        }
        .confirmationDialog("Delete this page and everything on it?", isPresented: Binding(get: { confirmDeletePage != nil }, set: { if !$0 { confirmDeletePage = nil } })) {
            Button("Delete page", role: .destructive) { if let key = confirmDeletePage { editor.deletePage(key) }; confirmDeletePage = nil }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear { Task { await editor.finish() } } // closing the window counts as Done
        #else
        .onDisappear { if embedded { Task { await editor.finish() } } } // the viewer's Done
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

    // MARK: Toolbar: one slim bar (docs/plans/sketch-2-plan.md T1)
    //
    // Done and the title on the left; one Pens button (the six pen types are in its tray), the
    // highlighter, eraser, lasso, shapes and text; Insert; the chosen tool's colours and sizes
    // inline; undo, redo, Ask and More on the right. Nothing scrolls: when the bar is narrow, the
    // inline sizes go first, then the colours, then Insert, shapes and text move into More
    // (`ViewThatFits`, in the order `ToolbarFold.order` documents). Tap the chosen tool again for
    // its tray: every colour, size and mode.

    static let penKinds: [InkEditorTool] = [.pen, .ballpoint, .pencil, .fountain, .brush, .marker]

    /// The pen the Pens button brings back.
    private var lastPen: InkEditorTool {
        if Self.penKinds.contains(editor.tool) { return editor.tool }
        return InkEditorTool(rawValue: UserDefaults.standard.string(forKey: "ink.lastPen") ?? "") ?? .pen
    }

    private func tap(_ t: InkEditorTool) {
        if editor.tool == t {
            trayOpen.toggle()
        } else {
            editor.select(t)
            if Self.penKinds.contains(t) { UserDefaults.standard.set(t.rawValue, forKey: "ink.lastPen") }
        }
    }

    private func toolIcon(_ t: InkEditorTool, on: Bool, symbol: String? = nil, label: String? = nil) -> some View {
        Button { tap(t) } label: {
            Image(systemName: symbol ?? t.symbol)
                .font(.title3)
                .frame(width: 38, height: 34)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(on ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottom) {
                    if t.ink != nil { Capsule().fill(Color(inkHex: editor.color(for: t))).frame(width: 14, height: 3).offset(y: 1) }
                }
                .inkTapArea()
        }
        .buttonStyle(.plain)
        .help(label ?? t.label)
        .accessibilityLabel(label ?? t.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Pens, highlighter, eraser, lasso (never fold), then shapes and text unless folded.
    private func tools(shapesAndText: Bool) -> some View {
        HStack(spacing: 2) {
            let pen = lastPen
            toolIcon(pen, on: Self.penKinds.contains(editor.tool), label: "Pens (\(pen.label))")
            toolIcon(.highlighter, on: editor.tool == .highlighter)
            toolIcon(.eraser, on: editor.tool == .eraser)
            toolIcon(.lasso, on: editor.tool == .lasso)
            if shapesAndText {
                toolIcon(.shape, on: editor.tool == .shape)
                toolIcon(.text, on: editor.tool == .text)
            }
        }
        // Tap the chosen tool again: its tray, under the tools.
        .popover(isPresented: $trayOpen) {
            ScrollView { trayContent.padding(16) }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 440, minHeight: 200, idealHeight: 360)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var insertMenu: some View {
        Menu {
            insertItems
        } label: {
            Image(systemName: "plus.circle").font(.title3).frame(width: 34, height: 34).inkTapArea()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert: pictures, elements, tape, ruler, protractor, laser")
        .accessibilityLabel("Insert")
        .popover(isPresented: $elementsOpen) { InkElementsLibrary(editor: editor) { elementsOpen = false }.frame(minWidth: 320, idealWidth: 380, minHeight: 360) }
    }

    @ViewBuilder private var insertItems: some View {
        #if os(iOS)
        Button { choosingPhoto = true } label: { Label("Picture from Photos", systemImage: "photo") }
        #endif
        Button { importingPicture = true } label: { Label("Picture from Files…", systemImage: "folder") }
        Button { elementsOpen = true } label: { Label("Elements…", systemImage: "square.grid.2x2") }
        Divider()
        Button { editor.select(.tape) } label: { Label("Tape", systemImage: InkEditorTool.tape.symbol) }
        Button { editor.select(.laser) } label: { Label("Laser pointer", systemImage: InkEditorTool.laser.symbol) }
        Toggle(isOn: Binding(get: { editor.ruler != nil }, set: { _ in editor.toggleGuide(.ruler) })) { Label("Ruler", systemImage: "ruler") }
        Toggle(isOn: Binding(get: { editor.protractor != nil }, set: { _ in editor.toggleGuide(.protractor) })) { Label("Protractor", systemImage: "angle") }
    }

    /// The chosen tool's colours and sizes in the bar (`sizes` false: colours only).
    private func inlineOptions(sizes: Bool) -> some View {
        HStack(spacing: 10) {
            if editor.tool.hasColor { InkColorPresets(editor: editor) }
            if sizes, editor.tool.hasSize { InkSizePresets(editor: editor) }
            if !editor.inkSettings.favourites.isEmpty {
                Menu {
                    ForEach(Array(editor.inkSettings.favourites.enumerated()), id: \.offset) { i, f in
                        Button("\(InkEditorTool(rawValue: f.tool.rawValue)?.label ?? "Pen"), size \(f.width.formatted())") { editor.use(f) }
                    }
                } label: { Image(systemName: "star").font(.title3).frame(width: 30, height: 34).inkTapArea() }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Favourite pens")
                .accessibilityLabel("Favourite pens")
            }
        }
    }

    /// The middle of the bar at a level of folding: 0 shows everything, 3 the least.
    private func middle(_ level: Int) -> some View {
        HStack(spacing: 8) {
            tools(shapesAndText: level < 3)
            if level < 3 { insertMenu }
            if level < 2 {
                Divider().frame(height: 26)
                inlineOptions(sizes: level < 1)
            }
            Spacer(minLength: 0)
        }
    }

    private var toolbar: some View {
        @Bindable var editor = editor
        return HStack(spacing: 6) {
            if !embedded {
                Button { Task { await editor.finish() }; dismiss() } label: {
                    Label("Done", systemImage: "chevron.backward").labelStyle(.iconOnly).font(.title3.weight(.semibold)).frame(width: 34, height: 34).inkTapArea()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Done")
            }
            titleMenu
            Divider().frame(height: 26)
            ViewThatFits(in: .horizontal) {
                middle(0)
                middle(1)
                middle(2)
                middle(3)
            }
            HStack(spacing: 4) {
                InkUndoButtons(editor: editor)
                if editor.isSketch { InkAudioButtons(editor: editor, audio: editor.audio) }
                Button { asking.toggle() } label: { Label("Ask", systemImage: "sparkles").labelStyle(.titleAndIcon).font(.callout.weight(.semibold)) }
                    .buttonStyle(.bordered)
                    .help("Ask about this notebook, check facts, or revise (⌘K)")
                moreMenu
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        // Keys (the Mac and iPad keyboards): the lasso's, and ⌘K for Ask. (Single-letter tool keys
        // would fire while typing in a text box or the Ask box, so there are none.)
        .background {
            Group {
                Button("Select all") { editor.selectAll() }.keyboardShortcut("a", modifiers: .command)
                Button("Copy") { editor.copySelection() }.keyboardShortcut("c", modifiers: .command).disabled(editor.selection == nil)
                Button("Cut") { editor.cutSelection() }.keyboardShortcut("x", modifiers: .command).disabled(editor.selection == nil)
                Button("Duplicate") { editor.duplicateSelection() }.keyboardShortcut("d", modifiers: .command).disabled(editor.selection == nil)
                Button("Ask") { asking.toggle() }.keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    /// The title, with the page's things: page settings, pages, dark page, present, export.
    private var titleMenu: some View {
        Menu {
            Button { pageSettings = true } label: { Label(editor.isSketch ? "Page settings…" : "View…", systemImage: "doc.richtext") }
            if editor.isSketch && !editor.isInfinite {
                Button { editor.showPages.toggle() } label: { Label("Pages", systemImage: "rectangle.stack") }
            }
            if editor.isSketch {
                Button { editor.darkPage.toggle() } label: { Label(editor.darkPage ? "Light page" : "Dark page", systemImage: editor.darkPage ? "sun.max" : "moon") }
            }
            Button { editor.presenting = true } label: { Label("Present", systemImage: "play.rectangle") }
            Menu {
                Button("PDF") { editor.exportPDF() }
                Button("GoodNotes notebook (.goodnotes)") { editor.exportGoodNotes() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(editor.exporting)
        } label: {
            HStack(spacing: 4) {
                Text(editor.target.title.isEmpty ? "Sketch" : editor.target.title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $pageSettings) { InkPageSettings(editor: editor).frame(minWidth: 320, idealWidth: 360, minHeight: 420) }
    }

    /// Everything else, including what a narrow bar folded away.
    private var moreMenu: some View {
        @Bindable var editor = editor
        return Menu {
            Section("Tools") {
                Button { tap(.shape) } label: { Label("Shapes", systemImage: InkEditorTool.shape.symbol) }
                Button { tap(.text) } label: { Label("Text", systemImage: InkEditorTool.text.symbol) }
                Menu { insertItems } label: { Label("Insert", systemImage: "plus.circle") }
                Button { trayOpen = true } label: { Label("\(editor.tool.label) options…", systemImage: "slider.horizontal.3") }
            }
            Section("Settings") {
                Toggle("Scribble to erase", isOn: $editor.scribbleToErase)
                Toggle("Shapes come out clean", isOn: $editor.shapeMode)
                Picker("Math Assist", selection: Binding(get: { MathAssistController.setting }, set: { MathAssistController.setting = $0 })) {
                    Text("Answer when I write =").tag(MathAssist.Mode.automatic)
                    Text("Only when I ask (lasso → Solve)").tag(MathAssist.Mode.onRequest)
                    Text("Off").tag(MathAssist.Mode.off)
                }
                Toggle("Smaller drawings (every device up to date)", isOn: Binding(get: { editor.inkSettings.compactPoints }, set: { editor.setCompactPoints($0) }))
                #if os(iOS)
                // Trove's GPU ink is sharp at every zoom; PencilKit's ink is the fallback (reopen to apply).
                Toggle("Classic ink (PencilKit)", isOn: Binding(get: { !InkMetalView.enabled }, set: { InkMetalView.enabled = !$0 }))
                #endif
                Picker("When a drawing opens", selection: $editor.fitWholePage) {
                    Text("Show the whole page").tag(true)
                    Text("Fit the page width").tag(false)
                }
                if !editor.inkSettings.favourites.isEmpty {
                    Menu("Remove a favourite pen") {
                        ForEach(Array(editor.inkSettings.favourites.enumerated()), id: \.offset) { i, f in
                            Button("\(i + 1): \(InkEditorTool(rawValue: f.tool.rawValue)?.label ?? "Pen"), \(f.color), size \(f.width.formatted())") { editor.removeFavourite(f) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 34, height: 34).inkTapArea()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

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

    /// The chosen tool's tray: every colour, size and mode (what the second row used to hold).
    @ViewBuilder private var trayContent: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.tool.label).font(.headline)
            if Self.penKinds.contains(editor.tool) {
                Picker("Pen", selection: Binding(get: { editor.tool }, set: { tap($0) })) {
                    ForEach(Self.penKinds) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if editor.tool.hasColor { InkColorPresets(editor: editor) }
            if editor.tool == .shape { shapeKinds }
            if editor.tool == .text || editor.textEdit != nil || editor.selectionHasText { InkTextStyleBar(editor: editor) }
            if editor.tool.hasSize {
                HStack(spacing: 10) {
                    InkSizePresets(editor: editor)
                    Slider(value: $editor.width, in: editor.sizeRange(editor.tool))
                    Text(InkSizeUnit.label(editor.width, tool: editor.tool))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                }
            }
            if editor.tool.ink != nil || editor.tool == .shape {
                HStack {
                    Button(editor.tool == .shape ? "Line options…" : "Pen options…") { penOptions = true }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $penOptions) {
                            InkPenOptions(editor: editor)
                                .frame(minWidth: 340, idealWidth: 380, maxWidth: 420, minHeight: editor.tool.ink != nil ? 440 : 260, idealHeight: editor.tool.ink != nil ? 480 : 280)
                                .presentationCompactAdaptation(.popover)
                        }
                    if editor.tool != .shape {
                        Button("Save as favourite") { editor.saveFavourite() }
                            .buttonStyle(.bordered)
                            .help("Keep this pen, colour and size as a favourite (on every device)")
                    }
                }
                if !editor.inkSettings.favourites.isEmpty { InkFavouritesRow(editor: editor) }
            }
            if editor.tool == .eraser {
                Picker("Eraser", selection: $editor.eraserMode) {
                    ForEach(InkEraserMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Highlighter only", isOn: $editor.highlighterOnly)
                // Off (the default): the eraser rubs out tape as well as ink.
                Toggle("Protect tape", isOn: Binding(get: { !editor.eraseTape }, set: { editor.eraseTape = !$0 }))
            }
            if editor.tool == .laser {
                Picker("Laser", selection: $editor.laserDot) {
                    Text("Line").tag(false)
                    Text("Dot").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if editor.tool == .lasso {
                Picker("Picks", selection: $editor.lassoKinds) {
                    ForEach(InkLassoKinds.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
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

/// Bottom left: the zoom and which page this is. The zoom shows relative to your own 100 % (set it
/// from here; reset puts back the original, a page point to a screen point). Its own view, since the
/// zoom changes during a pinch. Inside the safe area, so a rounded screen corner, the home
/// indicator or Stage Manager's grip never covers it (docs/plans/sketch-2-plan.md T4, T5).
struct InkZoomCorner: View {
    let editor: InkEditorModel

    var body: some View {
        let base = editor.zoomBase
        HStack(spacing: 6) {
            Menu {
                Button("Go to 100%") { editor.requestZoom(.scale(base.base)) }
                Button("Make this zoom my 100%") { editor.zoomBase = ZoomBase(base: editor.zoom) }
                    .disabled(abs(editor.zoom - base.base) < 0.001)
                Button("Reset 100% to the original") { editor.zoomBase = ZoomBase() }
                    .disabled(base.isOriginal)
                if !editor.isInfinite {
                    Divider()
                    Button("Whole page") { editor.requestZoom(.wholePage) }
                    Button("Page width") { editor.requestZoom(.pageWidth) }
                }
                Divider()
                ForEach(ZoomBase.presets.filter { $0 != 100 }, id: \.self) { p in Button("\(Int(p))%") { editor.requestZoom(.scale(base.zoom(forPercent: p))) } }
                Divider()
                Button { editor.requestZoom(.scale(editor.zoom * 1.25)) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                    .keyboardShortcut("+", modifiers: .command)
                Button { editor.requestZoom(.scale(editor.zoom / 1.25)) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
            } label: {
                Text(base.label(editor.zoom))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(minWidth: 58, minHeight: 32)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.gray.opacity(0.25)))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Zoom \(base.percent(editor.zoom)) percent")
            if editor.pages.count > 1, !editor.isInfinite {
                Text("\(editor.page + 1) / \(editor.pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.leading, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // ⌘0: your 100 %.
        .background { Button("Go to 100%") { editor.requestZoom(.scale(base.base)) }.keyboardShortcut("0", modifiers: .command).opacity(0).allowsHitTesting(false) }
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

    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        List {
            if !editor.pageNames.isEmpty {
                Section("Outline") {
                    ForEach(Array(editor.pages.enumerated()).filter { editor.pageNames[$0.element.key] != nil }, id: \.element.key) { index, page in
                        Button { editor.page = index } label: {
                            Label(editor.pageNames[page.key] ?? "", systemImage: index == editor.page ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1)").font(.callout.monospacedDigit())
                                if let name = editor.pageNames[page.key] { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                        }
                        .inkTapArea()
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if editor.isSketch {
                            Button { renaming = page.key; newName = editor.pageNames[page.key] ?? "" } label: { Label(editor.pageNames[page.key] == nil ? "Name this page…" : "Rename page…", systemImage: "bookmark") }
                        }
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
            if let page = editor.currentPage {
                Section {
                    // Like GoodNotes' add space: everything below the middle of the screen moves.
                    Button { editor.insertSpace(at: editor.visibleCenter.y, by: 120, pageKey: page.key) } label: { Label("Add space here", systemImage: "arrow.down.to.line") }
                    Button { editor.insertSpace(at: editor.visibleCenter.y, by: -120, pageKey: page.key) } label: { Label("Remove space here", systemImage: "arrow.up.to.line") }
                } footer: {
                    Text("Pushes everything below the middle of the screen down (or pulls it up). Undo puts it back.")
                }
            }
        }
        .alert("Name this page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("e.g. Week 3: Enzymes", text: $newName)
            Button("Save") { if let key = renaming { editor.renamePage(key, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Named pages show in the outline at the top of this panel.")
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

/// An exported GoodNotes notebook, for the save panel.
struct GoodNotesFile: FileDocument {
    static let type = UTType(filenameExtension: "goodnotes", conformingTo: .data) ?? .data
    static var readableContentTypes: [UTType] { [type] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
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
                .onTapGesture { model.openFile(item, attachment, page: index) }
            }
        }
        .task(id: "\(model.inkRevision)-\(model.fileViewer == nil)-\(pixelWidth)") { await render() }
    }

    private func render() async {
        // Behind the open viewer (iPhone, iPad) nobody sees these: redraw once it closes.
        guard model.fileViewer == nil, let library = model.library else { return }
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


/// Record while writing, and the sketch's recordings to play back (MASTER_PLAN G4).
struct InkAudioButtons: View {
    let editor: InkEditorModel
    @Bindable var audio: InkAudioController

    var body: some View {
        Button {
            Task { if audio.isRecording { await audio.stopRecording() } else { await audio.startRecording() } }
        } label: {
            Label(audio.isRecording ? "Stop recording" : "Record", systemImage: audio.isRecording ? "stop.circle.fill" : "mic")
        }
        .foregroundStyle(audio.isRecording ? .red : .primary)
        .help(audio.isRecording ? "Stop recording" : "Record audio while you write; play it back with the writing marked")
        if !editor.recordings.isEmpty {
            Menu {
                if audio.playing != nil { Button("Stop playing") { audio.stop() } }
                ForEach(editor.recordings) { rec in
                    Button("\(Date(timeIntervalSince1970: rec.start / 1000).formatted(date: .abbreviated, time: .shortened)) · \(Int(rec.duration / 60)) min \(Int(rec.duration) % 60) s") {
                        Task { await audio.play(rec) }
                    }
                }
            } label: { Label("Recordings", systemImage: audio.playing == nil ? "waveform" : "waveform.circle.fill") }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
