import Foundation
import Observation
import SwiftUI
import TroveCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Main-actor state for the UI. Owns the vault, library, sync loop and enrichment.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case loading, onboarding, ready, failed(String) }

    enum Selection: Hashable {
        case smart(SmartCollection)
        case collection(String)
        case source(ItemSource)
        case folder(String)
        case unfiled
        case graph
        case importer
        case clipboard
    }

    /// A folder and its subfolders, for the sidebar's outline.
    struct FolderNode: Identifiable, Hashable {
        let folder: Folder
        var children: [FolderNode]?
        var id: String { folder.id }
    }

    /// A folder with how deep it sits, for flat pickers ("Move to folder").
    struct FolderEntry: Identifiable, Hashable {
        let folder: Folder
        let depth: Int
        var id: String { folder.id }
        var indentedName: String { String(repeating: "    ", count: depth) + folder.name }
    }

    /// A running or finished import, which the Import screen animates.
    struct ImportRun: Equatable {
        var total: Int
        var done = 0
        var added = 0
        var current: String?
        var finished = false
        /// What "Show them" opens (the clipboard for a Paste import).
        var destination: Selection = .source(.import)
        /// "files" or "clips", for the counts.
        var unit = "files"
        /// The latest things that came in, newest first.
        var recent: [Arrival] = []

        struct Arrival: Identifiable, Equatable {
            let id = UUID()
            let label: String
        }

        var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    }

    struct SyncStatus: Equatable {
        var syncing = false
        var lastSync: Date?
        var lastError: String?
        var live = false
    }

    // MARK: Published state
    var phase: Phase = .loading
    var items: [Item] = [] { didSet { dataVersion += 1 } }
    var collections: [ItemCollection] = [] { didSet { dataVersion += 1 } }
    var folders: [Folder] = [] { didSet { dataVersion += 1 } }
    /// Bumped when items, folders or collections change: lists and counts worked out from them are
    /// kept until then (each section switch used to filter the whole library a dozen times).
    private(set) var dataVersion = 0
    @ObservationIgnored private var searchVersion = 0
    @ObservationIgnored private var visibleCache: (key: String, items: [Item])?
    @ObservationIgnored private var countsCache: (version: Int, counts: SidebarCounts)?
    /// Wikilinks and hand-made connections between items, rebuilt on every reload.
    var links = Links.Graph()
    var selection: Selection? = .smart(.recent) {
        didSet {
            guard selection != oldValue else { return }
            // Connections wants the whole window: what was open on the right closes.
            if selection == .graph { selectedItemID = nil }
            if selection != .clipboard { selectedClipID = nil }
        }
    }
    var selectedItemID: String?
    /// The clip open in the detail column while the clipboard is showing (Mac and iPad).
    var selectedClipID: String?
    /// Select mode: tapping toggles items into `picked` for the bulk actions bar.
    var selecting = false { didSet { if !selecting { picked = [] } } }
    var picked: Set<String> = []
    var searchText = "" { didSet { if searchText != oldValue { searchNow() } } }
    var searchResults: [Item]? { didSet { searchVersion += 1 } }
    /// Clips matching the search, shown under the library's results.
    private(set) var clipResults: [Clip] = []
    /// How many items the search matched in all, and the matching passage of the first results.
    private(set) var searchTotal = 0
    private(set) var searchSnippets: [String: SearchSnippet] = [:]
    @ObservationIgnored private var searchIndexSaved = ""
    /// This device's search index, copied from the library after each change. Searching it on the
    /// main actor answers every keystroke at once, without waiting behind syncing or file loads.
    @ObservationIgnored private var index = SearchIndex()
    /// What the library and the ink looked like at the last refresh: a sync that brought nothing
    /// new doesn't touch `items` (which would redraw every screen and card).
    @ObservationIgnored private var shownLibraryStamp = ""
    @ObservationIgnored private var shownInkStamp = ""
    var sync = SyncStatus()
    var enriching = false
    var toast: String?
    /// The relay's cloud AI state and this month's use (AppModel+AI.swift); nil without a relay.
    var cloudAIStatus: RelayClient.AIStatus?
    /// Last week's digest was checked this launch (AppModel+AI.swift).
    var digestChecked = false
    /// The relay's AI status was asked for this launch (AppModel+AI.swift).
    @ObservationIgnored var aiStatusChecked = false
    var showCapture = false
    /// The drawing editor, when it's open.
    var inkTarget: InkTarget?
    /// Bumped when ink changes or a sync brings changes, so drawings redraw.
    private(set) var inkRevision = 0
    /// Which items have ink, and on which files ("" = a sketch's own pages).
    private(set) var inkedLayers: [String: Set<String>] = [:]
    /// How many drawing editors are open. While one is, saving and pushing wait longer between
    /// strokes (each save writes the whole vault, each push uses the radio: both cost battery).
    @ObservationIgnored var drawingOpen = 0 {
        didSet {
            if oldValue == 0, drawingOpen > 0 { power.sketchOpened() }
            guard oldValue > 0, drawingOpen == 0 else { return }
            // Closing sends what the batching held back (docs/ROADMAP.md §3.7), then the counters stop.
            if !sketchDeferred { Task { await flushPushes(); power.sketchClosed() } }
            guard sketchDeferred else { return }
            sketchDeferred = false
            Task { await catchUpAfterSketch(); power.sketchClosed() }
        }
    }
    /// On iPhone and iPad a sketch fills the screen. While one is open, work nobody can see waits
    /// until it closes (it heated the iPad and used the battery while drawing): the library lists,
    /// search by meaning, Spotlight, the widget, the clipboard, enrichment (text recognition, AI), the
    /// inbox and price watches. The sketch's ink is still saved and synced (pushed a few seconds
    /// after you pause, others' strokes pulled on a live ping or every couple of minutes).
    var sketchCovers: Bool {
        #if os(iOS)
        return drawingOpen > 0
        #else
        return false
        #endif
    }
    /// Something waited for the sketch to close.
    @ObservationIgnored private var sketchDeferred = false
    @ObservationIgnored private var inkChangeTask: Task<Void, Never>?
    var config: VaultConfig? { vault.config }

    // MARK: Services
    let vault = VaultStore()
    private(set) var library: Library?
    private(set) var enrichment: EnrichmentService?
    let semantic = SemanticIndex()
    let clipboard = ClipboardStore()
    private var clipboardWatcher: ClipboardWatcher?
    #if os(macOS)
    private(set) var clipboardPalette: ClipboardPaletteController?
    #endif
    private var syncTask: Task<Void, Never>?
    /// A sync was asked for while one was running (a live ping, an edit): run once more after it.
    private var syncAgain = false
    /// Whether the last sync round pulled, pushed or imported anything (the loop backs off when not).
    private var lastSyncChanged = true
    #if os(macOS)
    private var syncBackoff = SyncBackoff(base: 30, idleMax: 300)
    #else
    private var syncBackoff = SyncBackoff(base: 60, idleMax: 300)
    #endif
    private var pushTask: Task<Void, Never>?
    /// Battery (docs/ROADMAP.md §3.7): the device's power state, Settings → Battery and its counters.
    let power = PowerMonitor()
    /// When local edits go out (batched while sketching: `PowerPolicy.pushRule`).
    @ObservationIgnored private var pusher = PushCoalescer(rule: PowerPolicy(PowerState()).pushRule)
    /// When the engine last reported a change (a local edit, if it left something unsent).
    @ObservationIgnored private var lastEngineChange = 0.0
    /// Live pings close together share one sync (`PowerPolicy.pingWindow`).
    @ObservationIgnored private var pings = Throttle(interval: 0)
    /// A ping that waits for the sketch to close (a very hot device).
    @ObservationIgnored private var pingHeld = false
    /// The inbox is fetched on a ping, on becoming active or every 15 minutes; price watches every 6 hours.
    @ObservationIgnored private var inboxWanted = true
    @ObservationIgnored private var lastInbox = 0.0
    @ObservationIgnored private var lastPriceWatches = 0.0
    @ObservationIgnored private var searchSaveTask: Task<Void, Never>?
    @ObservationIgnored private var widgetThrottle = Throttle(interval: PowerPolicy.widgetEvery)
    @ObservationIgnored private var widgetShown: SharedConfig.WidgetSnapshot?
    @ObservationIgnored private var widgetTask: Task<Void, Never>?
    private var mirroring = false
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var live: LiveConnection?

    // MARK: Lifecycle

    func start() async {
        #if os(macOS)
        Updater.shared.start()
        #endif
        guard vault.isSetUp else { phase = .onboarding; return }
        do {
            try await openLibrary()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func openLibrary() async throws {
        let signpost = Perf.begin("Open library")
        defer { Perf.end("Open library", signpost) }
        let engine = try vault.makeEngine()
        let library = Library(engine: engine)
        self.library = library
        // The search index from last time: only what changed since gets indexed again.
        let searchURL = vault.searchIndexURL
        if let saved = await Task.detached(priority: .userInitiated, operation: { VaultStore.read(SearchIndex.Snapshot.self, from: searchURL) }).value {
            await library.restoreSearch(saved)
        }
        await semantic.useCache(vault.semanticURL)
        let config = vault.config!
        enrichment = EnrichmentService(library: library, deviceId: config.deviceId, relay: vault.relayClient, cloudEnabled: config.cloudAI)
        vault.publishCaptureSettings()
        await engine.observe { Task { @MainActor [weak self] in self?.scheduleSave() } }
        await reload()
        await clipboard.attach(library)
        startClipboard()
        startSyncLoop()
        connectLive()
    }

    // MARK: Clipboard

    private func startClipboard() {
        if clipboardWatcher == nil {
            let watcher = ClipboardWatcher(store: clipboard)
            watcher.start()
            clipboardWatcher = watcher
        }
        #if os(macOS)
        if clipboardPalette == nil {
            let palette = ClipboardPaletteController(store: clipboard, thisDevice: { [weak self] in self?.config?.deviceId },
                                                     saveToLibrary: { [weak self] clip in self?.saveClip(clip) })
            palette.installHotKey()
            clipboardPalette = palette
        }
        #endif
    }

    /// Turns a clip into a library item.
    func saveClip(_ clip: Clip) {
        Task {
            if await clipboard.saveToLibrary(clip) != nil {
                toast = "Saved to Trove"
                await reload()
            }
        }
    }

    func createVault(useICloud: Bool, pickedFolder: URL?, encrypted: Bool) async {
        do {
            var folder: URL?
            #if os(macOS)
            if useICloud { folder = VaultStore.macICloudFolder }
            #endif
            if let pickedFolder { folder = pickedFolder }
            try vault.createVault(folder: folder, encrypted: encrypted, picked: pickedFolder != nil)
            try await openLibrary()
            phase = .ready
            await library?.addNote(title: "Welcome to Trove", body: Self.welcomeNote)
            await syncNow()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func join(_ payload: PairingPayload, useICloud: Bool, pickedFolder: URL?) async {
        do {
            var folder: URL?
            #if os(macOS)
            if useICloud { folder = VaultStore.macICloudFolder }
            #endif
            if let pickedFolder { folder = pickedFolder }
            try await vault.join(payload, folder: folder, picked: pickedFolder != nil)
            try await openLibrary()
            phase = .ready
            await syncNow()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func resetThisDevice() {
        syncTask?.cancel()
        live?.stop()
        vault.reset()
        library = nil
        items = []
        phase = .onboarding
    }

    // MARK: Loading

    func reload() async {
        guard let library else { return }
        let covered = sketchCovers
        if covered { sketchDeferred = true } else { await clipboard.reload() }
        let libraryStamp = await library.stamp(of: ["item", "collection", "folder"])
        // Behind an open sketch the lists, search index, Spotlight and widget catch up when it closes.
        if libraryStamp != shownLibraryStamp, !covered {
            shownLibraryStamp = libraryStamp
            items = await library.items()
            collections = await library.collections()
            folders = await library.folders()
            links = Links.graph(items)
            index = await library.searchIndex()
            index.inked = Set(inkedLayers.keys)
            saveSearchIndexSoon(libraryStamp)
            if !searchText.isEmpty { searchNow() }
            // Search by meaning catches up in the background; keyword search never waits for it.
            let snapshot = self.items, semantic = self.semantic
            let saveCache = policy.unlimited
            Task.detached(priority: .utility) { await semantic.update(snapshot, saveNow: saveCache) }
            publishWidget()
            SpotlightIndexer.index(items)
        }
        await applySharedSettings()
        let inkStamp = await library.stamp(of: ["stroke", "element"])
        if inkStamp != shownInkStamp {
            shownInkStamp = inkStamp
            // Which items have ink reads every stroke in the vault: behind an open sketch, once it closes.
            if !covered {
                inkedLayers = await library.inkedLayers()
                index.inked = Set(inkedLayers.keys)
            }
            inkRevision += 1
        }
    }

    /// The sketch closed: what waited for it (see `sketchCovers`), with a full sync.
    private func catchUpAfterSketch() async {
        guard let library, !sketchCovers else { return }
        inkedLayers = await library.inkedLayers()
        index.inked = Set(inkedLayers.keys)
        inkRevision += 1
        await syncNow()
    }

    // MARK: Drawing

    /// Something drew or erased: views showing ink redraw. (Saving and syncing follow from the engine.)
    /// Strokes come many a second, so the redraw waits for a pause unless `now`.
    func inkChanged(now: Bool = false) {
        inkChangeTask?.cancel()
        // The open sketch shows its own ink; nothing else is on screen to redraw.
        if sketchCovers { sketchDeferred = true; return }
        inkChangeTask = Task { [weak self] in
            if !now {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            self.inkRevision += 1
            if let library = self.library { self.inkedLayers = await library.inkedLayers() }
        }
    }

    /// A new sketch, opened in the editor (filed in `folder` when given).
    func newSketch(in folder: String? = nil) async {
        guard let library else { return }
        let id = await library.addSketch()
        if let folder { await library.move(id, to: folder) }
        await reload()
        selectedItemID = id
        inkTarget = InkTarget(itemId: id, layer: "", title: "Sketch")
    }

    func draw(on item: Item, page: Int = 0) {
        if item.kind == .sketch {
            inkTarget = InkTarget(itemId: item.id, layer: "", title: item.displayTitle, startPage: page)
        } else if let att = item.attachments.first(where: Self.canInk) {
            inkTarget = InkTarget(itemId: item.id, layer: att.id, title: att.name, startPage: page)
        }
    }

    /// Files that can be drawn on: PDFs and images.
    nonisolated static func canInk(_ attachment: Attachment) -> Bool {
        attachment.mime == "application/pdf" || (attachment.mime.hasPrefix("image/") && attachment.mime != "image/svg+xml")
            || attachment.name.lowercased().hasSuffix(".goodnotes")
    }

    var visibleItems: [Item] {
        if let searchResults { return searchResults }
        let key = "\(dataVersion)|\(searchVersion)|\(String(describing: selection))"
        if let visibleCache, visibleCache.key == key { return visibleCache.items }
        let out: [Item]
        switch selection {
        case .smart(let s): out = items.filter(s.contains)
        case .collection(let id): out = items.filter { $0.collections.contains(id) }
        case .source(let src): out = items.filter { $0.sources.contains(src) }
        case .folder(let id): out = items.filter { $0.folder == id }
        case .unfiled: out = unfiledItems
        case .graph, .importer, .clipboard, nil: out = items
        }
        visibleCache = (key, out)
        return out
    }

    /// The sidebar's numbers, worked out once per library change instead of on every draw.
    struct SidebarCounts {
        var smart: [SmartCollection: Int] = [:]
        var collections: [String: Int] = [:]
        var sources: [ItemSource: Int] = [:]
        var unfiled = 0
    }

    var sidebarCounts: SidebarCounts {
        if let countsCache, countsCache.version == dataVersion { return countsCache.counts }
        var c = SidebarCounts()
        for s in SmartCollection.allCases { c.smart[s] = items.filter(s.contains).count }
        let folderIds = Set(folders.map(\.id))
        for item in items {
            for id in item.collections { c.collections[id, default: 0] += 1 }
            for s in Set(item.sources) { c.sources[s, default: 0] += 1 }
            if item.folder.map({ !folderIds.contains($0) }) ?? true { c.unfiled += 1 }
        }
        countsCache = (dataVersion, c)
        return c
    }

    var selectedItem: Item? { selectedItemID.flatMap { id in items.first { $0.id == id } } }

    func count(_ smart: SmartCollection) -> Int { sidebarCounts.smart[smart] ?? 0 }

    // MARK: Folders

    var folderEntries: [FolderEntry] { Folder.tree(folders).map { FolderEntry(folder: $0.folder, depth: $0.depth) } }

    var folderNodes: [FolderNode] {
        let ids = Set(folders.map(\.id))
        let byParent = Dictionary(grouping: folders) { f in f.parent.flatMap { ids.contains($0) && $0 != f.id ? $0 : nil } ?? "" }
        var seen: Set<String> = []
        func nodes(_ key: String) -> [FolderNode] {
            (byParent[key] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .filter { seen.insert($0.id).inserted }
                .map { f in
                    let kids = nodes(f.id)
                    return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
                }
        }
        return nodes("")
    }

    var unfiledItems: [Item] {
        let ids = Set(folders.map(\.id))
        return items.filter { $0.folder.map { !ids.contains($0) } ?? true }
    }

    /// Items in a folder and everything inside it.
    func folderCount(_ id: String) -> Int {
        let parent = Dictionary(folders.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        return items.filter { item in
            var current = item.folder, hops = 0
            while let c = current, hops < 32 { if c == id { return true }; current = parent[c] ?? nil; hops += 1 }
            return false
        }.count
    }

    func folderPath(_ id: String?) -> [Folder] { id.map { Folder.path(of: $0, in: folders) } ?? [] }

    /// The top "Sketches" folder new sketches are filed in.
    var sketchesFolder: Folder? { folders.first { $0.parent == nil && $0.name == "Sketches" } }

    /// Whether a folder is inside Sketches (so it offers "New sketch here").
    func isSketchFolder(_ id: String) -> Bool { sketchesFolder.map { folderPath(id).first?.id == $0.id } ?? false }

    /// A folder inside Sketches (making Sketches itself if there isn't one yet).
    @discardableResult
    func createSketchFolder(_ name: String) async -> String? {
        let top: String?
        if let existing = sketchesFolder { top = existing.id } else { top = await createFolder("Sketches") }
        return await createFolder(name, in: top)
    }

    @discardableResult
    func createFolder(_ name: String, in parent: String? = nil) async -> String? {
        guard let library, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let id = await library.createFolder(name, in: parent)
        await reload()
        return id
    }

    func renameFolder(_ id: String, to name: String) async { await library?.renameFolder(id, to: name); await reload() }

    func deleteFolder(_ id: String) async {
        let parent = folders.first { $0.id == id }?.parent
        await library?.deleteFolder(id)
        if selection == .folder(id) { selection = parent.map { .folder($0) } ?? .smart(.recent) }
        await reload()
    }

    func moveFolder(_ id: String, into parent: String?) async { await library?.moveFolder(id, into: parent); await reload() }

    func move(_ itemId: String, to folder: String?) async {
        await library?.move(itemId, to: folder)
        await reload()
        toast = folder.flatMap { f in folders.first { $0.id == f }?.name }.map { "Moved to \($0)" } ?? "Removed from its folder"
    }

    func tidyUp() async {
        guard let library else { return }
        let n = await library.tidyUp()
        await reload()
        toast = n == 0 ? "Everything is already filed" : "Filed \(n) thing\(n == 1 ? "" : "s") into folders"
    }

    // MARK: Versions and connections

    func replaceFile(_ item: Item, with url: URL) async {
        guard let library else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { toast = "Couldn't read that file"; return }
        let name = url.lastPathComponent
        do {
            try await library.replaceFile(item.id, data: data, name: name, mime: FileImport.mime(forExtension: url.pathExtension))
            toast = "Saved as a new version"
        } catch {
            toast = "Couldn't save: \(error.localizedDescription)"
        }
        await reload()
    }

    func restore(_ item: Item, _ version: FileVersion) async {
        await library?.restoreFileVersion(item.id, version)
        await reload()
        toast = "Restored. The file you had is kept as a version too."
    }

    func textVersions(_ item: Item) async -> [TextVersion] { await library?.textVersions(item.id) ?? [] }

    /// A decrypted copy of an attachment in the temporary folder, for Quick Look and sharing.
    func temporaryFile(_ attachment: Attachment) async -> URL? {
        guard let data = try? await library?.attachmentData(attachment) else { toast = "Couldn't open \(attachment.name)"; return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLook/\(attachment.id.prefix(12))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(attachment.name.isEmpty ? "file" : attachment.name)
        do { try data.write(to: url, options: .atomic) } catch { toast = "Couldn't open \(attachment.name)"; return nil }
        return url
    }

    func connect(_ a: String, _ b: String) async { await library?.connect(a, b); await reload() }
    func disconnect(_ a: String, _ b: String) async { await library?.disconnect(a, b); await reload() }

    /// Opens the item a `[[wikilink]]` points at, or makes a note with that title.
    func openWikilink(_ title: String) async {
        let key = title.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = Links.titleIndex(items)[key] { selectedItemID = id; return }
        guard let library else { return }
        selectedItemID = await library.addNote(title: title.trimmingCharacters(in: .whitespaces), body: "")
        await reload()
    }

    // MARK: Search

    /// Keyword results straight away, on every keystroke; "search by meaning" is blended in a
    /// moment later when typing pauses.
    private func searchNow() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { searchResults = nil; clipResults = []; return }
        let query = SearchQuery.parse(text)
        showResults(index.searchWithTotal(query), query: query)
        clipResults = clipboard.matches(ClipQuery(text), limit: 8)
        guard query.text.count >= 3 else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let scores = await self.semantic.scores(for: query.text)
            guard !Task.isCancelled, !scores.isEmpty, self.searchText.trimmingCharacters(in: .whitespaces) == text else { return }
            self.showResults(self.index.searchWithTotal(query, semantic: scores), query: query)
        }
    }

    /// Results plus the matching passage (bold words) of the first ones, for the cards and rows.
    private func showResults(_ found: (hits: [SearchIndex.Hit], total: Int), query: SearchQuery) {
        searchTotal = found.total
        var snippets: [String: SearchSnippet] = [:]
        if query.hasWords {
            for hit in found.hits.prefix(60) {
                if let s = index.snippet(for: hit.item.id, query: query) { snippets[hit.item.id] = s }
            }
        }
        searchSnippets = snippets
        searchResults = found.hits.map(\.item)
    }

    /// Saves the search index next to the vault snapshot a little after the library changed.
    /// The whole index is written each time, so it waits for a minute without changes (a few seconds
    /// on the charger) and goes out at once when the app goes to the background.
    private func saveSearchIndexSoon(_ stamp: String, quiet: Double? = nil) {
        guard stamp != searchIndexSaved, let library else { return }
        let wait = quiet ?? (policy.unlimited ? 5 : PowerPolicy.cacheQuiet)
        let url = vault.searchIndexURL
        searchSaveTask?.cancel()
        searchSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.searchIndexSaved = stamp
            let bytes = await Task.detached(priority: .utility) { () -> Int in
                let snapshot = await library.searchSnapshot()
                guard let data = try? JSONEncoder().encode(snapshot) else { return 0 }
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return data.count
            }.value
            self?.power.count { $0.cacheBytes += bytes }
        }
    }

    // MARK: Sync

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait = await self?.syncRound() ?? 60
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// One background round; returns how long to wait before the next (longer while nothing changes
    /// or in Low Power Mode; live pings, edits and coming back still sync at once).
    private func syncRound() async -> Double {
        let policy = self.policy
        // Very hot while sketching: nothing until the sketch closes or the app goes to the background.
        guard let minPoll = policy.minPoll else { return 60 }
        await syncNow()
        let wait = syncBackoff.next(changed: lastSyncChanged, lowPower: policy.saving)
        // While drawing, others' strokes come with a live ping; polling waits longer.
        return max(wait, minPoll)
    }

    /// What the device allows right now (`PowerPolicy`, docs/ROADMAP.md §3.7).
    var policy: PowerPolicy { power.policy(sketching: drawingOpen > 0) }

    private static var clock: Double { Date().timeIntervalSince1970 }

    /// Pulls and pushes. A request that arrives mid-sync (say a live ping because the website just
    /// saved something) runs right after instead of being dropped. Enrichment and the Mac mirror run
    /// after the sync lock is released, so slow OCR never holds up changes from other devices.
    func syncNow() async {
        guard let library else { return }
        if sync.syncing { syncAgain = true; return }
        sync.syncing = true
        let signpost = Perf.begin("Sync")
        var changed = false
        repeat {
            syncAgain = false
            // Behind an open sketch only the vault syncs (its strokes go out, others' come in); the
            // inbox and price watches wait for it to close.
            let light = sketchCovers
            if light { sketchDeferred = true } else { await importLocalInbox() }
            // Checkpoints rewrite the whole vault: on the charger or with no sketch open.
            await library.engine.allowCheckpoints(policy.checkpoints)
            let report = await library.sync()
            if report.wroteCheckpoint != nil { Perf.event("Checkpoint") }
            if report.pulled > 0 || report.pushed > 0 { changed = true }
            if pusher.hasPending, !(await library.engine.hasUnsentChanges) { pusher.pushed(at: Self.clock) }
            power.count { c in
                c.syncRounds += 1
                c.pushes += report.pushed
                c.pulls += report.pulled
            }
            if !light, let client = vault.relayClient, let keys = vault.keys {
                // The inbox and price watches were two more requests every round; now only when due.
                let now = Self.clock
                if inboxWanted || now - lastInbox >= PowerPolicy.inboxEvery {
                    inboxWanted = false
                    lastInbox = now
                    power.count { $0.otherRequests += 1 }
                    let inbox = await InboxSync.run(client: client, keys: keys, library: library)
                    if !inbox.imported.isEmpty { changed = true }
                    if !inbox.imported.isEmpty { toast = "\(inbox.imported.count) new from your inbox" }
                }
                if now - lastPriceWatches >= PowerPolicy.priceWatchesEvery {
                    lastPriceWatches = now
                    power.count { $0.otherRequests += 1 }
                    let watches = await PriceWatchSync.run(client: client, library: library)
                    for drop in watches.drops { await PriceAlerts.notify(drop) }
                    if let drop = watches.drops.first { toast = PriceAlerts.message(drop) }
                }
            }
            sync.lastSync = Date()
            sync.lastError = report.errors.first
            await reload()
            saveNow()
        } while syncAgain
        lastSyncChanged = changed
        Perf.end("Sync", signpost)
        sync.syncing = false
        // Text recognition, meaning vectors, AI and the Mac's mirror: once the sketch closes.
        if sketchCovers { sketchDeferred = true; return }
        await enrichSoon()
        await afterSyncAI()
        await mirrorIfOwner()
    }

    // MARK: Settings that follow you (PROTOCOL.md §8, `settings.app`)

    /// Shared settings without a home of their own on this platform (the Mac's page recording and
    /// updates, seen from an iPhone), so the toggles still show and pass on the right value.
    private var sharedValues: [SharedSetting: Bool] = [:]

    /// A shared setting's value on this device.
    func isOn(_ key: SharedSetting) -> Bool {
        switch key {
        case .clipboardHistory: return clipboard.enabled
        case .holdSensitive: return clipboard.keepSensitive
        case .saveCopiesOnOpen: return clipboard.captureOnOpen
        case .cloudAI: return config?.cloudAI ?? false
        case .recordPlaces: return clipboard.recordPlaces
        #if os(macOS)
        case .recordPages: return sharedValues[key] ?? ClipSourceProbe.recordPages
        case .autoUpdate: return sharedValues[key] ?? Updater.shared.automatic
        #else
        case .recordPages, .autoUpdate: return sharedValues[key] ?? key.standard
        #endif
        }
    }

    /// Changes a setting here at once, then in the vault, so every device follows.
    func setShared(_ key: SharedSetting, _ on: Bool) {
        apply(key, on)
        Task {
            await library?.setSharedSetting(key, on)
            if key == .cloudAI { try? await vault.relayClient?.setAIEnabled(on) }
            pushSoon()
        }
    }

    private func apply(_ key: SharedSetting, _ on: Bool) {
        sharedValues[key] = on
        switch key {
        case .clipboardHistory: if clipboard.enabled != on { clipboard.enabled = on }
        case .holdSensitive: if clipboard.keepSensitive != on { clipboard.keepSensitive = on }
        case .saveCopiesOnOpen: if clipboard.captureOnOpen != on { clipboard.captureOnOpen = on }
        case .cloudAI: if config?.cloudAI != on { updateConfig { $0.cloudAI = on } }
        case .recordPlaces: if clipboard.recordPlaces != on { clipboard.recordPlaces = on }
        case .recordPages:
            #if os(macOS)
            ClipSourceProbe.recordPages = on
            #endif
        case .autoUpdate:
            #if os(macOS)
            if Updater.shared.automatic != on { Updater.shared.automatic = on }
            #endif
        }
    }

    /// After loading: take on what other devices set. A value only this device has (changed before
    /// settings synced) is shared the first time, so nobody loses a choice they made.
    private func applySharedSettings() async {
        guard let library else { return }
        let synced = await library.sharedSettings()
        for key in SharedSetting.allCases {
            if let value = synced[key] {
                if isOn(key) != value || sharedValues[key] == nil { apply(key, value) }
            } else if isOn(key) != key.standard {
                await library.setSharedSetting(key, isOn(key))
            }
        }
    }

    /// Pushes local edits a moment after they're made, like the website does. While sketching they're
    /// batched (`PushCoalescer`): out after a real pause or a few minutes of writing, at most once a
    /// minute, and at once when the sketch closes or the app goes to the background.
    private func pushSoon() {
        pusher.rule = policy.pushRule
        guard let due = pusher.dueTime() else { return }
        pushTask?.cancel()
        let wait = max(0, due - Self.clock)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.pusher.rule = self.policy.pushRule
            if self.pusher.isDue(at: Self.clock) { await self.syncNow() } else { self.pushSoon() }
        }
    }

    /// The sketch's page changed: what's waiting goes out as soon as the batching allows.
    func sketchPageChanged() {
        pusher.pageChanged()
        pushSoon()
    }

    /// Sends what the batching held back, and runs a ping that waited (sketch closed, app to the background).
    func flushPushes() async {
        guard pusher.hasPending || pingHeld else { return }
        pingHeld = false
        pushTask?.cancel()
        await syncNow()
    }

    /// Back from the background: the live socket was closed there.
    func becameActive() async {
        #if os(iOS)
        clipboardWatcher?.check()
        #endif
        inboxWanted = true
        if !sync.live { connectLive() }
        await syncNow()
    }

    /// To the background: send what's waiting, write the caches, and close the live socket (its 25 s
    /// keep-alive would otherwise wake the radio for as long as the system lets the app run).
    func enteredBackground() {
        saveNow()
        if let library {
            Task { [weak self] in
                guard let self else { return }
                self.saveSearchIndexSoon(await library.stamp(of: ["item", "collection", "folder"]), quiet: 0)
            }
        }
        let semantic = self.semantic
        Task.detached(priority: .utility) { await semantic.saveNow() }
        Task { await flushPushes() }
        #if os(iOS)
        live?.stop()
        pings.cancel()
        #endif
    }

    private func connectLive() {
        live?.stop()
        guard let url = vault.relayClient?.liveURL else { sync.live = false; return }
        live = LiveConnection(url: url) { [weak self] connected in
            Task { @MainActor in self?.sync.live = connected }
        } onEvent: { [weak self] in
            Task { @MainActor in self?.livePing() }
        }
        live?.start()
    }

    /// Another device saved something. While sketching or saving battery, pings close together share
    /// one sync (a Mac copying to the clipboard mid-sketch used to wake the iPad every time).
    private func livePing() {
        power.count { $0.livePings += 1 }
        inboxWanted = true
        guard let window = policy.pingWindow else { pingHeld = true; return }
        pings.interval = window
        switch pings.request(at: Self.clock) {
        case .now:
            Task { await syncNow() }
        case .after(let delay):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pings.ran(at: Self.clock)
                await self.syncNow()
            }
        case .waiting:
            break
        }
    }

    /// Envelopes the share extension sealed into the App Group when the relay wasn't available.
    private func importLocalInbox() async {
        guard let library, let keys = vault.keys else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: SharedConfig.localInbox, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "trv" {
            guard let data = try? Data(contentsOf: file), let envelope = try? InboxEnvelope.open(data, with: keys) else { continue }
            if (try? await library.importInbox(envelope)) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        lastEngineChange = Self.clock
        let wait: Duration = drawingOpen > 0 ? .seconds(4) : .seconds(1)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.saveNow()
            await self?.reload()
            guard let self, let library = self.library else { return }
            if await library.engine.hasUnsentChanges {
                self.pusher.edited(at: self.lastEngineChange)
                self.pushSoon()
            }
        }
    }

    func saveNow() {
        guard let library else { return }
        power.count { $0.saves += 1 }
        let url = vault.snapshotURL
        let database = vault.database
        // Only what changed since the last save is written (SQLite), off the main thread.
        Task.detached(priority: .utility) {
            await SnapshotWriter.shared.save(library.engine, database: database, legacyURL: url)
        }
    }

    // MARK: Enrichment

    /// After a sync, within what the power state allows (`PowerPolicy.enrichment`): on battery only
    /// what this device saved in the last hour, nothing in Low Power Mode, when hot or while sketching;
    /// the rest waits for the overnight task on the charger.
    func enrichSoon() async {
        let budget = policy.enrichment
        guard let enrichment, !enriching, !budget.isNone else { return }
        enriching = true
        let signpost = Perf.begin("Enrich")
        await enrichment.configure(relay: vault.relayClient, cloudEnabled: vault.config?.cloudAI ?? false)
        let round = await enrichment.run(budget: budget)
        Perf.end("Enrich", signpost)
        enriching = false
        countRound(round)
        if round.changed > 0 { await reload() }
    }

    func countRound(_ round: EnrichmentService.Round) {
        power.count { c in
            c.aiCalls += round.aiCalls
            c.visionPages += round.visionPages
            c.otherRequests += round.requests
        }
    }

    var aiStatus: String {
        if OnDeviceAI.isAvailable { return "Apple Intelligence on this device" }
        if vault.config?.cloudAI == true, vault.relayClient != nil {
            guard let s = cloudAIStatus else { return "Cloud AI (opt-in) via your relay" }
            if !s.configured { return "Cloud AI is on here, but your relay has no Anthropic key yet" }
            return "Cloud AI (opt-in) via your relay: \(s.used) of \(s.limit) tokens used this month"
        }
        return "Basic (text recognition, dates, places, search by meaning). Smart summaries come from your iPad."
    }

    // MARK: Mirror (Mac)

    private func mirrorIfOwner() async {
        #if os(macOS)
        guard let config = vault.config, config.mirrorOwner, let library, !mirroring else { return }
        mirroring = true
        defer { mirroring = false }
        if let folder = try? vault.folderURL() {
            await ObsidianMirrorService.shared.export(items: items, to: folder.appendingPathComponent("Notes"), library: library)
        }
        if let custom = config.obsidianFolder {
            await ObsidianMirrorService.shared.sync(items: items, folder: URL(fileURLWithPath: custom), library: library)
        }
        if config.appleNotesImport { await AppleNotesBridge.importAll(into: library) }
        #endif
    }

    // MARK: Actions

    func capture(_ text: String) async {
        guard let library else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
            let (id, isNew) = await library.addLink(url)
            toast = isNew ? "Link saved" : "Already saved, opened it"
            selectedItemID = id
        } else {
            let title = trimmed.split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
            let body = trimmed.contains("\n") ? String(trimmed.drop { $0 != "\n" }.dropFirst()) : ""
            selectedItemID = await library.addNote(title: body.isEmpty ? "" : title, body: body.isEmpty ? trimmed : body)
            toast = "Note saved"
        }
        await reload()
        Task { await syncNow() }
    }

    func newNote() async {
        guard let library else { return }
        let id = await library.addNote(title: "", body: "")
        await reload()
        selectedItemID = id
    }

    private(set) var importRun: ImportRun?

    /// Imports anything: files, folders (recursively) and zips (opened, see `FileImport`). The
    /// Import screen shows progress from `importRun`.
    /// Paste's history going into the clipboard: what it's doing now, then what happened.
    var pasteImportStatus: String?
    var importingPaste = false

    /// Everything from Paste into the clipboard (`PasteImport`): its database (and `-wal`), found on
    /// this Mac or picked. Times, apps and pinboards (as tags) are kept.
    func importFromPaste(db: URL, wal: URL?) async {
        guard let library, !importingPaste else { return }
        guard importRun?.finished != false else { toast = "Still importing. Try again when it's done."; return }
        importingPaste = true
        defer { importingPaste = false }
        let scoped = [db, wal].compactMap { $0 }.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        pasteImportStatus = "Reading Paste's history…"
        // The Import screen's progress ring follows along, like any other import.
        var run = ImportRun(total: 1, current: "Paste's history", destination: .clipboard, unit: "clips")
        importRun = run
        do {
            let data = try Data(contentsOf: db), walData = wal.flatMap { try? Data(contentsOf: $0) }
            let read = try await Task.detached(priority: .userInitiated) { try PasteImport.read(data, wal: walData) }.value
            pasteImportStatus = "Adding \(read.entries.count) clips…"
            run.total = max(1, read.entries.count)
            run.current = "your Paste clips"
            importRun = run
            let result = await library.importClips(read.entries) { [weak self] done, added, latest in
                await MainActor.run {
                    guard let self, var now = self.importRun else { return }
                    now.done = done
                    now.added = added
                    if let latest, !latest.isEmpty { now.recent = Array(([ImportRun.Arrival(label: latest)] + now.recent).prefix(8)) }
                    self.importRun = now
                }
            }
            run = importRun ?? run
            run.done = run.total
            run.added = result.added
            run.current = nil
            run.finished = true
            importRun = run
            await clipboard.reload()
            var message = "Added \(result.added) clip\(result.added == 1 ? "" : "s") to your clipboard"
            if result.merged > 0 { message += ", \(result.merged) already here" }
            if read.skipped > 0 { message += "; \(read.skipped) couldn't be read" }
            if read.entries.isEmpty { message = "Found no clips in it. Its tables: \(read.tables.joined(separator: ", "))" }
            pasteImportStatus = message
            toast = result.added > 0 ? "Your Paste history is in the clipboard" : nil
            if result.added > 0 { pushSoon() }
        } catch {
            pasteImportStatus = "Couldn't read it: \(error)"
            importRun = nil
        }
    }

    /// A dropped or picked file that's Paste's database goes to the clipboard, not the library.
    static func isPasteDatabase(_ url: URL) -> Bool {
        guard ["db.sqlite", "Paste.db"].contains(url.lastPathComponent) else { return false }
        return url.path.lowercased().contains("paste") || url.path.lowercased().contains("wiheads")
            || ((try? Data(contentsOf: url)).flatMap { try? SQLiteReader($0) }?.tables.contains { ["ZITEMENTITY", "ZSNIPPET"].contains($0.name) } ?? false)
    }

    func importFiles(_ urls: [URL], source: ItemSource = .import) async {
        guard let library else { return }
        if let db = urls.first(where: Self.isPasteDatabase) {
            let wal = urls.first { $0.lastPathComponent == db.lastPathComponent + "-wal" }
                ?? URL(fileURLWithPath: db.path + "-wal").checkedFile
            selection = .importer // the progress ring shows there
            await importFromPaste(db: db, wal: wal)
            let rest = urls.filter { $0 != db && !$0.lastPathComponent.hasPrefix(db.lastPathComponent + "-") }
            if rest.isEmpty { return }
            await importFiles(rest, source: source)
            return
        }
        guard importRun?.finished != false else { toast = "Still importing. Drop the rest when it's done."; return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        let files = urls.flatMap(Self.filesWithFolders)
        var run = ImportRun(total: files.count)
        importRun = run
        for (url, folder) in files {
            run.current = url.lastPathComponent
            importRun = run
            if let data = try? Data(contentsOf: url) {
                let name = url.lastPathComponent
                let placed = await Task.detached(priority: .userInitiated) { FileImport.placed(name: name, data: data, folder: folder) }.value
                for entry in placed {
                    let (count, label) = await perform(entry.action, folder: entry.folder, in: library, source: source)
                    run.added += count
                    if count > 0 { run.recent.insert(.init(label: label), at: 0) }
                }
                run.recent = Array(run.recent.prefix(8))
            }
            run.done += 1
            importRun = run
        }
        run.current = nil
        run.finished = true
        importRun = run
        toast = run.added == 1 ? "Added 1 item" : "Added \(run.added) items"
        await reload()
        Task {
            await syncNow()
            await enrichSoon()
        }
    }

    /// Clears a finished import so the drop zone shows again.
    func dismissImport() { if importRun?.finished == true { importRun = nil } }

    private func perform(_ action: ImportAction, folder: [String], in library: Library, source: ItemSource) async -> (Int, String) {
        switch action {
        case .items(let items):
            let added = await library.importItems(items)
            let kind = items.first?.kind == .highlight ? "highlights" : "links"
            return (added, added == 1 ? "1 \(kind.dropLast())" : "\(added) \(kind)")
        case .note(let title, let body, let tags):
            _ = await library.addNote(title: title, body: body, tags: tags, source: .import, folder: folder)
            return (1, title.isEmpty ? "Note" : title)
        case .file(let name, let data, let mime):
            let ok = (try? await library.addFile(data, name: name, mime: mime, source: source, folder: folder)) != nil
            return (ok ? 1 : 0, name)
        }
    }

    /// Like `filesInside`, with the folders each file sat in (starting with the dropped folder's
    /// name), so the organiser can keep the structure. A loose file has no folders.
    nonisolated static func filesWithFolders(_ url: URL) -> [(URL, [String])] {
        let files = filesInside(url)
        guard files.count != 1 || files[0] != url else { return [(url, [])] }
        let root = url.standardizedFileURL.pathComponents
        return files.map { file in
            let parts = file.standardizedFileURL.deletingLastPathComponent().pathComponents
            return (file, [url.lastPathComponent] + Array(parts.dropFirst(root.count)))
        }
    }

    /// The file itself, or every visible file in a folder (packages such as .pages count as files).
    nonisolated static func filesInside(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func update(_ id: String, _ fields: [String: JSONValue]) async { await library?.update(id, fields); await reload() }
    func setBody(_ id: String, _ text: String) async { await library?.setBody(id, text) }
    func togglePin(_ item: Item) async { await library?.setPinned(item.id, !item.isPinned); await reload() }
    func markRead(_ item: Item) async { await library?.markRead(item.id, item.readAt == nil); await reload() }

    func delete(_ item: Item) async {
        await library?.delete(item.id)
        if selectedItemID == item.id { selectedItemID = nil }
        await reload()
        SpotlightIndexer.remove(item.id)
    }

    // MARK: Several at once

    func togglePicked(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    /// Deletes the picked items (or the ones given) and leaves select mode.
    func deletePicked(_ ids: Set<String>? = nil) async {
        guard let library else { return }
        let ids = ids ?? picked
        for id in ids { await library.delete(id); SpotlightIndexer.remove(id) }
        if let selected = selectedItemID, ids.contains(selected) { selectedItemID = nil }
        selecting = false
        await reload()
        toast = ids.count == 1 ? "Deleted 1 item" : "Deleted \(ids.count) items"
    }

    func movePicked(to folder: String?) async {
        guard let library else { return }
        let ids = picked
        for id in ids { await library.move(id, to: folder) }
        selecting = false
        await reload()
        let name = folder.flatMap { f in folders.first { $0.id == f }?.name }
        toast = name.map { "Moved \(ids.count) to \($0)" } ?? "Removed \(ids.count) from their folders"
    }

    func pinPicked(_ pinned: Bool) async {
        guard let library else { return }
        for id in picked { await library.setPinned(id, pinned) }
        selecting = false
        await reload()
    }

    func addPicked(to collection: String) async {
        guard let library else { return }
        let count = picked.count
        for id in picked { await library.add(id, to: collection) }
        selecting = false
        await reload()
        toast = "Added \(count) to \(collections.first { $0.id == collection }?.name ?? "the collection")"
    }

    // MARK: Price drops and public links

    var hasRelay: Bool { vault.relayClient != nil }

    /// Turns price tracking on or off. The relay watch is set up by `PriceWatchSync` on the next
    /// sync of any device that has the relay.
    func setTracking(_ item: Item, _ on: Bool) async {
        guard let library, let url = item.watchableURL else { return }
        await library.setWatching(item.id, url: on ? url : nil)
        if on { await PriceAlerts.requestPermission() }
        toast = !on ? "Stopped tracking the price"
            : hasRelay ? "Tracking the price. You'll get an alert when it drops"
            : "Tracking turns on once a device with the relay syncs"
        await reload()
        if hasRelay { await syncNow() }
    }

    /// Publishes (or re-publishes) a note as a public web page and copies the link.
    func publish(_ item: Item) async {
        guard let library, let client = vault.relayClient else { toast = "Public links need the relay (Settings → Sync)"; return }
        let slug = item.published?.slug ?? RelayClient.newSlug()
        do {
            let url = try await client.publish(slug: slug, title: item.displayTitle, markdown: item.body)
            if item.published?.url != url { await library.setPublished(item.id, PublishedLink(slug: slug, url: url)) }
            Pasteboard.copy(url.absoluteString)
            toast = item.published == nil ? "Published. Link copied" : "Page updated. Link copied"
        } catch {
            toast = "Couldn't publish: \(error.localizedDescription)"
        }
        await reload()
    }

    func unpublish(_ item: Item) async {
        guard let library, let link = item.published else { return }
        guard let client = vault.relayClient else { toast = "Removing a public link needs the relay"; return }
        do {
            try await client.unpublish(slug: link.slug)
        } catch {
            toast = "Couldn't remove the link: \(error.localizedDescription)"
            return
        }
        await library.setPublished(item.id, nil)
        toast = "Public link removed"
        await reload()
    }

    func resolveConflicts(_ item: Item, keeping text: String) async {
        await library?.resolveConflicts(item.id, keeping: text)
        await reload()
    }

    func createCollection(_ name: String, symbol: String = "folder", color: String = "blue") async -> String? {
        let id = await library?.createCollection(name, symbol: symbol, color: color)
        await reload()
        return id
    }

    func toggle(_ item: Item, in collection: String) async {
        guard let library else { return }
        if item.collections.contains(collection) { await library.remove(item.id, from: collection) } else { await library.add(item.id, to: collection) }
        await reload()
    }

    func ask(_ question: String) async -> (answer: String, sources: [Item]) {
        guard let library else { return ("", []) }
        let semanticScores = await semantic.scores(for: question)
        let hits = await library.search(question, semantic: semanticScores, limit: 8)
        let fallbackHits = hits
        let sources = fallbackHits.map { (id: $0.id, text: [$0.title, $0.summary ?? "", $0.body, $0.ocrText ?? ""].joined(separator: "\n")) }
        guard !sources.isEmpty else { return ("Nothing in your Trove seems to match that yet.", []) }
        if let answer = try? await OnDeviceAI.ask(question, sources: sources) {
            return (answer.answer, fallbackHits.filter { answer.citations.contains($0.id) }.nilIfEmpty ?? fallbackHits)
        }
        if vault.config?.cloudAI == true, let relay = vault.relayClient, let answer = try? await relay.ask(question, sources: sources) {
            return (answer.answer + "\n\n(Answered in the cloud)", fallbackHits.filter { answer.citations.contains($0.id) }.nilIfEmpty ?? fallbackHits)
        }
        return ("Here are the closest matches. (Turn on Apple Intelligence or cloud AI for written answers.)", fallbackHits)
    }

    // MARK: Settings helpers

    /// The user's own relay, baked in at build time (`TroveDefaultRelay` in project.yml).
    nonisolated static var defaultRelay: String? {
        (Bundle.main.object(forInfoDictionaryKey: "TroveDefaultRelay") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func connectRelay(_ urlString: String) async throws {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else { throw URLError(.badURL) }
        try await vault.connectRelay(url)
        try await openLibrary()
    }

    func disconnectRelay() async {
        vault.disconnectRelay()
        try? await openLibrary()
    }

    func updateConfig(_ change: (inout VaultConfig) -> Void) {
        guard var c = vault.config else { return }
        change(&c)
        vault.save(c)
    }

    // MARK: Widget

    /// The widget reloads only when what it shows changed (recent, pinned, counts), and at most every
    /// 15 minutes: each reload wakes the widget extension (docs/ROADMAP.md §3.7 item 12).
    private func publishWidget() {
        func w(_ item: Item) -> SharedConfig.WidgetItem {
            .init(id: item.id, title: item.displayTitle, subtitle: item.siteName ?? item.category.rawValue.capitalized,
                  symbol: ItemStyle.symbol(for: item), pinned: item.isPinned)
        }
        var counts: [String: Int] = [:]
        for s in [SmartCollection.toRead, .recipes, .places, .thingsToBuy] { counts[s.rawValue] = count(s) }
        let recent = items.prefix(6).map(w)
        let pinned = items.filter(\.isPinned).prefix(6).map(w)
        let next = SharedConfig.WidgetSnapshot(updated: Date(), recent: recent, pinned: pinned, counts: counts)
        if let shown = widgetShown, shown.recent == next.recent, shown.pinned == next.pinned, shown.counts == next.counts { return }
        widgetShown = next
        switch widgetThrottle.request(at: Self.clock) {
        case .now:
            writeWidget()
        case .after(let delay):
            widgetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.widgetThrottle.ran(at: Self.clock)
                self.writeWidget()
            }
        case .waiting:
            break
        }
    }

    private func writeWidget() {
        guard var snapshot = widgetShown else { return }
        snapshot.updated = Date()
        SharedConfig.saveWidget(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static let welcomeNote = """
    Trove keeps everything you save, organises it for you, and finds it again.

    **Try it**
    - Paste a link or type a thought into Capture (⌘⇧Space on Mac).
    - Share anything to Trove from other apps.
    - Search by meaning: “that ramen place”, “tax pdf from March”.
    - Use #tags anywhere in a note.

    Your iPad (Apple Intelligence) adds smart titles and summaries to everything, even items saved on other devices.
    """
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension URL {
    /// This file URL if something is there.
    var checkedFile: URL? { FileManager.default.fileExists(atPath: path) ? self : nil }
}
