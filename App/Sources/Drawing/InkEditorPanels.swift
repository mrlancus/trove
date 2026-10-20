import SwiftUI
import TroveCore

/// The editor's Page panel: paper (with pictures of each), page colour, size and orientation, for
/// this page or every page; pages or an endless canvas; and how pages show (like the website's).
struct InkPageSettings: View {
    let editor: InkEditorModel
    @State private var everyPage = true

    var body: some View {
        @Bindable var editor = editor
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if editor.isSketch {
                    if !editor.isInfinite {
                        Picker("Change", selection: $everyPage) {
                            Text("Every page").tag(true)
                            Text("This page").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    heading("Paper")
                    ForEach(InkPaper.groups, id: \.title) { group in
                        Text(group.title).font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(group.papers, id: \.self) { paper in
                                    Button { apply(paper: paper) } label: {
                                        VStack(spacing: 4) {
                                            PaperThumb(paper: paper, color: editor.pageColor)
                                                .frame(width: 48, height: 64)
                                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(editor.paper == paper ? Color.accentColor : .gray.opacity(0.3),
                                                                                                       lineWidth: editor.paper == paper ? 2 : 1))
                                            Text(paper.title).font(.caption2).multilineTextAlignment(.center).lineLimit(2)
                                                .foregroundStyle(editor.paper == paper ? Color.accentColor : .secondary)
                                        }
                                        .frame(width: 66)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(paper.title)
                                    .accessibilityAddTraits(editor.paper == paper ? .isSelected : [])
                                }
                            }
                        }
                    }
                    heading("Page colour")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(InkPage.colors, id: \.self) { c in
                            let on = (editor.pageColor ?? "#ffffff") == c
                            Button { apply(color: c == "#ffffff" ? "" : c) } label: {
                                Circle().fill(Color(inkHex: c)).frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(on ? Color.accentColor : .gray.opacity(0.4), lineWidth: on ? 2.5 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(InkPage.colorTitles[c] ?? c)
                        }
                    }
                    if !editor.isInfinite, let page = editor.currentPage {
                        heading("Size")
                        let named = InkPageSize.named(page.width, page.height)
                        let landscape = named?.landscape ?? (page.width > page.height)
                        Picker("Size", selection: Binding(get: { named?.size }, set: { if let s = $0 { apply(size: s.dimensions(landscape: s == .wide ? true : landscape)) } })) {
                            ForEach(InkPageSize.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                            if named == nil { Text("Custom").tag(InkPageSize?.none) }
                        }
                        Picker("Orientation", selection: Binding(get: { landscape }, set: { l in
                            let a = min(page.width, page.height), b = max(page.width, page.height)
                            apply(size: l ? [b, a] : [a, b])
                        })) {
                            Text("Portrait").tag(false)
                            Text("Landscape").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    heading("Canvas")
                    Picker("Canvas", selection: Binding(get: { editor.isInfinite }, set: { editor.setInfinite($0) })) {
                        Text("Pages").tag(false)
                        Text("Endless canvas").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                #if os(iOS)
                if !editor.isInfinite {
                    heading("Pages show")
                    Picker("Pages show", selection: $editor.layout) {
                        ForEach(InkPageLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                #endif
                if editor.isSketch && !editor.isInfinite {
                    HStack {
                        Button { editor.addPage(after: editor.currentKey) } label: { Label("Page after this", systemImage: "plus") }
                        Button { editor.duplicatePage(editor.currentKey) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func apply(paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) {
        if everyPage || editor.isInfinite { editor.setAllPages(paper: paper, color: color, size: size) } else { editor.setPage(editor.currentKey, paper: paper, color: color, size: size) }
    }
}

/// A small picture of a paper, drawn the same way as the pages.
struct PaperThumb: View {
    let paper: InkPaper
    let color: String?

    var body: some View {
        Canvas { context, size in
            context.withCGContext { ctx in
                ctx.scaleBy(x: size.width / 300, y: size.height / 400)
                InkRenderer.drawPaper(paper, size: CGSize(width: 300, height: 400), color: color, in: ctx)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
    }
}

/// The palette squeezing Apple Pencil opens at its tip (like GoodNotes and Notes): tools, colours,
/// size, undo and redo.
struct InkPalette: View {
    let editor: InkEditorModel
    private static let tools: [InkEditorTool] = [.pen, .pencil, .fountain, .brush, .marker, .highlighter, .eraser, .lasso, .laser, .text]

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 5), spacing: 4) {
                ForEach(Self.tools) { t in
                    Button { editor.select(t) } label: {
                        Image(systemName: t.symbol).font(.title3).frame(width: 40, height: 38)
                            .foregroundStyle(editor.tool == t ? Color.accentColor : Color.primary)
                            .background(editor.tool == t ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.label)
                }
            }
            if editor.tool.hasColor {
                HStack(spacing: 6) {
                    ForEach(InkEditorModel.colors, id: \.self) { c in
                        Button { editor.color = c } label: {
                            Circle().fill(Color(inkHex: c)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(editor.color == c ? Color.accentColor : .gray.opacity(0.4), lineWidth: editor.color == c ? 2 : 1).padding(-2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(c)")
                    }
                }
            }
            if editor.tool.hasSize {
                HStack {
                    Image(systemName: "circle.fill").font(.system(size: 5))
                    Slider(value: $editor.width, in: editor.tool == .eraser && editor.eraserMode == .precise ? 0.5...12 : 1...(editor.tool == .text ? 72 : 60))
                    Image(systemName: "circle.fill").font(.system(size: 14))
                }
            }
            if editor.tool == .eraser {
                Picker("Eraser", selection: $editor.eraserMode) { ForEach(InkEraserMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
            }
            HStack {
                Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!editor.canUndo)
                Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!editor.canRedo)
                Spacer()
                Button { editor.palette = nil } label: { Label("Close", systemImage: "xmark") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
    }
}
