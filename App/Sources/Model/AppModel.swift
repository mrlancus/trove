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
    var items: [Item] = []
    var collections: [ItemCollection] = []
    var folders: [Folder] = []
    /// Wikilinks and hand-made connections between items, rebuilt on every reload.
    var links = Links.Graph()
    var selection: Selection? = .smart(.recent)
    var selectedItemID: String?
    /// Select mode: tapping toggles items into `picked` for the bulk actions bar.
    var selecting = false { didSet { if !selecting { picked = [] } } }
    var picked: Set<String> = []
    var searchText = "" { didSet { if searchText != oldValue { searchNow() } } }
    var searchResults: [Item]?
    /// Clips matching the search, shown under the library's results.
    private(set) var clipResults: [Clip] = []
    /// This device's search index, copied from the library after each change. Searching it on the
    /// main actor answers every keystroke at once, without waiting behind syncing or file loads.
    @ObservationIgnored private var index = SearchIndex()
    var sync = SyncStatus()
    var enriching = false
    var toast: String?
    var showCapture = false
    /// The drawing editor, when it's open.
    var inkTarget: InkTarget?
    /// Bumped when ink changes or a sync brings changes, so drawings redraw.
    private(set) var inkRevision = 0
    /// Which items have ink, and on which files ("" = a sketch's own pages).
    private(set) var inkedLayers: [String: Set<String>] = [:]
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
    private var pushTask: Task<Void, Never>?
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
        let engine = try vault.makeEngine()
        let library = Library(engine: engine)
        self.library = library
        let config = vault.config!
        enrichment = EnrichmentService(library: library, deviceId: config.deviceId, relay: vault.relayClient, cloudEnabled: config.cloudAI)
        vault.publishCaptureSettings()
        await engine.observe { _ in Task { @MainActor [weak self] in self?.scheduleSave() } }
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
        await clipboard.reload()
        items = await library.items()
        collections = await library.collections()
        folders = await library.folders()
        links = Links.graph(items)
        index = await library.searchIndex()
        if !searchText.isEmpty { searchNow() }
        await applySharedSettings()
        // Search by meaning catches up in the background; keyword search never waits for it.
        let snapshot = self.items, semantic = self.semantic
        Task.detached(priority: .utility) { await semantic.update(snapshot) }
        publishWidget()
        SpotlightIndexer.index(items)
        inkedLayers = await library.inkedLayers()
        inkRevision += 1
    }

    // MARK: Drawing

    /// Something drew or erased: views showing ink redraw. (Saving and syncing follow from the engine.)
    func inkChanged() {
        inkRevision += 1
        Task { if let library { inkedLayers = await library.inkedLayers() } }
    }

    /// A new sketch, opened in the editor.
    func newSketch() async {
        guard let library else { return }
        let id = await library.addSketch()
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
    }

    var visibleItems: [Item] {
        if let searchResults { return searchResults }
        switch selection {
        case .smart(let s): return items.filter(s.contains)
        case .collection(let id): return items.filter { $0.collections.contains(id) }
        case .source(let src): return items.filter { $0.sources.contains(src) }
        case .folder(let id): return items.filter { $0.folder == id }
        case .unfiled: return unfiledItems
        case .graph, .importer, nil: return items
        }
    }

    var selectedItem: Item? { selectedItemID.flatMap { id in items.first { $0.id == id } } }

    func count(_ smart: SmartCollection) -> Int { items.filter(smart.contains).count }

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
        searchResults = index.search(query).map(\.item)
        let clipQuery = ClipQuery(text)
        clipResults = Array(clipboard.clips.lazy.filter { clipQuery.matches($0, haystack: self.clipboard.searchText($0)) }.prefix(8))
        guard query.text.count >= 3 else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let scores = await self.semantic.scores(for: query.text)
            guard !Task.isCancelled, !scores.isEmpty, self.searchText.trimmingCharacters(in: .whitespaces) == text else { return }
            self.searchResults = self.index.search(query, semantic: scores).map(\.item)
        }
    }

    // MARK: Sync

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                #if os(macOS)
                try? await Task.sleep(for: .seconds(30))
                #else
                try? await Task.sleep(for: .seconds(60))
                #endif
            }
        }
    }

    /// Pulls and pushes. A request that arrives mid-sync (say a live ping because the website just
    /// saved something) runs right after instead of being dropped. Enrichment and the Mac mirror run
    /// after the sync lock is released, so slow OCR never holds up changes from other devices.
    func syncNow() async {
        guard let library else { return }
        if sync.syncing { syncAgain = true; return }
        sync.syncing = true
        repeat {
            syncAgain = false
            await importLocalInbox()
            let report = await library.sync()
            if let client = vault.relayClient, let keys = vault.keys {
                let inbox = await InboxSync.run(client: client, keys: keys, library: library)
                if !inbox.imported.isEmpty { toast = "\(inbox.imported.count) new from your inbox" }
                let watches = await PriceWatchSync.run(client: client, library: library)
                for drop in watches.drops { await PriceAlerts.notify(drop) }
                if let drop = watches.drops.first { toast = PriceAlerts.message(drop) }
            }
            sync.lastSync = Date()
            sync.lastError = report.errors.first
            await reload()
            saveNow()
        } while syncAgain
        sync.syncing = false
        await enrichSoon()
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

    /// Pushes local edits a moment after they're made, like the website does.
    private func pushSoon() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Back from the background: the live socket has usually been dropped by then.
    func becameActive() async {
        #if os(iOS)
        clipboardWatcher?.check()
        #endif
        if !sync.live { connectLive() }
        await syncNow()
    }

    private func connectLive() {
        live?.stop()
        guard let url = vault.relayClient?.liveURL else { sync.live = false; return }
        live = LiveConnection(url: url) { [weak self] connected in
            Task { @MainActor in self?.sync.live = connected }
        } onEvent: { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        live?.start()
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
            await self?.reload()
            guard let library = self?.library else { return }
            if await library.engine.hasUnsentChanges { self?.pushSoon() }
        }
    }

    func saveNow() {
        guard let library else { return }
        Task {
            let snapshot = await library.engine.snapshot()
            vault.saveSnapshot(snapshot)
        }
    }

    // MARK: Enrichment

    func enrichSoon() async {
        guard let enrichment, !enriching else { return }
        enriching = true
        await enrichment.configure(relay: vault.relayClient, cloudEnabled: vault.config?.cloudAI ?? false)
        let changed = await enrichment.run(limit: 20)
        enriching = false
        if changed > 0 { await reload() }
    }

    var aiStatus: String {
        if OnDeviceAI.isAvailable { return "Apple Intelligence on this device" }
        if vault.config?.cloudAI == true, vault.relayClient != nil { return "Cloud AI (opt-in) via your relay" }
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
    func importFiles(_ urls: [URL], source: ItemSource = .import) async {
        guard let library else { return }
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

    private func publishWidget() {
        func w(_ item: Item) -> SharedConfig.WidgetItem {
            .init(id: item.id, title: item.displayTitle, subtitle: item.siteName ?? item.category.rawValue.capitalized,
                  symbol: ItemStyle.symbol(for: item), pinned: item.isPinned)
        }
        var counts: [String: Int] = [:]
        for s in [SmartCollection.toRead, .recipes, .places, .thingsToBuy] { counts[s.rawValue] = count(s) }
        SharedConfig.saveWidget(.init(updated: Date(), recent: items.prefix(6).map(w), pinned: items.filter(\.isPinned).prefix(6).map(w), counts: counts))
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
