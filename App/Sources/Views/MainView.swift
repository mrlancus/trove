import SwiftUI
import TroveCore
import UniformTypeIdentifiers

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
    @State private var showImporter = false
    @State private var showAsk = false
    @State private var showSettings = false
    @State private var showClipboard = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 520)
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search everything… try tag:recipe or is:pinned")
                .toolbar { toolbar }
        } detail: {
            if let item = model.selectedItem {
                ItemDetailView(item: item).id(item.id)
            } else {
                EmptyState(symbol: "sparkles.rectangle.stack", title: "Pick something", message: "Or press ⌘N for a note, or paste a link into Capture.")
            }
        }
        .sheet(isPresented: $model.showCapture) { CaptureView().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showAsk) { AskView() }
        .sheet(isPresented: $showClipboard) { ClipboardScreen() }
        #if os(iOS)
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        #endif
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls) } }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            DropHandler.handle(providers, model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showCapture = true } label: { Label("Capture", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu {
                Button { Task { await model.newNote() } } label: { Label("New note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                Button { showImporter = true } label: { Label("Import files…", systemImage: "square.and.arrow.down") }
                VoiceNoteButton()
                #if os(iOS)
                ScanDocumentButton()
                #endif
            } label: { Label("Add", systemImage: "ellipsis.circle") }
            Button { showAsk = true } label: { Label("Ask Trove", systemImage: "sparkles") }
                .keyboardShortcut("j", modifiers: .command)
            Button { showClipboard = true } label: { Label("Clipboard", systemImage: "doc.on.clipboard") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Clipboard history (⌥Space from anywhere on the Mac)")
            SyncIndicator()
        }
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
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @State private var newCollection = ""
    @State private var addingCollection = false

    private let primary: [SmartCollection] = [.recent, .pinned, .toRead, .notes]
    private let smart: [SmartCollection] = [.recipes, .places, .thingsToBuy, .events, .videos, .quotes, .receipts, .handwriting, .needsAttention]

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                ForEach(primary) { s in row(s) }
            }
            Section("Smart Collections") {
                ForEach(smart.filter { model.count($0) > 0 || $0 == .recipes || $0 == .places }) { s in row(s) }
            }
            Section {
                ForEach(model.collections) { c in
                    Label(c.name, systemImage: c.symbol)
                        .foregroundStyle(Color.trove(c.color))
                        .badge(model.items.filter { $0.collections.contains(c.id) }.count)
                        .tag(AppModel.Selection.collection(c.id))
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button { addingCollection = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                }
            }
            let sources = Set(model.items.map(\.source)).subtracting([.app, .share]).sorted { $0.rawValue < $1.rawValue }
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources, id: \.self) { s in
                        Label(ItemStyle.sourceLabel(s), systemImage: ItemStyle.sourceSymbol(s)).tag(AppModel.Selection.source(s))
                    }
                }
            }
        }
        .navigationTitle("Trove")
        .toolbar {
            ToolbarItem {
                #if os(macOS)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
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
        .onChange(of: model.selection) { model.searchText = "" }
    }

    private func row(_ s: SmartCollection) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(model.count(s))
            .tag(AppModel.Selection.smart(s))
    }
}

// MARK: - Library grid

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.visibleItems
        ScrollView {
            if items.isEmpty {
                emptyState.padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)], spacing: 14) {
                    ForEach(items) { item in
                        Button { model.selectedItemID = item.id } label: { ItemCard(item: item) }
                            .buttonStyle(.plain)
                            .overlay {
                                if model.selectedItemID == item.id {
                                    RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: 2)
                                }
                            }
                            .contextMenu { ItemMenu(item: item) }
                    }
                }
                .padding(16)
                .animation(.spring(duration: 0.35), value: items.map(\.id))
            }
        }
        .navigationTitle(title)
        .refreshable { await model.syncNow() }
    }

    private var title: String {
        if model.searchResults != nil { return "Results" }
        switch model.selection {
        case .smart(let s): return s.title
        case .collection(let id): return model.collections.first { $0.id == id }?.name ?? "Collection"
        case .source(let s): return ItemStyle.sourceLabel(s)
        case nil: return "Trove"
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.searchResults != nil {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, or search by meaning, like “that pasta place”.")
        } else {
            EmptyState(symbol: "tray", title: "Nothing here yet", message: "Share things to Trove, drop files here, or press ⌘⇧N to capture.")
        }
    }
}

struct ItemMenu: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
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
        if item.kind == .note {
            Button { Task { await model.publish(item) } } label: {
                Label(item.published == nil ? "Publish to link" : "Update public page", systemImage: "globe")
            }
            if let link = item.published {
                Button { Pasteboard.copy(link.url.absoluteString) } label: { Label("Copy public link", systemImage: "link") }
                Button { Task { await model.unpublish(item) } } label: { Label("Remove public link", systemImage: "eye.slash") }
            }
        }
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
        Button { try? AppleNotesBridge.save(item) } label: { Label("Save to Apple Notes", systemImage: "note.text.badge.plus") }
        #endif
        Divider()
        Button(role: .destructive) { Task { await model.delete(item) } } label: { Label("Delete", systemImage: "trash") }
    }
}

enum DropHandler {
    @MainActor
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await model.importFiles([url]) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await model.capture(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in await model.capture(text) }
                }
            }
        }
        return true
    }
}
