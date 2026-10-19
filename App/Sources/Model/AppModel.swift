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
    var selection: Selection? = .smart(.recent)
    var selectedItemID: String?
    var searchText = "" { didSet { scheduleSearch() } }
    var searchResults: [Item]?
    var sync = SyncStatus()
    var enriching = false
    var toast: String?
    var showCapture = false
    var config: VaultConfig? { vault.config }

    // MARK: Services
    let vault = VaultStore()
    private(set) var library: Library?
    private(set) var enrichment: EnrichmentService?
    let semantic = SemanticIndex()
    private var syncTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var live: LiveConnection?

    // MARK: Lifecycle

    func start() async {
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
        startSyncLoop()
        connectLive()
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
        items = await library.items()
        collections = await library.collections()
        await semantic.update(items)
        if !searchText.isEmpty { await runSearch() }
        publishWidget()
        SpotlightIndexer.index(items)
    }

    var visibleItems: [Item] {
        if let searchResults { return searchResults }
        switch selection {
        case .smart(let s): return items.filter(s.contains)
        case .collection(let id): return items.filter { $0.collections.contains(id) }
        case .source(let src): return items.filter { $0.source == src }
        case nil: return items
        }
    }

    var selectedItem: Item? { selectedItemID.flatMap { id in items.first { $0.id == id } } }

    func count(_ smart: SmartCollection) -> Int { items.filter(smart.contains).count }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    private func runSearch() async {
        guard let library else { return }
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { searchResults = nil; return }
        let free = SearchQuery.parse(text).text
        let semanticScores = await semantic.scores(for: free)
        searchResults = await library.search(text, semantic: semanticScores)
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

    func syncNow() async {
        guard let library, !sync.syncing else { return }
        sync.syncing = true
        defer { sync.syncing = false }
        await importLocalInbox()
        let report = await library.sync()
        if let client = vault.relayClient, let keys = vault.keys {
            let inbox = await InboxSync.run(client: client, keys: keys, library: library)
            if !inbox.imported.isEmpty { toast = "\(inbox.imported.count) new from your inbox" }
        }
        sync.lastSync = Date()
        sync.lastError = report.errors.first
        await reload()
        saveNow()
        await enrichSoon()
        await mirrorIfOwner()
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
        guard let config = vault.config, config.mirrorOwner, let library else { return }
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

    func importFiles(_ urls: [URL], source: ItemSource = .app) async {
        guard let library else { return }
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "txt" where url.lastPathComponent.lowercased().contains("clippings"):
                added += await library.importItems(KindleClippings.parse(String(decoding: data, as: UTF8.self)))
            case "html", "htm":
                let html = String(decoding: data, as: UTF8.self)
                let marks = NetscapeBookmarks.parse(html)
                if marks.isEmpty { _ = try? await library.addFile(data, name: url.lastPathComponent, mime: "text/html", source: source) ; added += 1 }
                else { added += await library.importItems(marks) }
            case "csv":
                added += await library.importItems(CSVImport.importLinks(String(decoding: data, as: UTF8.self)))
            case "md", "markdown":
                let note = ObsidianMirror.parse(String(decoding: data, as: UTF8.self), fileName: url.lastPathComponent)
                await library.addNote(title: note.title, body: note.body, tags: note.tags, source: .import)
                added += 1
            default:
                if (try? await library.addFile(data, name: url.lastPathComponent, mime: Self.mime(for: ext), source: source)) != nil { added += 1 }
            }
        }
        toast = added == 1 ? "Added 1 item" : "Added \(added) items"
        await reload()
        Task { await syncNow() }
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
            return (answer.answer + "\n\n☁︎ Answered in the cloud", fallbackHits.filter { answer.citations.contains($0.id) }.nilIfEmpty ?? fallbackHits)
        }
        return ("Here are the closest matches. (Turn on Apple Intelligence or cloud AI for written answers.)", fallbackHits)
    }

    // MARK: Settings helpers

    func setCloudAI(_ on: Bool) async {
        guard var c = vault.config else { return }
        c.cloudAI = on
        vault.save(c)
        try? await vault.relayClient?.setAIEnabled(on)
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

    static func mime(for ext: String) -> String {
        switch ext {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "m4a": "audio/m4a"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "mov": "video/quicktime"
        case "mp4": "video/mp4"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
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
