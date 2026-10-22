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
                                        .inkTapArea()
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
                                    .inkTapArea()
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
/// sizes, undo and redo.
struct InkPalette: View {
    let editor: InkEditorModel
    static let width: CGFloat = 316
    static let height: CGFloat = 206
    /// Where the arcs are centred, in the palette: on the Pencil's tip (InkEditorView places it so).
    static let centre = CGPoint(x: width / 2, y: 178)
    private static let tools: [InkEditorTool] = [.pen, .ballpoint, .pencil, .fountain, .brush, .marker, .highlighter, .eraser, .lasso, .shape, .text, .laser, .tape]

    /// Curved round the Pencil's tip, like Apple's own: every tool on the outer arc and your colours
    /// on the inner one (drag along either to turn it), undo, sizes and redo in the middle. Picking
    /// leaves it open; squeezing again or tapping anywhere else closes it.
    var body: some View {
        ZStack {
            InkArcDial(items: Self.tools, centre: Self.centre, radius: 124, band: 50, from: 172, to: 8, step: 27, selected: editor.tool) { t in
                toolButton(t)
            }
            if editor.tool.hasColor {
                // Smaller than the tools' arc and clear of the undo row underneath.
                InkArcDial(items: editor.presetColors(for: editor.tool), centre: Self.centre, radius: 80, band: 28, from: 144, to: 36, step: 21,
                           selected: editor.color) { c in
                    colourButton(c)
                }
                .id(InkEditorModel.colorGroup(editor.tool))
            }
            HStack(spacing: 4) {
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.body.weight(.medium)).frame(width: 30, height: 30).inkTapArea() }
                    .buttonStyle(.plain).disabled(!editor.canUndo).accessibilityLabel("Undo")
                if editor.tool.hasSize { InkSizePresets(editor: editor) }
                Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward").font(.body.weight(.medium)).frame(width: 30, height: 30).inkTapArea() }
                    .buttonStyle(.plain).disabled(!editor.canRedo).accessibilityLabel("Redo")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .position(x: Self.centre.x, y: Self.centre.y)
        }
        .frame(width: Self.width, height: Self.height)
    }

    private func toolButton(_ t: InkEditorTool) -> some View {
        Button { editor.select(t) } label: {
            Image(systemName: t.symbol).font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(editor.tool == t ? Color.white : Color.primary)
                .background(editor.tool == t ? Color.accentColor : .clear, in: Circle())
                .overlay(alignment: .bottom) {
                    if t.ink != nil, editor.tool != t { Capsule().fill(Color(inkHex: editor.color(for: t))).frame(width: 12, height: 3).offset(y: -3) }
                }
                .inkTapArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.label)
    }

    private func colourButton(_ c: String) -> some View {
        Button { editor.color = c } label: {
            Circle().fill(Color(inkHex: c)).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .overlay(Circle().strokeBorder(editor.color == c ? Color.accentColor : .gray.opacity(0.35), lineWidth: editor.color == c ? 2.5 : 1).padding(-2.5))
                .frame(width: 26, height: 26)
                .inkTapArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(c)")
    }
}
