import QuickLook
import SwiftUI
import TroveCore
import UniformTypeIdentifiers

// Pieces of the item screen added with folders, versions and connections (docs/PROTOCOL.md §9).

/// "Documents › Spreadsheets · filed automatically", with a Move menu.
struct FolderLine: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        let path = model.folderPath(item.folder)
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(FolderStyle.color(for: path.first?.id))
            if path.isEmpty {
                Text("Not in a folder").foregroundStyle(.secondary)
            } else {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(folder.name) { model.selection = .folder(folder.id) }.buttonStyle(.plain)
                }
                if item.isAutoFiled { Text("· filed automatically").foregroundStyle(.secondary).help("Move it and it stays where you put it.") }
            }
            Spacer()
            // Whether your AI may look at it (Ask, reading handwriting); everything may by default.
            Button { Task { await model.setAIAllowed(item, !item.aiAllowed) } } label: {
                Label(item.aiAllowed ? "AI can see" : "Hidden from AI", systemImage: item.aiAllowed ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(item.aiAllowed ? Color.secondary : Color.orange)
            .fixedSize()
            .help(item.aiAllowed ? "Your AI can look at this when it needs to. Click to hide it." : "Your AI never sees this. Click to let it.")
            Menu {
                Button("No folder") { Task { await model.move(item.id, to: nil) } }
                ForEach(model.folderEntries) { entry in
                    Button { Task { await model.move(item.id, to: entry.folder.id) } } label: {
                        Label(entry.indentedName, systemImage: item.folder == entry.folder.id ? "checkmark" : "folder")
                    }
                }
            } label: { Label("Move", systemImage: "folder.badge.gearshape") }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .font(.callout)
    }
}

/// The item's files: a preview each, Quick Look, a new version, and the earlier versions.
struct FilesSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.pickFiles) private var pickFiles
    @State private var quickLook: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(item.attachments.enumerated()), id: \.element.id) { index, attachment in
                VStack(alignment: .leading, spacing: 8) {
                    // One line: the name and size, Open, and New version (in "⋯" when there's no room).
                    ViewThatFits(in: .horizontal) {
                        fileRow(attachment, index: index, compact: false)
                        fileRow(attachment, index: index, compact: true)
                    }
                    AttachmentView(attachment: attachment, item: item)
                }
            }
            if !item.fileVersions.isEmpty {
                DisclosureGroup("Versions (\(item.fileVersions.count) earlier)") {
                    ForEach(item.fileVersions, id: \.attachment.id) { version in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(version.at.formatted(.relative(presentation: .named))).font(.callout.weight(.semibold))
                                Text([version.attachment.name, ByteCountFormatter.string(fromByteCount: Int64(version.attachment.size), countStyle: .file)]
                                    .joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { Task { quickLook = await model.temporaryFile(version.attachment) } }
                            Button("Restore") { Task { await model.restore(item, version) } }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.vertical, 4)
                    }
                }
                .padding(12)
                .card(cornerRadius: 14)
            }
        }
        .quickLookPreview($quickLook)
    }

    private func fileRow(_ attachment: Attachment, index: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text(attachment.name).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 4)
            Button { model.openFile(item, attachment) } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("Open full screen. Edit there to draw, highlight, fill in or mark up.")
            if index == 0 {
                if compact {
                    Menu {
                        Button { chooseVersion() } label: { Label("New version", systemImage: "square.and.arrow.down.on.square") }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More")
                } else {
                    Button { chooseVersion() } label: { Label("New version", systemImage: "square.and.arrow.down.on.square") }
                        .fixedSize()
                        .help("Replace with an edited copy; the current file is kept as a version")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Through the window's one file picker (`ImportPickers`).
    private func chooseVersion() {
        let model = model, item = item
        pickFiles(FilePick(types: [.item], multiple: false) { urls in
            if let url = urls.first { Task { await model.replaceFile(item, with: url) } }
        })
    }
}

/// A GoodNotes notebook: the cover and the documents inside it.
struct GoodNotesPreview: View {
    let preview: FilePreview.GoodNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                if let data = preview.thumbnail, let image = PlatformImage(data: data) {
                    Image(platformImage: image).resizable().scaledToFit().frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 8)).shadow(radius: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("GoodNotes notebook").font(.headline)
                    Text("\(preview.pages) page\(preview.pages == 1 ? "" : "s")\(preview.documents.isEmpty ? "" : " · \(preview.documents.count) document\(preview.documents.count == 1 ? "" : "s") inside")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Couldn't read the pages of this notebook, so here are its cover and the documents inside.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(preview.documents.enumerated()), id: \.offset) { _, doc in
                if doc.mime == "application/pdf" {
                    PDFKitView(data: doc.data).frame(minHeight: 420).clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let image = PlatformImage(data: doc.data) {
                    Image(platformImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .card(cornerRadius: 14)
    }
}

/// Earlier versions of a note's text, to read and restore.
struct HistorySheet: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [TextVersion] = []
    @State private var chosen = 0

    var body: some View {
        NavigationStack {
            Group {
                if versions.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "No edits yet", message: "Each editing session is kept here.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Version", selection: $chosen) {
                            ForEach(Array(versions.enumerated()), id: \.offset) { index, v in
                                Text(index == 0 ? "Latest · \(v.at.formatted(date: .abbreviated, time: .shortened))" : v.at.formatted(date: .abbreviated, time: .shortened))
                                    .tag(index)
                            }
                        }
                        ScrollView {
                            Text(versions[chosen].text.isEmpty ? "(empty)" : versions[chosen].text)
                                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .card(cornerRadius: 12)
                    }
                    .padding()
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore this version") {
                        let text = versions[chosen].text
                        Task { await model.setBody(item.id, text); await model.reload(); dismiss() }
                    }
                    .disabled(versions.isEmpty || chosen == 0 || versions[chosen].text == item.body)
                }
            }
        }
        .sheetSize(width: 600, height: 560)
        .task { versions = await model.textVersions(item) }
    }
}

/// Links to and from this item, unmade links, mentions, suggestions, and Connect to….
struct ConnectionsSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    /// Worked out in the background when the item or the library changes: "Mentioned in" and
    /// "Maybe related" read every other item's text, which stalled opening an item when it ran on
    /// every redraw.
    @State private var found = Found()

    struct Found: Sendable {
        var outgoing: [Item] = []
        var incoming: [Item] = []
        var mentions: [Item] = []
        var related: [Item] = []
    }

    var body: some View {
        let outgoing = found.outgoing, incoming = found.incoming
        let mentions = found.mentions, related = found.related
        let unmade = model.links.unresolved[item.id] ?? []
        content(outgoing: outgoing, incoming: incoming, mentions: mentions, related: related, unmade: unmade)
            .task(id: "\(item.id)|\(model.dataVersion)") {
                let items = model.items, graph = model.links, item = item
                found = await Task.detached(priority: .userInitiated) {
                    let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let linked = Set(graph.neighbours(of: item.id))
                    return Found(outgoing: (graph.outgoing[item.id] ?? []).compactMap { byId[$0] },
                                 incoming: (graph.incoming[item.id] ?? []).compactMap { byId[$0] },
                                 mentions: Array(Links.mentions(of: item, in: items, linked: linked).prefix(8)),
                                 related: Array(Links.related(to: item, in: items).filter { !linked.contains($0.id) }.prefix(5)))
                }.value
            }
    }

    @ViewBuilder
    private func content(outgoing: [Item], incoming: [Item], mentions: [Item], related: [Item], unmade: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Button { connecting = true } label: { Label("Connect to…", systemImage: "link.badge.plus") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            group("Links to", outgoing) { other in item.links.contains(other.id) }
            group("Linked from", incoming) { other in other.links.contains(item.id) }
            if !unmade.isEmpty {
                Text("Not made yet").font(.caption).foregroundStyle(.secondary)
                FlowRow {
                    ForEach(unmade, id: \.self) { title in
                        Button("+ \(title)") { Task { await model.openWikilink(title) } }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if !mentions.isEmpty {
                Text("Mentioned in").font(.caption).foregroundStyle(.secondary)
                FlowRow { ForEach(mentions) { other in chip(other, action: ("Link", { _ = Task { await model.connect(other.id, item.id) } })) } }
            }
            if !related.isEmpty {
                Text("Maybe related").font(.caption).foregroundStyle(.secondary)
                FlowRow { ForEach(related) { other in chip(other, action: ("Connect", { _ = Task { await model.connect(item.id, other.id) } })) } }
            }
            if outgoing.isEmpty, incoming.isEmpty, unmade.isEmpty, mentions.isEmpty, related.isEmpty {
                Text("Type [[ and a title in your notes to link things, or use Connect to….").font(.caption).foregroundStyle(.secondary)
            }
            if !outgoing.isEmpty || !incoming.isEmpty {
                GraphCanvas(focus: item.id, compact: true).frame(height: 220).card(cornerRadius: 14)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
        .sheet(isPresented: $connecting) { ConnectSheet(item: item) }
    }

    @ViewBuilder
    private func group(_ label: String, _ others: [Item], removable: @escaping (Item) -> Bool) -> some View {
        if !others.isEmpty {
            Text(label).font(.caption).foregroundStyle(.secondary)
            FlowRow {
                ForEach(others) { other in
                    if removable(other) {
                        chip(other, action: ("×", { _ = Task { await model.disconnect(item.id, other.id) } }))
                    } else {
                        chip(other, action: nil)
                    }
                }
            }
        }
    }

    private func chip(_ other: Item, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 4) {
            Button(other.displayTitle) { model.selectedItemID = other.id }.buttonStyle(.plain).lineLimit(1)
            if let action { Button(action.0, action: action.1).buttonStyle(.plain).foregroundStyle(.tint).font(.caption.weight(.semibold)) }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.background.secondary, in: Capsule())
    }
}

struct ConnectSheet: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { other in
                    Button {
                        Task { await model.connect(item.id, other.id); dismiss() }
                    } label: {
                        Label(other.displayTitle, systemImage: ItemStyle.symbol(for: other))
                    }
                }
            }
            .searchable(text: $query, prompt: "Find something to connect")
            .navigationTitle("Connect to…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheetSize(width: 480, height: 520)
    }

    private var results: [Item] {
        let others = model.items.filter { $0.id != item.id && !item.links.contains($0.id) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(others.prefix(30)) }
        return others.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }.prefix(30).map { $0 }
    }
}

/// Lays chips out in rows that wrap.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
