import SwiftUI
import TroveCore

/// The ruler and protractor buttons (toolbar). On iPad the ruler is PencilKit's own (draw along it,
/// turn it with two fingers); elsewhere it's Trove's, moved by its body and turned by its knobs.
struct InkGuideButtons: View {
    let editor: InkEditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { editor.toggleGuide(.ruler) } label: {
                Image(systemName: "ruler").font(.title3).frame(width: 34, height: 34)
                    .foregroundStyle(editor.ruler != nil ? Color.accentColor : Color.primary)
                    .background(editor.ruler != nil ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .inkTapArea()
            }
            .buttonStyle(.plain)
            .help("Ruler: draw along its edges; drag it to move, its round knobs to turn")
            .accessibilityLabel("Ruler")
            .accessibilityAddTraits(editor.ruler != nil ? .isSelected : [])
            Button { editor.toggleGuide(.protractor) } label: {
                Image(systemName: "angle").font(.title3).frame(width: 34, height: 34)
                    .foregroundStyle(editor.protractor != nil ? Color.accentColor : Color.primary)
                    .background(editor.protractor != nil ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .inkTapArea()
            }
            .buttonStyle(.plain)
            .help("Protractor: measure angles and draw arcs along it")
            .accessibilityLabel("Protractor")
            .accessibilityAddTraits(editor.protractor != nil ? .isSelected : [])
        }
    }
}

/// A text box's font, bold, italic and bullets (the box being typed in, the selected boxes, or the next new one).
struct InkTextStyleBar: View {
    let editor: InkEditorModel

    var body: some View {
        let style = editor.currentTextStyle
        HStack(spacing: 6) {
            Picker("Font", selection: Binding(get: { style.font }, set: { f in
                var next = editor.currentTextStyle
                next.font = f
                editor.applyTextStyle(next)
            })) {
                ForEach(InkTextStyle.Font.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Button {
                var next = editor.currentTextStyle
                next.bold.toggle()
                editor.applyTextStyle(next)
            } label: { Image(systemName: "bold").frame(width: 30, height: 30).inkTapArea() }
                .buttonStyle(.plain)
                .foregroundStyle(style.bold ? Color.accentColor : Color.primary)
                .background(style.bold ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Bold")
                .accessibilityAddTraits(style.bold ? .isSelected : [])
            Button {
                var next = editor.currentTextStyle
                next.italic.toggle()
                editor.applyTextStyle(next)
            } label: { Image(systemName: "italic").frame(width: 30, height: 30).inkTapArea() }
                .buttonStyle(.plain)
                .foregroundStyle(style.italic ? Color.accentColor : Color.primary)
                .background(style.italic ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Italic")
                .accessibilityAddTraits(style.italic ? .isSelected : [])
            if editor.textEdit != nil {
                Button { editor.toggleBullets() } label: { Image(systemName: "list.bullet").frame(width: 30, height: 30).inkTapArea() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bullet list")
                Button("Done") { editor.commitTextEdit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// The lasso's turn, flip, front/back and straighten buttons.
struct InkSelectionArrangeButtons: View {
    let editor: InkEditorModel

    var body: some View {
        HStack(spacing: 4) {
            icon("rotate.right", "Turn a quarter right") { editor.turnSelection(by: Double.pi / 2) }
            icon("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip left to right") { editor.flipSelection(horizontal: true) }
            icon("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip upside down") { editor.flipSelection(horizontal: false) }
            icon("square.3.layers.3d.top.filled", "Bring to front") { editor.arrangeSelection(front: true) }
            icon("square.3.layers.3d.bottom.filled", "Send to back") { editor.arrangeSelection(front: false) }
            icon("level", "Straighten") { editor.straightenSelection() }
        }
    }

    private func icon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 22, minHeight: 22) }
            .help(label)
            .accessibilityLabel(label)
    }
}

/// The elements library: Trove's own elements and the ones you saved, by folder. A tap puts one on
/// the page (selected, so it can be moved straight away).
struct InkElementsLibrary: View {
    let editor: InkEditorModel
    var close: () -> Void
    @State private var previews: [String: InkImage] = [:]

    private var folders: [(title: String, items: [InkSticker])] {
        var order: [String] = []
        var groups: [String: [InkSticker]] = [:]
        for s in editor.stickers {
            let title = s.builtin ? "Trove: " + s.folder : (s.folder.isEmpty ? "Yours" : s.folder)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(s)
        }
        return order.map { (title: $0, items: groups[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(folders, id: \.title) { folder in
                    Text(folder.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(folder.items) { sticker in tile(sticker) }
                    }
                }
                Text("Select something with the lasso, then Save as element to keep it here, on every device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .task {
            await editor.loadStickers()
            await renderPreviews()
        }
    }

    private func tile(_ sticker: InkSticker) -> some View {
        Button { editor.placeSticker(sticker); close() } label: {
            VStack(spacing: 4) {
                ZStack {
                    Color.white
                    if let image = previews[sticker.id] { Image(decorative: image.image, scale: 2).resizable().scaledToFit().padding(4) }
                }
                .frame(width: 64, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.3)))
                Text(sticker.name).font(.caption2).lineLimit(1)
            }
            .frame(width: 76)
            .inkTapArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.name)
        .contextMenu {
            if !sticker.builtin {
                Button(role: .destructive) { editor.deleteSticker(sticker) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    /// Small pictures of each element, drawn once.
    private func renderPreviews() async {
        for sticker in editor.stickers where previews[sticker.id] == nil {
            let content = InkEditorModel.stickerContent(sticker)
            let box = InkGeometry.Rect(x: -4, y: -4, width: max(8, sticker.w + 8), height: max(8, sticker.h + 8))
            let scale = min(4, 128 / max(box.width, box.height))
            let image = await Task.detached(priority: .utility) { InkRenderer.renderSelection(content, box: box, scale: scale).map(InkImage.init) }.value
            if let image { previews[sticker.id] = image }
        }
    }
}

/// Ask AI's answer: save it as a note connected to the drawing (or the flashcards), or copy it.
struct InkAIResultSheet: View {
    let result: InkAIResult
    let editor: InkEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if result.result.cards.isEmpty {
                        Text(LocalizedStringKey(result.result.text)).textSelection(.enabled)
                    } else {
                        ForEach(Array(result.result.cards.enumerated()), id: \.offset) { _, card in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.front).font(.headline)
                                Text(card.back).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text(result.result.label).font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(result.action.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { editor.aiResult = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(result.result.cards.isEmpty ? "Save as note" : "Save flashcards") { editor.saveAIResult(); dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
