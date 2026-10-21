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
    static let width: CGFloat = 228
    private static let tools: [InkEditorTool] = [.pen, .pencil, .highlighter, .eraser, .lasso]

    /// Small and quick, like Apple Pencil's own palette: a row of tools, a row of colours and sizes.
    /// Picking a tool or colour closes it.
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Self.tools) { t in
                    Button { editor.select(t); editor.palette = nil } label: {
                        Image(systemName: t.symbol).font(.body).frame(width: 34, height: 32)
                            .foregroundStyle(editor.tool == t ? Color.accentColor : Color.primary)
                            .background(editor.tool == t ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.label)
                }
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.body).frame(width: 34, height: 32) }
                    .buttonStyle(.plain)
                    .disabled(!editor.canUndo)
                    .accessibilityLabel("Undo")
            }
            if !editor.inkSettings.favourites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    InkFavouritesRow(editor: editor) { editor.palette = nil }
                }
            }
            if editor.tool.hasColor {
                HStack(spacing: 5) {
                    ForEach(InkEditorModel.colors.prefix(5), id: \.self) { c in
                        Button { editor.color = c; editor.palette = nil } label: {
                            Circle().fill(Color(inkHex: c)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(editor.color == c ? Color.accentColor : .gray.opacity(0.35), lineWidth: editor.color == c ? 2 : 1).padding(-2))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(c)")
                    }
                    Divider().frame(height: 18)
                    InkSizePresets(editor: editor).scaleEffect(0.85)
                }
            } else if editor.tool.hasSize {
                InkSizePresets(editor: editor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}
