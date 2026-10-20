#if os(iOS)
import SwiftUI
import TroveCore

/// A screen pushed on the iPhone's navigation stacks.
enum PhoneRoute: Hashable {
    case list(AppModel.Selection)
    case item(String)
}

/// The iPhone layout: tabs for the library, the clipboard and search, each a navigation stack where
/// tapping a row opens it. Anything that sets `selectedItemID` (a tap, a [[link]], a widget, a new
/// note) pushes that item onto the current tab.
struct PhoneRootView: View {
    @Binding var showSettings: Bool
    @Binding var showClipboard: Bool
    @Environment(AppModel.self) private var model
    @State private var tab = PhoneTab.library
    @State private var clipState = ClipPaletteState()
    @State private var libraryPath: [PhoneRoute] = []
    @State private var searchPath: [PhoneRoute] = []

    enum PhoneTab: Hashable { case library, clipboard, search }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Library", systemImage: "square.grid.2x2", value: PhoneTab.library) {
                NavigationStack(path: $libraryPath) {
                    SidebarView(showSettings: $showSettings, onPick: { selection in
                        model.selection = selection
                        libraryPath.append(.list(selection))
                    })
                    .toolbar { PhoneAddButtons() }
                    .navigationDestination(for: PhoneRoute.self) { destination($0) }
                }
            }
            Tab("Clipboard", systemImage: "doc.on.clipboard", value: PhoneTab.clipboard) {
                NavigationStack {
                    ClipsView(style: .list, state: clipState, store: model.clipboard, thisDevice: model.config?.deviceId,
                              activate: { entry, transform in copy(entry, transform) },
                              saveToLibrary: { model.saveClip($0) })
                        .navigationTitle("Clipboard")
                }
                .task { await model.clipboard.reload() }
            }
            .badge(model.clipboard.ephemeral.count)
            Tab(value: PhoneTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    PhoneSearch()
                        .navigationDestination(for: PhoneRoute.self) { destination($0) }
                }
            }
        }
        .onChange(of: model.selectedItemID) { _, id in
            guard let id else { return }
            if tab == .clipboard { tab = .library }
            if tab == .search { open(id, on: &searchPath) } else { open(id, on: &libraryPath) }
        }
        .onChange(of: libraryPath) { _, path in if tab == .library { follow(path) } }
        .onChange(of: searchPath) { _, path in if tab == .search { follow(path) } }
        .onChange(of: tab) { old, new in
            if old == .search { model.searchText = "" }
            model.selecting = false
            follow(new == .search ? searchPath : libraryPath)
        }
    }

    @ViewBuilder private func destination(_ route: PhoneRoute) -> some View {
        switch route {
        case .list(.graph): GraphScreen()
        case .list(.importer): ImportView()
        case .list(let selection):
            LibraryView()
                .onAppear { if model.selection != selection { model.selection = selection } }
                .toolbar { PhoneAddButtons() }
        case .item(let id):
            if let item = model.items.first(where: { $0.id == id }) {
                ItemDetailView(item: item).id(id).navigationBarTitleDisplayMode(.inline)
            } else {
                EmptyState(symbol: "questionmark.folder", title: "Not here any more", message: "It may have been deleted on another device.")
            }
        }
    }

    private func open(_ id: String, on path: inout [PhoneRoute]) {
        if path.last == .item(id) { return }
        path.append(.item(id))
    }

    /// Keeps `selectedItemID` in step with the item on screen (or none), so going back and tapping
    /// the same item again opens it again.
    private func follow(_ path: [PhoneRoute]) {
        if case .item(let id) = path.last {
            if model.selectedItemID != id { model.selectedItemID = id }
        } else if model.selectedItemID != nil {
            model.selectedItemID = nil
        }
        if case .list(let selection) = path.last, model.selection != selection { model.selection = selection }
    }

    private func copy(_ entry: ClipEntry, _ transform: ClipTransform?) {
        Task {
            switch entry {
            case .clip(let clip): await model.clipboard.copy(clip, transform: transform)
            case .sensitive(let e): model.clipboard.copy(e)
            }
            model.toast = "Copied"
        }
    }
}

/// Capture (+) and the Add menu, in the iPhone's navigation bars.
struct PhoneAddButtons: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu { AddMenu() } label: { Label("Add", systemImage: "ellipsis.circle") }
            Button { model.showCapture = true } label: { Label("Capture", systemImage: "plus.circle.fill") }
        }
    }
}

/// The Search tab: results as you type, plus quick filters when the field is empty.
struct PhoneSearch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showAsk) private var showAsk

    var body: some View {
        @Bindable var model = model
        List {
            if model.searchText.isEmpty {
                Section("Try") {
                    ForEach(["is:pinned", "is:unread", "type:note", "from:goodnotes"], id: \.self) { example in
                        Button(example) { model.searchText = example }
                    }
                    Button { showAsk() } label: { Label("Ask Trove a question", systemImage: "sparkles") }
                }
                Section("Recent") {
                    ForEach(model.items.prefix(8)) { item in
                        Button { model.selectedItemID = item.id } label: { ItemRow(item: item) }.buttonStyle(.plain)
                    }
                }
            } else if let results = model.searchResults {
                if results.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, or search by meaning, like “that pasta place”.")
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { item in
                    Button { model.selectedItemID = item.id } label: { ItemRow(item: item) }
                        .buttonStyle(.plain)
                        .swipeActions { Button(role: .destructive) { Task { await model.delete(item) } } label: { Label("Delete", systemImage: "trash") } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $model.searchText, prompt: "Everything you saved")
    }
}
#endif
