import SwiftUI
import TroveCore
#if os(iOS)
import GameController
#endif

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
    /// The clip being edited in place of the preview (⌘E).
    var editing: String?
    /// One of your tags: only clips with it are shown.
    var tag: String?
    /// Bumped to put the cursor in the search field (each time the palette opens).
    var focusRequest = 0
    /// The "new tag" row, while it's open.
    var newTag: NewTagDraft?

    struct NewTagDraft: Equatable {
        var name = ""
        var color: TagColor = .blue
        /// The clip that gets the tag once it's made, when it was started from a clip's menu.
        var forClip: String?
    }

    /// The last answer, kept until the clips, the search or the filters change: the view asks
    /// several times per keystroke.
    @ObservationIgnored private var cached: (key: String, entries: [ClipEntry])?

    func entries(_ store: ClipboardStore, thisDevice: String?) -> [ClipEntry] {
        let key = "\(store.revision)|\(store.ephemeral.map(\.id).joined(separator: ","))|\(filter.rawValue)|\(tag ?? "")|\(thisDevice ?? "")|\(query)"
        if let cached, cached.key == key { return cached.entries }
        let parsed = ClipQuery(query)
        let sensitive = tag == nil ? store.ephemeral.map(ClipEntry.sensitive) : []
        let synced = store.clips.map(ClipEntry.clip)
        let pinnedFirst = filter == .all && parsed.isEmpty
            ? synced.filter { $0.clip?.isPinned == true } + synced.filter { $0.clip?.isPinned != true }
            : synced
        let found = (sensitive + pinnedFirst).filter { entry in
            guard filter.includes(entry, thisDevice: thisDevice) else { return false }
            switch entry {
            case .clip(let c):
                if let tag, !c.tags.contains(tag) { return false }
                return parsed.isEmpty || parsed.matches(c, haystack: store.searchText(c))
            case .sensitive(let e): return query.isEmpty || e.text.localizedCaseInsensitiveContains(query)
            }
        }
        cached = (key, found)
        return found
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
                    if let clip = selected?.clip, state.editing == clip.id {
                        ClipDetailForm(clip: clip, store: store, thisDevice: thisDevice, saveToLibrary: saveToLibrary) { state.editing = nil }
                    } else if let selected {
                        ClipPreview(entry: selected, store: store, thisDevice: thisDevice, activate: activate, saveToLibrary: saveToLibrary,
                                    edit: { state.editing = $0.id })
                    } else { emptyState }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: state.focusRequest) { searchFocused = true }
        .onChange(of: state.query) { state.selection = entries.first?.id }
        .onChange(of: state.tag) { state.selection = entries.first?.id }
        .onChange(of: state.selection) { if state.editing != state.selection { state.editing = nil } }
        .onChange(of: state.filter) { state.selection = entries.first?.id }
    }

    /// The kinds, then your tags in their colours (click one to see only its clips), then "+ Tag".
    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Divider().frame(height: 16)
                    ForEach(store.customTags) { tag in tagChip(tag) }
                    Button { state.newTag = .init() } label: {
                        Label("Tag", systemImage: "plus").font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Make a tag with a colour, to sort clips into")
                }
                .padding(.vertical, 1)
            }
            if state.newTag != nil { NewTagRow(state: state, store: store) }
        }
    }

    private func tagChip(_ tag: CustomTag) -> some View {
        let on = state.tag == tag.name
        return Button { state.tag = on ? nil : tag.name } label: {
            HStack(spacing: 5) {
                Circle().fill(tag.color.color).frame(width: 8, height: 8)
                Text(tag.name).font(.callout.weight(on ? .semibold : .regular))
                Text("\(store.clips.lazy.filter { $0.tags.contains(tag.name) }.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tag.color.color.opacity(on ? 0.3 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? tag.color.color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Colour") {
                ForEach(TagColor.allCases, id: \.self) { c in
                    Button { Task { await store.setTagColor(tag.name, c) } } label: {
                        Label(c.rawValue.capitalized, systemImage: c == tag.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Button(role: .destructive) {
                if state.tag == tag.name { state.tag = nil }
                Task { await store.deleteTag(tag.name) }
            } label: { Label("Delete tag", systemImage: "trash") }
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
                            .contextMenu { if let clip = entry.clip { ClipTagMenu(clip: clip, store: store, state: state) } }
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
            hint("⌘E", "Edit")
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

    @State private var detail: String?

    private var list: some View {
        List {
            Section {
                PasteButton(payloadType: String.self) { strings in
                    Task { for s in strings { await store.capture(text: s, sourceApp: nil) } }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
            } footer: {
                Text("What you copy is saved each time you open Trove (iOS asks “Allow Paste?” unless you allow it in Settings → Apps → Trove → Paste from Other Apps). Copies on your other devices appear here by themselves.")
            }
            Section {
                filterChips
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            Section {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                        Button { activate(entry, nil) } label: {
                            ClipRow(entry: entry, store: store, index: nil, selected: false, stacked: nil)
                        }
                        .buttonStyle(.plain)
                        if let clip = entry.clip {
                            Button { detail = clip.id } label: { Image(systemName: "info.circle").font(.title3) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Details and edit")
                        }
                    }
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
        .searchable(text: $state.query, prompt: "Search your clipboard, or #tag, app:")
        .searchFocused($searchFocused)
        .onAppear { if Self.typingGoesToSearch { searchFocused = true } }
        .overlay {
            if entries.isEmpty { emptyState }
        }
        .sheet(item: Binding(get: { detail.map(ClipSheetID.init) }, set: { detail = $0?.id })) { sheet in
            ClipDetailSheet(clipID: sheet.id, store: store, thisDevice: thisDevice, saveToLibrary: saveToLibrary)
        }
    }


    @ViewBuilder
    private func menu(for entry: ClipEntry) -> some View {
        Button { activate(entry, nil) } label: { Label("Copy", systemImage: "doc.on.doc") }
        if let clip = entry.clip {
            ForEach(ClipTransform.available(for: clip.text), id: \.self) { t in
                Button { activate(entry, t) } label: { Text("Copy as \(t.title)") }
            }
            Button { detail = clip.id } label: { Label("Details and edit…", systemImage: "pencil") }
            ClipTagMenu(clip: clip, store: store, state: state)
            Button { Task { await store.togglePin(clip) } } label: { Label(clip.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
            Button { saveToLibrary(clip) } label: { Label("Save to Trove", systemImage: "tray.and.arrow.down") }
        }
        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
    }

    /// With a keyboard (the Mac, or an iPad with one attached), the search box has the cursor as
    /// soon as the clipboard opens, so typing searches. On a touch screen the keyboard would cover it.
    static var typingGoesToSearch: Bool {
        #if os(macOS)
        true
        #else
        GCKeyboard.coalesced != nil
        #endif
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
                Text(title).lineLimit(1).font(.callout.weight(entry.clip == nil ? .regular : .medium))
                if let snippet {
                    Text(snippet).lineLimit(1).foregroundStyle(.secondary)
                        .font(entry.clip.map { [.code, .json].contains($0.kind) } == true ? .caption.monospaced() : .caption)
                }
                HStack(spacing: 6) {
                    Text(subtitle).foregroundStyle(.secondary)
                    if let tags = entry.clip?.tags, !tags.isEmpty {
                        let mine: [String] = Array(tags.filter { store.color(ofTag: $0) != nil }.prefix(3))
                        ForEach(mine, id: \.self) { name in
                            let color = (store.color(ofTag: name) ?? .gray).color
                            Text(name).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(color.opacity(0.2), in: Capsule())
                                .foregroundStyle(color)
                        }
                        let rest = tags.filter { store.color(ofTag: $0) == nil }
                        if mine.count < 3, !rest.isEmpty {
                            Text(rest.prefix(3 - mine.count).map { "#" + $0 }.joined(separator: " ")).foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption).lineLimit(1)
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
        case .clip(let c): c.displayTitle
        case .sensitive: "Hidden: looks like a password or code"
        }
    }

    /// The summary, the start of the text, or the text found in an image, when it isn't the title.
    private var snippet: String? {
        guard let c = entry.clip else { return nil }
        let s = c.summary ?? (c.kind == .image ? c.ocrText?.split(separator: "\n").first.map(String.init) : c.preview)
        guard let s, !s.isEmpty, s != c.displayTitle else { return nil }
        return s
    }

    private var subtitle: String {
        switch entry {
        case .clip(let c):
            let app = [c.sourceApp, c.sourceTitle].compactMap { $0 }.joined(separator: " — ")
            let from = [app.isEmpty ? nil : app, c.device == nil ? nil : c.sourceDevice].compactMap { $0 }.joined(separator: " · ")
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
    var edit: (Clip) -> Void = { _ in }
    @State private var image: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let clip = entry.clip {
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.displayTitle).font(.headline).lineLimit(2)
                    if let summary = clip.summary { Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                    if !clip.tags.isEmpty { Text(clip.tags.map { "#" + $0 }.joined(separator: " ")).font(.caption).foregroundStyle(.orange) }
                }
            }
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
                    ClipTagMenu(clip: clip, store: store, state: nil)
                        .labelStyle(.iconOnly)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Tags")
                    Button { edit(clip) } label: { Image(systemName: "pencil") }
                        .help("Details and edit (⌘E)")
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
                VStack(alignment: .leading, spacing: 8) {
                    if let image { Image(platformImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
                    else { ProgressView() }
                    if let ocr = clip.ocrText { Text(ocr).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                }
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
        if let page = clip.sourceURL?.host ?? clip.sourceTitle { parts.append(page) }
        if clip.device != thisDevice, let device = clip.sourceDevice { parts.append("from \(device)") }
        parts.append(clip.createdAt.relative)
        if clip.image == nil, clip.files.isEmpty {
            let i = clip.insights
            parts.append("\(i.chars) character\(i.chars == 1 ? "" : "s") · \(i.words) word\(i.words == 1 ? "" : "s")")
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

// MARK: - Tags

/// "Tags" in a clip's menu: tick your tags on and off, or make a new one for it.
struct ClipTagMenu: View {
    let clip: Clip
    let store: ClipboardStore
    /// Where "New tag…" opens its row; nil where there's no row to open (it's made blue instead).
    let state: ClipPaletteState?

    var body: some View {
        Menu {
            ForEach(store.customTags) { tag in
                Button { Task { await store.toggleTag(tag.name, on: clip) } } label: {
                    Label(tag.name, systemImage: clip.tags.contains(tag.name) ? "checkmark.circle.fill" : "circle")
                }
            }
            if !store.customTags.isEmpty { Divider() }
            if let state {
                Button { state.newTag = .init(forClip: clip.id) } label: { Label("New tag…", systemImage: "plus") }
            } else if store.customTags.isEmpty {
                Text("Make a tag with + Tag above")
            }
        } label: { Label("Tags", systemImage: "tag") }
    }
}

/// Name and colour for a new tag, under the filter chips.
struct NewTagRow: View {
    @Bindable var state: ClipPaletteState
    let store: ClipboardStore
    @FocusState private var focused: Bool

    var body: some View {
        let draft = state.newTag ?? .init()
        HStack(spacing: 8) {
            TextField("New tag", text: Binding(get: { state.newTag?.name ?? "" }, set: { state.newTag?.name = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .focused($focused)
                .onSubmit(create)
            ForEach(TagColor.allCases, id: \.self) { c in
                Button { state.newTag?.color = c } label: {
                    Circle().fill(c.color).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(draft.color == c ? 0.8 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.rawValue.capitalized)
            }
            Spacer(minLength: 4)
            Button("Cancel") { state.newTag = nil }.buttonStyle(.borderless)
            Button("Add", action: create).buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { focused = true }
    }

    private func create() {
        guard let draft = state.newTag, !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.newTag = nil
        Task {
            guard let name = await store.setTagColor(draft.name, draft.color) else { return }
            if let id = draft.forClip, let clip = store.clips.first(where: { $0.id == id }), !clip.tags.contains(name) {
                await store.toggleTag(name, on: clip)
            }
        }
    }
}
