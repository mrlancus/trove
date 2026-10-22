import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().task { await model.start() }
        case .onboarding:
            OnboardingView()
        case .ready:
            MainView()
        case .failed(let message):
            VStack(spacing: 16) {
                EmptyState(symbol: "exclamationmark.triangle", title: "Trove couldn't open your vault", message: message)
                Button("Try again") { Task { model.phase = .loading } }.buttonStyle(.borderedProminent)
                Button("Set up this device again", role: .destructive) { model.resetThisDevice() }
            }
            .padding()
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showAsk = false
    @State private var showSettings = false
    @State private var showClipboard = false
    @State private var dropTargeted = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            #if os(iOS)
            if sizeClass == .compact { PhoneRootView(showSettings: $showSettings, showClipboard: $showClipboard) } else { split }
            #else
            split
            #endif
        }
        .sheet(isPresented: $model.showCapture) { CaptureView().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showAsk) { AskView() }
        .sheet(isPresented: $showClipboard) { ClipboardScreen() }
        #if os(iOS)
        .fullScreenCover(item: $model.inkTarget) { target in InkEditorView(target: target, app: model).environment(model) }
        .fullScreenCover(item: $model.fileViewer) { target in FileViewer(target: target).environment(model) }
        #else
        // On the Mac a sketch opens in its own window, beside the library, not over it.
        .onChange(of: model.inkTarget) { _, target in
            guard let target else { return }
            openWindow(id: "ink", value: target)
            model.inkTarget = nil
        }
        // Files open in a viewer window of their own too.
        .onChange(of: model.fileViewer) { _, target in
            guard let target else { return }
            openWindow(id: "file", value: target)
            model.fileViewer = nil
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        #endif
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if dropTargeted, model.selection != .importer { WindowDropOverlay().transition(.opacity) } }
        .animation(.easeOut(duration: 0.2), value: dropTargeted)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in
            DropHandler.handle(providers, model: model)
        }
        .environment(\.showAsk, { showAsk = true })
        .copiesSelection(model)
        // The one file picker (and Photos and the scanner) for everything in this window.
        .importPickers()
    }

    /// Connections takes the whole right side (list and detail columns); what was open closes, and a
    /// point tapped there opens over it.
    @ViewBuilder private var split: some View {
        if model.selection == .graph, model.searchText.isEmpty { graphSplit } else { columnsSplit }
    }

    private var graphSplit: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $columns) {
            SidebarView(showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            GraphScreen()
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search everything… try tag:recipe or is:pinned")
                .toolbar { toolbar }
        }
        .sheet(item: Binding(get: { model.selectedItem }, set: { if $0 == nil { model.selectedItemID = nil } })) { item in
            NavigationStack {
                ItemDetailView(item: item).id(item.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.selectedItemID = nil } } }
            }
            .importPickers() // a sheet presents its own pickers
            #if os(macOS)
            .sheetSize(width: 760, height: 820)
            #endif
        }
    }

    private var columnsSplit: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $columns) {
            SidebarView(showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            Group {
                if model.selection == .importer, model.searchText.isEmpty { ImportView() }
                else if model.selection == .clipboard { ClipboardScreen(embedded: true, select: { model.selectedClipID = $0 }) }
                else { LibraryView() }
            }
                .navigationSplitViewColumnWidth(min: 320, ideal: 520)
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search everything… try tag:recipe or is:pinned")
                .toolbar { toolbar }
        } detail: {
            if model.selection == .clipboard, model.searchText.isEmpty || model.selectedClipID != nil {
                if let id = model.selectedClipID, let clip = model.clipboard.clips.first(where: { $0.id == id }) {
                    ClipDetailPanel(clip: clip)
                } else {
                    EmptyState(symbol: "doc.on.clipboard", title: "Pick a clip", message: "Its details show here: the text, tags, note, where it came from and where you pasted it. Double-click a clip to copy it.")
                }
            } else if let item = model.selectedItem {
                ItemDetailView(item: item).id(item.id)
            } else {
                EmptyState(symbol: "sparkles.rectangle.stack", title: "Pick something", message: "Or press ⌘N for a note, or paste a link into Capture.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showCapture = true } label: { Label("Capture", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button { Task { await model.newSketch() } } label: { Label("New sketch", systemImage: "pencil.tip.crop.circle.badge.plus") }
                .help("New sketch (⇧⌘D): draw with the Pencil, a mouse or the trackpad")
            Button { Task { await model.openToday() } } label: { Label("Today", systemImage: "calendar") }
                .help("Today's note (⌘T)")
            Menu { AddMenu() } label: { Label("Add", systemImage: "ellipsis.circle") }
            Button { showAsk = true } label: { Label("Ask Trove", systemImage: "sparkles") }
                .keyboardShortcut("j", modifiers: .command)
            Button { showClipboard = true } label: { Label("Clipboard", systemImage: "doc.on.clipboard") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Clipboard history (⌥Space from anywhere on the Mac)")
            SyncIndicator()
        }
    }
}

/// "New from template": yours first, then the built-in ones (PROTOCOL.md §12).
struct TemplatesMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            let templates = model.noteTemplates
            ForEach(templates.filter(\.user)) { t in item(t) }
            if templates.contains(where: \.user) { Divider() }
            ForEach(templates.filter { !$0.user }) { t in item(t) }
        } label: {
            Label("New from template", systemImage: "doc.badge.plus")
        }
    }

    private func item(_ t: Notes.Template) -> some View {
        Button { Task { await model.newNote(from: t) } } label: { Label(t.name, systemImage: Self.symbol(t)) }
    }

    static func symbol(_ t: Notes.Template) -> String {
        if t.user { return "doc.text" }
        switch t.id {
        case "daily": return "calendar"
        case "meeting": return "person.2"
        case "journal": return "book"
        case "recipe": return "fork.knife"
        default: return "doc.text"
        }
    }
}

/// New note, import, voice note, scan: the "Add" menu everywhere.
struct AddMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showImporter) private var showImporter

    var body: some View {
        Button { Task { await model.newNote() } } label: { Label("New note", systemImage: "square.and.pencil") }
            .keyboardShortcut("n", modifiers: .command)
        Button { Task { await model.openToday() } } label: { Label("Today's note", systemImage: "calendar") }
            .keyboardShortcut("t", modifiers: .command)
        TemplatesMenu()
        Button { Task { await model.newSketch() } } label: { Label("New sketch", systemImage: "scribble.variable") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Button { showImporter() } label: { Label("Import files…", systemImage: "square.and.arrow.down") }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        VoiceNoteButton()
        #if os(iOS)
        ScanDocumentButton()
        PhotosImportButton()
        #endif
        Divider()
        Button { Task { await model.makeDigest() } } label: { Label("Make this week's digest", systemImage: "calendar.badge.clock") }
    }
}

extension EnvironmentValues {
    @Entry var showImporter: () -> Void = {}
    @Entry var showAsk: () -> Void = {}
}

/// Shown over the whole window while files are dragged over it.
struct WindowDropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                              style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .padding(20)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .symbolEffect(.pulse)
                Text("Drop to add to Trove").font(.title.weight(.semibold))
                Text("Files, folders, zips, links or text").foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct SyncIndicator: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { Task { await model.syncNow() } } label: {
            if model.sync.syncing {
                ProgressView().controlSize(.small)
            } else if model.sync.lastError != nil {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            } else {
                Image(systemName: model.sync.live ? "bolt.horizontal.icloud" : "checkmark.icloud").foregroundStyle(.secondary)
            }
        }
        .help(model.sync.lastError ?? (model.sync.lastSync.map { "Synced \($0.relative)" } ?? "Sync"))
        .keyboardShortcut("r", modifiers: .command)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glass(cornerRadius: 22)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.spring) { model.toast = nil }
                }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    /// On iPhone each row pushes its screen instead of filling a column.
    var onPick: ((AppModel.Selection) -> Void)? = nil
    @State private var newCollection = ""
    @State private var addingCollection = false
    @State private var folderName = ""
    @State private var folderAction: FolderAction?

    /// What the folder name alert is for.
    enum FolderAction: Identifiable {
        case create(parent: String?), rename(String)
        var id: String {
            switch self { case .create(let p): "new-\(p ?? "")"; case .rename(let id): "rename-\(id)" }
        }
    }

    private let primary: [SmartCollection] = [.recent, .pinned, .toRead, .notes, .sketches]
    private let smart: [SmartCollection] = [.recipes, .places, .thingsToBuy, .events, .videos, .quotes, .receipts, .handwriting, .needsAttention]

    var body: some View {
        @Bindable var model = model
        List(selection: onPick.map { pick in Binding(get: { nil }, set: { if let s = $0 { pick(s) } }) } ?? $model.selection) {
            Section {
                ForEach(primary) { s in row(s) }
                // Right under Sketches.
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .tag(AppModel.Selection.clipboard)
                Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(AppModel.Selection.graph)
                Label("Import", systemImage: "square.and.arrow.down.on.square")
                    .badge(model.importRun.map { $0.finished ? 0 : $0.total - $0.done } ?? 0)
                    .tag(AppModel.Selection.importer)
            }
            Section {
                OutlineGroup(model.folderNodes, children: \.children) { node in
                    folderRow(node.folder)
                }
                let unfiled = model.sidebarCounts.unfiled
                if unfiled > 0 {
                    Label("Unfiled", systemImage: "tray").badge(unfiled).tag(AppModel.Selection.unfiled)
                        .contextMenu { Button("Tidy up: file everything") { Task { await model.tidyUp() } } }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { folderName = ""; folderAction = .create(parent: nil) } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                        .help("New folder")
                        .sidebarHeaderButton()
                }
            }
            Section("Smart Collections") {
                ForEach(smart.filter { model.count($0) > 0 || $0 == .recipes || $0 == .places }) { s in row(s) }
            }
            Section {
                ForEach(model.collections) { c in
                    Label(c.name, systemImage: c.symbol)
                        .foregroundStyle(Color.trove(c.color))
                        .badge(model.sidebarCounts.collections[c.id] ?? 0)
                        .tag(AppModel.Selection.collection(c.id))
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button { addingCollection = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).sidebarHeaderButton()
                }
            }
            let sources = Set(model.sidebarCounts.sources.keys).subtracting([.app, .share]).sorted { ItemStyle.sourceLabel($0) < ItemStyle.sourceLabel($1) }
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources, id: \.self) { s in
                        Label(ItemStyle.sourceLabel(s), systemImage: ItemStyle.sourceSymbol(s))
                            .badge(model.sidebarCounts.sources[s] ?? 0)
                            .tag(AppModel.Selection.source(s))
                    }
                }
            }
        }
        .navigationTitle("Trove")
        .toolbar {
            ToolbarItem {
                #if os(macOS)
                // A plain button: SettingsLink in a toolbar was sometimes left greyed out (disabled)
                // after the Settings window had been open.
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
                #else
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                #endif
            }
        }
        .alert("New collection", isPresented: $addingCollection) {
            TextField("Name", text: $newCollection)
            Button("Create") {
                let name = newCollection
                newCollection = ""
                Task { if let id = await model.createCollection(name) { model.selection = .collection(id) } }
            }
            Button("Cancel", role: .cancel) { newCollection = "" }
        }
        .onChange(of: model.selection) { model.searchText = ""; model.selecting = false }
        .alert(folderAlertTitle, isPresented: Binding(get: { folderAction != nil }, set: { if !$0 { folderAction = nil } })) {
            TextField("Name", text: $folderName)
            Button(folderAlertButton) {
                let name = folderName, action = folderAction
                folderName = ""
                Task {
                    switch action {
                    case .create(let parent): if let id = await model.createFolder(name, in: parent) { model.selection = .folder(id) }
                    case .rename(let id): await model.renameFolder(id, to: name)
                    case nil: break
                    }
                }
            }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
    }

    private var folderAlertTitle: String {
        if case .rename = folderAction { return "Rename folder" }
        return "New folder"
    }

    private var folderAlertButton: String {
        if case .rename = folderAction { return "Rename" }
        return "Create"
    }

    private func folderRow(_ folder: Folder) -> some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: "folder.fill").foregroundStyle(FolderStyle.color(for: model.folderPath(folder.id).first?.id))
        }
            .badge(model.folderCount(folder.id))
            .tag(AppModel.Selection.folder(folder.id))
            .dropDestination(for: String.self) { ids, _ in
                let itemIds = ids.filter { id in model.items.contains { $0.id == id } }
                let folderIds = ids.filter { id in model.folders.contains { $0.id == id } && id != folder.id }
                Task {
                    for id in itemIds { await model.move(id, to: folder.id) }
                    for id in folderIds { await model.moveFolder(id, into: folder.id) }
                }
                return !(itemIds.isEmpty && folderIds.isEmpty)
            }
            .draggable(folder.id)
            .contextMenu {
                Button { folderName = ""; folderAction = .create(parent: folder.id) } label: { Label("New folder inside", systemImage: "folder.badge.plus") }
                Button { folderName = folder.name; folderAction = .rename(folder.id) } label: { Label("Rename", systemImage: "pencil") }
                if folder.parent != nil {
                    Button { Task { await model.moveFolder(folder.id, into: nil) } } label: { Label("Move to top level", systemImage: "arrow.up.to.line") }
                }
                Divider()
                Button(role: .destructive) { Task { await model.deleteFolder(folder.id) } } label: {
                    Label("Delete folder (keeps what's inside)", systemImage: "trash")
                }
            }
    }

    private func row(_ s: SmartCollection) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(model.count(s))
            .tag(AppModel.Selection.smart(s))
            .contextMenu {
                if s == .sketches { Button { Task { await model.newSketch() } } label: { Label("New sketch", systemImage: "pencil.tip.crop.circle.badge.plus") } }
            }
    }
}

// MARK: - Library

enum LibraryLayout: String { case grid, list }

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage("library.layout") private var storedLayout = ""
    @State private var confirmDelete = false
    /// The last item clicked in select mode, for ⇧-click ranges on the Mac.
    @State private var anchor: String?

    var body: some View {
        let items = model.visibleItems
        Group {
            if layout == .list { list(items) } else { grid(items) }
        }
        .navigationTitle(model.selecting ? "\(model.picked.count) selected" : title)
        .refreshable { await model.syncNow() }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Picker("Layout", selection: Binding(get: { layout }, set: { storedLayout = $0.rawValue })) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                .pickerStyle(.inline)
            }
            ToolbarItem(placement: .primaryAction) {
                if !items.isEmpty || model.selecting {
                    Button(model.selecting ? "Done" : "Select") { withAnimation(.snappy) { model.selecting.toggle() } }
                        .keyboardShortcut(model.selecting ? .cancelAction : KeyboardShortcut("e", modifiers: [.command, .shift]))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selecting { SelectionBar(items: items, confirmDelete: $confirmDelete).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deletePicked() } }
        } message: {
            Text("They're removed from all your devices.")
        }
        #if os(macOS)
        .onDeleteCommand {
            if model.selecting, !model.picked.isEmpty { confirmDelete = true }
            else if let item = model.selectedItem { model.picked = [item.id]; model.selecting = true; confirmDelete = true }
        }
        .onExitCommand { if model.selecting { withAnimation(.snappy) { model.selecting = false } } }
        #endif
        .animation(.snappy, value: model.selecting)
    }

    private var layout: LibraryLayout {
        if let stored = LibraryLayout(rawValue: storedLayout) { return stored }
        #if os(iOS)
        return sizeClass == .compact ? .list : .grid
        #else
        return .grid
        #endif
    }

    private var deleteQuestion: String {
        model.picked.count == 1 ? "Delete 1 item?" : "Delete \(model.picked.count) items?"
    }

    @ViewBuilder private var header: some View {
        if case .folder(let id) = model.selection, model.searchResults == nil {
            FolderHeader(folderId: id)
            if model.isSketchFolder(id), !model.selecting {
                Button { Task { await model.newSketch(in: id) } } label: { Label("New sketch here", systemImage: "pencil.tip.crop.circle.badge.plus") }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        if case .smart(.sketches) = model.selection, model.searchResults == nil, !model.selecting { SketchesHeader() }
        if case .unfiled = model.selection, !model.visibleItems.isEmpty, !model.selecting {
            Button { Task { await model.tidyUp() } } label: { Label("Tidy up: file everything", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)
        }
    }

    private func grid(_ items: [Item]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding([.horizontal, .top], 16)
            }
            if items.isEmpty && model.clipResults.isEmpty {
                emptyState.padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)], spacing: 14) {
                    ForEach(items) { item in
                        Button { tap(item, in: items) } label: { ItemCard(item: item) }
                            .buttonStyle(.plain)
                            .overlay {
                                if model.picked.contains(item.id) || (!model.selecting && model.selectedItemID == item.id) {
                                    RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: model.picked.contains(item.id) ? 3 : 2)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if model.selecting { PickMark(on: model.picked.contains(item.id)).padding(10) }
                            }
                            .contextMenu { ItemMenu(item: item) }
                            .draggable(item.id) { ItemCard(item: item).frame(width: 220).opacity(0.9) }
                    }
                }
                .padding(16)
                .animation(.spring(duration: 0.35), value: items.count)
                if !model.clipResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From your clipboard").font(.headline).padding(.bottom, 4)
                        ClipSearchRows()
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding([.horizontal, .bottom], 16)
                }
            }
        }
    }

    private func list(_ items: [Item]) -> some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            if items.isEmpty && model.clipResults.isEmpty {
                emptyState.padding(.top, 60).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                Button { tap(item, in: items) } label: {
                    HStack(spacing: 12) {
                        if model.selecting { PickMark(on: model.picked.contains(item.id)) }
                        ItemRow(item: item)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(model.picked.contains(item.id) || (!model.selecting && model.selectedItemID == item.id) ? Color.accentColor.opacity(0.14) : nil)
                .contextMenu { ItemMenu(item: item) }
                .draggable(item.id)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { Task { await model.delete(item) } } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    Button { Task { await model.togglePin(item) } } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
                        .tint(.orange)
                }
            }
            if !model.clipResults.isEmpty {
                Section("From your clipboard") { ClipSearchRows() }
            }
        }
        .listStyle(.plain)
        .animation(.spring(duration: 0.35), value: items.count)
    }

    /// Opens the item, or in select mode adds it to (or takes it out of) the selection. On the Mac,
    /// ⌘-click and ⇧-click select without entering select mode first, like Finder.
    private func tap(_ item: Item, in items: [Item]) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor, let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            if !model.selecting { model.selecting = true }
            for i in min(a, b)...max(a, b) { model.picked.insert(items[i].id) }
            return
        }
        if flags.contains(.command) {
            if !model.selecting {
                model.selecting = true
                if let current = model.selectedItemID, current != item.id { model.picked.insert(current) }
            }
            model.togglePicked(item.id)
            anchor = item.id
            return
        }
        #endif
        if model.selecting {
            model.togglePicked(item.id)
            anchor = item.id
        } else {
            model.selectedItemID = item.id
            anchor = item.id
        }
    }

    private var title: String {
        if model.searchResults != nil { return "Results" }
        switch model.selection {
        case .smart(let s): return s.title
        case .collection(let id): return model.collections.first { $0.id == id }?.name ?? "Collection"
        case .source(let s): return ItemStyle.sourceLabel(s)
        case .folder(let id): return model.folders.first { $0.id == id }?.name ?? "Folder"
        case .unfiled: return "Unfiled"
        case .graph: return "Connections"
        case .importer: return "Import"
        case .clipboard: return "Clipboard"
        case nil: return "Trove"
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.searchResults != nil {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, or search by meaning, like “that pasta place”.")
        } else {
            EmptyState(symbol: "tray", title: "Nothing here yet", message: "Share things to Trove, drop files here, or tap + to capture.")
        }
    }
}

/// The round checkmark on a card or row in select mode.
struct PickMark: View {
    let on: Bool
    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(on ? Color.white : Color.secondary, on ? Color.accentColor : Color.clear)
            .background(Circle().fill(.background.opacity(on ? 0 : 0.8)))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// What you can do to the picked items: shown at the bottom in select mode.
struct SelectionBar: View {
    let items: [Item]
    @Binding var confirmDelete: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let allPicked = !items.isEmpty && items.allSatisfy { model.picked.contains($0.id) }
        let none = model.picked.isEmpty
        HStack(spacing: 6) {
            Button(allPicked ? "Select none" : "Select all") {
                if allPicked { model.picked = [] } else { model.picked = Set(items.map(\.id)) }
            }
            .keyboardShortcut("a", modifiers: .command)
            Spacer(minLength: 8)
            Menu {
                FolderPicker(current: nil) { folder in Task { await model.movePicked(to: folder) } }
            } label: { Label("Move", systemImage: "folder") }
            .disabled(none)
            if !model.collections.isEmpty {
                Menu {
                    ForEach(model.collections) { c in
                        Button { Task { await model.addPicked(to: c.id) } } label: { Label(c.name, systemImage: c.symbol) }
                    }
                } label: { Label("Collection", systemImage: "square.stack") }
                .disabled(none)
            }
            let allPinned = !none && model.items.filter { model.picked.contains($0.id) }.allSatisfy(\.isPinned)
            Button { Task { await model.pinPicked(!allPinned) } } label: { Label(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "pin.slash" : "pin") }
                .disabled(none)
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(none)
                .tint(.red)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glass(cornerRadius: 26)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// "No folder" plus every folder, indented: for Move menus.
struct FolderPicker: View {
    let current: String?
    let pick: (String?) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { pick(nil) } label: { Label("No folder", systemImage: "tray") }
        Divider()
        ForEach(model.folderEntries) { entry in
            Button { pick(entry.folder.id) } label: {
                Label(entry.indentedName, systemImage: current == entry.folder.id ? "checkmark" : "folder")
            }
        }
    }
}

/// A compact row for the list layout (the iPhone's default).
struct ItemRow: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item, square: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.body.weight(.semibold)).lineLimit(2)
                if model.searchResults != nil, let found = model.searchSnippets[item.id] {
                    Text(SearchSnippetText.attributed(found, kind: item.kind)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                } else if let snippet = ItemCard.snippet(item) {
                    Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 5) {
                    Image(systemName: ItemStyle.symbol(for: item)).foregroundStyle(ItemStyle.tint(for: item))
                    Text(ItemCard.subtitle(item)).lineLimit(1)
                    if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                    if item.hasConflicts { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct ItemMenu: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { Task { await model.copy([item]) } } label: { Label("Copy", systemImage: "doc.on.doc") }
        if item.kind != .sketch, let file = item.attachments.first {
            Button { model.openFile(item, file) } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
            if FilePrinter.isPrintable(file) {
                Menu { FilePrintItems(item: item, attachment: file) } label: { Label("Print", systemImage: "printer") }
            }
        }
        Button { Task { await model.togglePin(item) } } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        if item.kind == .link || item.category == .article {
            Button { Task { await model.markRead(item) } } label: {
                Label(item.readAt == nil ? "Mark as read" : "Mark as unread", systemImage: "checkmark.circle")
            }
        }
        if let url = item.url {
            Button { Pasteboard.copy(url.absoluteString) } label: { Label("Copy link", systemImage: "doc.on.doc") }
            Link(destination: url) { Label("Open link", systemImage: "safari") }
        }
        if item.watchableURL != nil {
            Button { Task { await model.setTracking(item, item.priceWatch == nil) } } label: {
                Label(item.priceWatch == nil ? "Track price drops" : "Stop tracking price",
                      systemImage: item.priceWatch == nil ? "bell.badge" : "bell.slash")
            }
        }
        if item.kind == .note && !Notes.isDaily(item) {
            let isTemplate = item.tags.contains(Notes.templateTag)
            Button { Task { await model.setTemplate(item, !isTemplate) } } label: {
                Label(isTemplate ? "Stop using as template" : "Use as template", systemImage: isTemplate ? "doc.badge.ellipsis" : "doc.badge.plus")
            }
        }
        if item.kind == .note {
            Button { Task { await model.publish(item) } } label: {
                Label(item.published == nil ? "Publish to link" : "Update public page", systemImage: "globe")
            }
            if let link = item.published {
                Button { Pasteboard.copy(link.url.absoluteString) } label: { Label("Copy public link", systemImage: "link") }
                Button { Task { await model.unpublish(item) } } label: { Label("Remove public link", systemImage: "eye.slash") }
            }
        }
        Menu {
            FolderPicker(current: item.folder) { folder in Task { await model.move(item.id, to: folder) } }
        } label: { Label("Move to folder", systemImage: "folder") }
        if !model.collections.isEmpty {
            Menu("Collections") {
                ForEach(model.collections) { c in
                    Button { Task { await model.toggle(item, in: c.id) } } label: {
                        Label(c.name, systemImage: item.collections.contains(c.id) ? "checkmark" : c.symbol)
                    }
                }
            }
        }
        #if os(macOS)
        Button { Task { try? await AppleNotesBridge.save(item) } } label: { Label("Save to Apple Notes", systemImage: "note.text.badge.plus") }
        #endif
        Divider()
        if !model.selecting {
            Button { model.selecting = true; model.picked = [item.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        }
        Button(role: .destructive) { Task { await model.delete(item) } } label: { Label("Delete", systemImage: "trash") }
    }
}

@MainActor
enum DropHandler {
    /// Files are imported together (so one drop is one import run); links and text are captured.
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        Task { @MainActor in
            var files: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = await loadFile(provider) { files.append(url) }
                } else if provider.canLoadObject(ofClass: URL.self) {
                    if let url = await loadURL(provider) { await model.capture(url.absoluteString) }
                } else if provider.canLoadObject(ofClass: String.self) {
                    // A card or folder dragged inside the app carries its id; folders handle those.
                    if let text = await loadString(provider), !model.items.contains(where: { $0.id == text }), !model.folders.contains(where: { $0.id == text }) {
                        await model.capture(text)
                    }
                }
            }
            guard !files.isEmpty else { return }
            model.selection = .importer
            await model.importFiles(files)
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { value, _ in done.resume(returning: value) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: String.self) { value, _ in done.resume(returning: value) }
        }
    }

    /// On the Mac a dropped file is its real path. On iOS the system hands over a temporary copy that
    /// disappears after the callback, so it's copied somewhere that lasts until the import is done.
    private static func loadFile(_ provider: NSItemProvider) async -> URL? {
        #if os(macOS)
        return await loadURL(provider)
        #else
        let suggested = provider.suggestedName
        return await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
                let copy = dir.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: url, to: copy)
                done.resume(returning: FileManager.default.fileExists(atPath: copy.path) ? copy : nil)
            }
        }
        #endif
    }
}

// MARK: - Folders

enum FolderStyle {
    /// Same palette and hashing as the website (web/public/graph.js), so a folder has one colour everywhere.
    static let palette: [Color] = [.init(hex: 0xFF9F43), .init(hex: 0xFF4F8B), .init(hex: 0xA55EEA), .init(hex: 0x54A0FF),
                                   .init(hex: 0x1DD1A1), .init(hex: 0xFECA57), .init(hex: 0xFF6B6B), .init(hex: 0x48DBFB)]

    static func color(for topFolderId: String?) -> Color {
        guard let id = topFolderId else { return .secondary }
        var hash: UInt32 = 0
        for scalar in id.unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Breadcrumbs and subfolders at the top of a folder.
struct FolderHeader: View {
    let folderId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let path = model.folderPath(folderId)
        let children = model.folders.filter { $0.parent == folderId }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 12) {
            if path.count > 1 {
                HStack(spacing: 4) {
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, folder in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(folder.name) { model.selection = .folder(folder.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            if !children.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(children) { child in
                        Button { model.selection = .folder(child.id) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(FolderStyle.color(for: path.first?.id))
                                Text(child.name).lineLimit(1)
                                Spacer()
                                Text("\(model.folderCount(child.id))").foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(12)
                            .card(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)
                        .dropDestination(for: String.self) { ids, _ in
                            Task { for id in ids where model.items.contains(where: { $0.id == id }) { await model.move(id, to: child.id) } }
                            return true
                        }
                    }
                }
            }
        }
    }
}

/// The top of Sketches: a big way in to drawing, and its folders (drop sketches on them).
struct SketchesHeader: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { Task { await model.newSketch() } } label: {
                HStack(spacing: 14) {
                    Image(systemName: "pencil.tip.crop.circle.badge.plus").font(.system(size: 34)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New sketch").font(.headline)
                        Text("Pens, highlighter, shapes, text and pictures, on pages or an endless canvas.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 16)
            }
            .buttonStyle(.plain)
            let top = model.sketchesFolder
            let folders = model.folders.filter { top != nil && $0.parent == top?.id }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(folders) { folder in
                    Button { model.selection = .folder(folder.id) } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(FolderStyle.color(for: top?.id))
                            Text(folder.name).lineLimit(1)
                            Spacer()
                            Text("\(model.folderCount(folder.id))").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(12)
                        .card(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { ids, _ in
                        Task { for id in ids where model.items.contains(where: { $0.id == id }) { await model.move(id, to: folder.id) } }
                        return true
                    }
                }
                Button { name = ""; naming = true } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("New folder").lineLimit(1)
                        Spacer()
                    }
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
        }
        .alert("New folder in Sketches", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { let n = name; Task { if let id = await model.createSketchFolder(n) { model.selection = .folder(id) } } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension View {
    /// A sidebar section's button, centred over the rows' count pills instead of out at the edge.
    func sidebarHeaderButton() -> some View {
        #if os(macOS)
        frame(width: 24).padding(.trailing, 9)
        #else
        self
        #endif
    }
}
