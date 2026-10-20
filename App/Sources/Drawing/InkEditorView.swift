import SwiftUI
import TroveCore

/// The drawing editor: a sketch's pages, or a PDF or image to write on. Pen, pencil, marker,
/// highlighter and eraser; colours and sizes; undo and redo; paper and pages for sketches. The same
/// tools as the website's (web/public/draw.js).
struct InkEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editor: InkEditorModel
    @State private var showColors = false

    init(target: InkTarget, app: AppModel) {
        _editor = State(initialValue: InkEditorModel(target: target, app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color.gray.opacity(0.18).ignoresSafeArea()
                if let page = editor.currentPage, editor.loaded {
                    canvas(page)
                } else if let failed = editor.failed {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Can't draw here", message: failed)
                } else {
                    ProgressView("Opening…")
                }
            }
            if editor.pages.count > 1 || editor.isSketch { pageBar }
        }
        .task { await editor.load() }
        .task(id: app.inkRevision) { if editor.loaded { await editor.reloadStrokes() } }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 700)
        #endif
    }

    @ViewBuilder private func canvas(_ page: InkPageSpec) -> some View {
        #if os(iOS)
        PencilCanvas(editor: editor, page: page, pageIndex: editor.page, strokes: editor.currentStrokes,
                     tool: editor.tool, color: editor.color, width: editor.width)
            .ignoresSafeArea(edges: .bottom)
        #else
        MouseInkCanvas(editor: editor, page: page, pageIndex: editor.page, strokes: editor.currentStrokes,
                       tool: editor.tool, color: editor.color, width: editor.width)
        #endif
    }

    // MARK: Toolbar

    private var toolbar: some View {
        @Bindable var editor = editor
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(InkEditorTool.allCases) { t in
                        Button { editor.select(t) } label: {
                            Image(systemName: t.symbol)
                                .font(.title3)
                                .frame(width: 40, height: 36)
                                .foregroundStyle(editor.tool == t ? Color.accentColor : Color.primary)
                                .background(editor.tool == t ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .help(t.label)
                        .accessibilityLabel(t.label)
                        .accessibilityAddTraits(editor.tool == t ? .isSelected : [])
                    }
                }
                HStack(spacing: 6) {
                    ForEach(InkEditorModel.colors, id: \.self) { c in
                        Button { editor.color = c } label: {
                            Circle().fill(Color(inkHex: c)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .overlay(Circle().strokeBorder(editor.tool != .eraser && editor.color == c ? Color.accentColor : .gray.opacity(0.4), lineWidth: editor.color == c ? 2 : 1).padding(-2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(c)")
                    }
                    ColorPicker("Any colour", selection: Binding(get: { Color(inkHex: editor.color) }, set: { editor.color = $0.inkHex }), supportsOpacity: false)
                        .labelsHidden()
                }
                .disabled(editor.tool == .eraser)
                .opacity(editor.tool == .eraser ? 0.4 : 1)
                HStack(spacing: 6) {
                    Circle().fill(Color(inkHex: editor.color).opacity(editor.tool == .highlighter ? 0.5 : 1))
                        .frame(width: min(22, max(4, editor.width)), height: min(22, max(4, editor.width)))
                        .frame(width: 24)
                    Slider(value: $editor.width, in: 1...40).frame(width: 110)
                        .disabled(editor.tool == .eraser)
                }
                HStack(spacing: 4) {
                    Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!editor.canUndo).keyboardShortcut("z", modifiers: .command)
                    Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!editor.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                if editor.isSketch {
                    Menu {
                        Picker("Paper", selection: Binding(get: { editor.paper }, set: { editor.setPaper($0) })) {
                            Text("Blank").tag(InkPaper.blank)
                            Text("Lined").tag(InkPaper.lined)
                            Text("Squared").tag(InkPaper.grid)
                            Text("Dotted").tag(InkPaper.dotted)
                        }
                    } label: { Label("Paper", systemImage: "doc.plaintext") }
                    .fixedSize()
                }
                Text(editor.target.title).font(.headline).lineLimit(1).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            }
            Button("Done") { Task { await editor.finish() }; dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 12)
        }
        .background(.bar)
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
                Button { editor.addPage() } label: { Label("Page", systemImage: "plus") }.buttonStyle(.bordered)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
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

/// A sketch's pages in its item view: tap one to draw on it.
struct SketchSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var images: [Int: InkImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(item.sketchPages) page\(item.sketchPages == 1 ? "" : "s")", systemImage: "scribble.variable").font(.headline)
                Spacer()
                Button { model.draw(on: item) } label: { Label("Draw", systemImage: "pencil.tip") }
                    .buttonStyle(.borderedProminent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(0..<item.sketchPages, id: \.self) { page in
                    Button { model.draw(on: item, page: page) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Color.white
                                if let image = images[page] { Image(decorative: image.image, scale: 2).resizable() }
                            }
                            .aspectRatio(item.sketchPageSize.width / item.sketchPageSize.height, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            if item.sketchPages > 1 { Text("\(page + 1)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
        .task(id: "\(model.inkRevision)-\(item.paper.rawValue)-\(item.sketchPages)") { await render() }
    }

    private func render() async {
        guard let library = model.library else { return }
        let size = item.sketchPageSize, paper = item.paper
        for page in 0..<item.sketchPages {
            let strokes = await library.strokes(on: item.id, page: page)
            let spec = InkPageSpec(width: size.width, height: size.height, background: .paper(paper))
            images[page] = await Task.detached(priority: .utility) { InkRenderer.render(spec, strokes: strokes, pixelWidth: 360).map(InkImage.init) }.value
        }
    }
}

/// A PDF or image with ink on it, page by page.
struct InkedFileView: View {
    let item: Item
    let attachment: Attachment
    let data: Data
    @Environment(AppModel.self) private var model
    @State private var pages: [InkPageSpec] = []
    @State private var images: [Int: InkImage] = [:]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                ZStack {
                    Color.white
                    if let image = images[index] { Image(decorative: image.image, scale: 2).resizable() } else { ProgressView() }
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
        let data = data, mime = attachment.mime
        if pages.isEmpty { pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime) }.value }
        let all = await library.strokes(on: item.id, layer: attachment.id)
        for (index, page) in pages.enumerated() {
            let strokes = all.filter { $0.page == index }
            let width = Int(min(2400, page.width * 2))
            images[index] = await Task.detached(priority: .userInitiated) { InkRenderer.render(page, strokes: strokes, pixelWidth: width).map(InkImage.init) }.value
        }
    }
}
