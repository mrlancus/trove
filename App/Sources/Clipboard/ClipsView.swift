import SwiftUI
import TroveCore

/// One row in the history: a synced clip, or a sensitive copy kept briefly on this device.
enum ClipEntry: Identifiable, Equatable {
    case clip(Clip)
    case sensitive(EphemeralClip)

    var id: String {
        switch self {
        case .clip(let c): c.id
        case .sensitive(let e): "s:" + e.id
        }
    }

    var clip: Clip? { if case .clip(let c) = self { c } else { nil } }
    var text: String {
        switch self {
        case .clip(let c): c.text
        case .sensitive(let e): e.text
        }
    }
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all, pinned, links, images, code, colors, text, otherDevices
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .links: "Links"
        case .images: "Images"
        case .code: "Code"
        case .colors: "Colors"
        case .text: "Text"
        case .otherDevices: "Other devices"
        }
    }

    func includes(_ entry: ClipEntry, thisDevice: String?) -> Bool {
        guard let clip = entry.clip else { return self == .all || self == .text }
        switch self {
        case .all: return true
        case .pinned: return clip.isPinned
        case .links: return clip.kind == .link
        case .images: return clip.kind == .image
        case .code: return [.code, .json].contains(clip.kind)
        case .colors: return clip.kind == .color
        case .text: return [.text, .email, .phone, .number, .path].contains(clip.kind)
        case .otherDevices: return clip.device != nil && clip.device != thisDevice
        }
    }
}

/// What the palette is showing: search, filter, the highlighted row and the paste stack.
@MainActor
@Observable
final class ClipPaletteState {
    var query = ""
    var filter: ClipFilter = .all
    var selection: String?
    /// Clips marked with ⇥ to paste together, in the order they were marked.
    var stack: [String] = []

    func entries(_ store: ClipboardStore, thisDevice: String?) -> [ClipEntry] {
        let sensitive = store.ephemeral.map(ClipEntry.sensitive)
        let synced = store.clips.map(ClipEntry.clip)
        let pinnedFirst = filter == .all && query.isEmpty
            ? synced.filter { $0.clip?.isPinned == true } + synced.filter { $0.clip?.isPinned != true }
            : synced
        return (sensitive + pinnedFirst).filter { entry in
            guard filter.includes(entry, thisDevice: thisDevice) else { return false }
            switch entry {
            case .clip(let c): return c.matches(query)
            case .sensitive(let e): return query.isEmpty || e.text.localizedCaseInsensitiveContains(query)
            }
        }
    }

    func move(_ delta: Int, in entries: [ClipEntry]) {
        guard !entries.isEmpty else { selection = nil; return }
        let index = entries.firstIndex { $0.id == selection } ?? -1
        selection = entries[max(0, min(entries.count - 1, index + delta))].id
    }

    func toggleStack(_ id: String) {
        if let i = stack.firstIndex(of: id) { stack.remove(at: i) } else { stack.append(id) }
    }
}

/// The clipboard history UI. `.palette` is the Mac's floating window (keyboard driven, preview on the
/// right); `.list` is the iPhone/iPad screen (tap to copy).
struct ClipsView: View {
    enum Style { case palette, list }

    let style: Style
    @Bindable var state: ClipPaletteState
    let store: ClipboardStore
    let thisDevice: String?
    /// Paste (palette) or copy (list) the entry, optionally rewritten.
    var activate: (ClipEntry, ClipTransform?) -> Void
    var saveToLibrary: (Clip) -> Void = { _ in }
    var close: () -> Void = {}
    @FocusState private var searchFocused: Bool

    private var entries: [ClipEntry] { state.entries(store, thisDevice: thisDevice) }
    private var selected: ClipEntry? { entries.first { $0.id == state.selection } ?? entries.first }

    var body: some View {
        switch style {
        case .palette: palette
        case .list: list
        }
    }

    // MARK: Palette (Mac)

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.orange).font(.title3)
                TextField("Search your clipboard…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                if !state.stack.isEmpty {
                    Label("\(state.stack.count) stacked", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            filterChips.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            HStack(spacing: 0) {
                rows.frame(width: 330)
                Divider()
                Group {
                    if let selected { ClipPreview(entry: selected, store: store, thisDevice: thisDevice, activate: activate, saveToLibrary: saveToLibrary) }
                    else { emptyState }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: state.query) { state.selection = entries.first?.id }
        .onChange(of: state.filter) { state.selection = entries.first?.id }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipFilter.allCases) { f in
                    Button { state.filter = f } label: {
                        Text(f.title).font(.callout.weight(state.filter == f ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(state.filter == f ? AnyShapeStyle(.orange.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                            .foregroundStyle(state.filter == f ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        ClipRow(entry: entry, store: store, index: index, selected: entry.id == (selected?.id),
                                stacked: state.stack.firstIndex(of: entry.id).map { $0 + 1 })
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { activate(entry, nil) }
                            .onTapGesture { state.selection = entry.id }
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("⏎", "Paste")
            hint("⌥⏎", "Copy")
            hint("⇥", "Stack")
            hint("⌘P", "Pin")
            hint("⌘S", "Save to Trove")
            hint("⌘⌫", "Delete")
            Spacer()
            hint("esc", "Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    private var emptyState: some View {
        EmptyState(symbol: "doc.on.clipboard",
                   title: store.clips.isEmpty ? "Nothing copied yet" : "No matches",
                   message: store.clips.isEmpty ? "Copy anything and it shows up here, on every device." : "Try another word or filter.")
    }

    // MARK: List (iPhone / iPad)

    private var list: some View {
        List {
            Section {
                PasteButton(payloadType: String.self) { strings in
                    Task { for s in strings { await store.capture(text: s, sourceApp: nil) } }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
            } footer: {
                Text("iOS only lets apps read the clipboard when you ask, so tap Paste to add what you copied. Copies on your Mac appear here automatically.")
            }
            Section {
                Picker("Show", selection: $state.filter) {
                    ForEach(ClipFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                ForEach(entries) { entry in
                    Button { activate(entry, nil) } label: {
                        ClipRow(entry: entry, store: store, index: nil, selected: false, stacked: nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: entry) }
                    .swipeActions(edge: .leading) {
                        if let clip = entry.clip {
                            Button { Task { await store.togglePin(clip) } } label: { Label(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
                                .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .searchable(text: $state.query, prompt: "Search your clipboard")
        .overlay {
            if entries.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func menu(for entry: ClipEntry) -> some View {
        Button { activate(entry, nil) } label: { Label("Copy", systemImage: "doc.on.doc") }
        if let clip = entry.clip {
            ForEach(ClipTransform.available(for: clip.text), id: \.self) { t in
                Button { activate(entry, t) } label: { Text("Copy as \(t.title)") }
            }
            Button { Task { await store.togglePin(clip) } } label: { Label(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
            Button { saveToLibrary(clip) } label: { Label("Save to Trove", systemImage: "tray.and.arrow.down") }
        }
        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
    }

    private func delete(_ entry: ClipEntry) {
        switch entry {
        case .clip(let c): Task { await store.delete(c) }
        case .sensitive(let e): store.forget(e)
        }
    }
}

// MARK: - Rows and previews

struct ClipRow: View {
    let entry: ClipEntry
    let store: ClipboardStore
    let index: Int?
    let selected: Bool
    let stacked: Int?

    var body: some View {
        HStack(spacing: 10) {
            ClipBadge(entry: entry, store: store).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                    .font(entry.clip.map { [.code, .json].contains($0.kind) } == true ? .callout.monospaced() : .callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let stacked {
                Text("\(stacked)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(.orange, in: Circle())
            } else if entry.clip?.isPinned == true {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            } else if let index, index < 9 {
                Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(.orange.opacity(0.16)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 9))
    }

    private var title: String {
        switch entry {
        case .clip(let c): c.preview.isEmpty ? c.kind.title : c.preview
        case .sensitive: "Hidden: looks like a password or code"
        }
    }

    private var subtitle: String {
        switch entry {
        case .clip(let c):
            let from = [c.sourceApp, c.device == nil ? nil : c.sourceDevice].compactMap { $0 }.joined(separator: " · ")
            return [from.isEmpty ? nil : from, c.sortDate.relative].compactMap { $0 }.joined(separator: " · ")
        case .sensitive(let e):
            return "This device only · gone \(e.expires.relative)"
        }
    }
}

/// The square on the left of a row: an image thumbnail, a color swatch or the kind's symbol.
struct ClipBadge: View {
    let entry: ClipEntry
    let store: ClipboardStore
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else if let clip = entry.clip, clip.kind == .color, let c = ClipClassifier.color(clip.text) {
                RoundedRectangle(cornerRadius: 8).fill(Color(red: c.r, green: c.g, blue: c.b, opacity: c.a))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            } else {
                Image(systemName: symbol).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.orange.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: entry.id) {
            if let clip = entry.clip, clip.image != nil { image = await store.image(for: clip) }
        }
    }

    private var symbol: String {
        switch entry {
        case .clip(let c): c.kind.symbol
        case .sensitive: "lock.fill"
        }
    }
}

/// Right-hand side of the palette: the whole clip, smart extras for its kind, and actions.
struct ClipPreview: View {
    let entry: ClipEntry
    let store: ClipboardStore
    let thisDevice: String?
    var activate: (ClipEntry, ClipTransform?) -> Void
    var saveToLibrary: (Clip) -> Void
    @State private var image: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let clip = entry.clip {
                let transforms = ClipTransform.available(for: clip.text)
                if clip.image == nil, clip.files.isEmpty, !transforms.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("Paste as").font(.caption).foregroundStyle(.secondary)
                            ForEach(transforms, id: \.self) { t in
                                Button(t.title) { activate(entry, t) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                HStack {
                    Text(meta(clip)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { Task { await store.togglePin(clip) } } label: { Image(systemName: clip.isPinned ? "pin.slash" : "pin") }
                        .help(clip.isPinned ? "Unpin" : "Pin")
                    Button { saveToLibrary(clip) } label: { Image(systemName: clip.savedItem == nil ? "tray.and.arrow.down" : "checkmark.circle") }
                        .help("Save to Trove")
                    Button(role: .destructive) { Task { await store.delete(clip) } } label: { Image(systemName: "trash") }
                        .help("Delete")
                }
                .buttonStyle(.borderless)
            } else if case .sensitive(let e) = entry {
                Label("Kept on this device for two minutes, never synced. Gone \(e.expires.relative).", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task(id: entry.id) {
            image = nil
            if let clip = entry.clip, clip.image != nil { image = await store.image(for: clip) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry {
        case .sensitive(let e):
            VStack(alignment: .leading, spacing: 8) {
                Text(String(repeating: "•", count: min(24, e.text.count))).font(.title2.monospaced())
                Text("Looks like a password, key or one-time code").foregroundStyle(.secondary)
            }
        case .clip(let clip):
            switch clip.kind {
            case .image:
                if let image { Image(platformImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
                else { ProgressView() }
            case .color:
                if let c = ClipClassifier.color(clip.text) { ColorDetails(text: clip.text, r: c.r, g: c.g, b: c.b, a: c.a) }
            case .link:
                VStack(alignment: .leading, spacing: 8) {
                    Text(URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Link").font(.title3.weight(.semibold))
                    Text(clip.text).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(6)
                    if let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Link(destination: url) { Label("Open", systemImage: "safari") }
                    }
                }
            case .file:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(clip.files, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "doc").help(path)
                    }
                }
            case .code, .json:
                ScrollView { Text(clip.text).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            default:
                ScrollView { Text(clip.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    private func meta(_ clip: Clip) -> String {
        var parts: [String] = []
        if let app = clip.sourceApp { parts.append(app) }
        if clip.device != thisDevice, let device = clip.sourceDevice { parts.append("from \(device)") }
        parts.append(clip.createdAt.relative)
        if clip.image == nil, clip.files.isEmpty {
            let words = clip.text.split(whereSeparator: \.isWhitespace).count
            parts.append("\(clip.text.count) characters · \(words) words")
        }
        return parts.joined(separator: " · ")
    }
}

/// A big swatch with the color in the formats people paste: hex, rgb() and hsl().
struct ColorDetails: View {
    let text: String
    let r: Double, g: Double, b: Double, a: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(Color(red: r, green: g, blue: b, opacity: a))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            ForEach(formats, id: \.self) { value in
                HStack {
                    Text(value).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button { ClipPasteboard.write(text: value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                }
            }
        }
    }

    private var formats: [String] {
        let R = Int((r * 255).rounded()), G = Int((g * 255).rounded()), B = Int((b * 255).rounded())
        let hex = String(format: "#%02X%02X%02X", R, G, B)
        let maxC = max(r, g, b), minC = min(r, g, b), l = (maxC + minC) / 2, d = maxC - minC
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maxC == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
        }
        let alpha = a < 1 ? String(format: ", %.2f", a) : ""
        return [hex, "rgb\(a < 1 ? "a" : "")(\(R), \(G), \(B)\(alpha))",
                "hsl\(a < 1 ? "a" : "")(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%\(alpha))"]
    }
}
