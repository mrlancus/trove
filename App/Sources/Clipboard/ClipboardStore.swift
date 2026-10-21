import Foundation
import Observation
import TroveCore

/// A sensitive copy (password, API key, one-time code) kept only in memory on this device, then
/// forgotten. Never synced.
struct EphemeralClip: Identifiable, Equatable {
    let id = UUID().uuidString
    let text: String
    let sourceApp: String?
    let expires: Date
}

/// Clipboard history for the UI: synced clips from the library plus this device's short-lived
/// sensitive ones. `ClipboardWatcher` feeds it (all the time on the Mac, whenever Trove opens on
/// iPhone and iPad), and the Paste button adds by hand.
@MainActor
@Observable
final class ClipboardStore {
    static let sensitiveLifetime: TimeInterval = 120

    private(set) var clips: [Clip] = []
    private(set) var ephemeral: [EphemeralClip] = []
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "clipboard.enabled") } }
    /// Keep sensitive copies for two minutes on this device (off: ignore them entirely).
    var keepSensitive: Bool { didSet { UserDefaults.standard.set(keepSensitive, forKey: "clipboard.keepSensitive") } }
    /// iPhone/iPad: something new was copied that isn't saved yet (seen without reading it, so iOS
    /// doesn't ask "Allow Paste?"; the Paste button saves it).
    var copyWaiting = false
    /// Saving what was copied whenever Trove opens. Synced, and still offered for the shared
    /// setting; iPhone and iPad no longer read the clipboard by themselves (`ClipboardWatcher`).
    var captureOnOpen: Bool { didSet { UserDefaults.standard.set(captureOnOpen, forKey: "clipboard.captureOnOpen") } }
    /// Keep where you were with each copy and paste (synced: `recordPlaces`).
    var recordPlaces = true

    /// The last copy this device recorded, for the status line in Settings.
    private(set) var lastCaptured: (date: Date, heldBriefly: Bool)?

    /// Your tags, each with a colour (synced, `settings.tags`): the clipboard's sections.
    private(set) var customTags: [CustomTag] = []
    /// Bumped whenever `clips` changes, so lists can keep their filtered results until then.
    private(set) var revision = 0
    @ObservationIgnored private var shownStamp = ""

    @ObservationIgnored private var library: Library?
    /// What each clip's row shows and is searched by, worked out once per version of the clip, off
    /// the main thread after a reload. Working it out again on every draw (the kind is a set of
    /// pattern checks) made a big history crawl.
    @ObservationIgnored private var facts: [String: (hlc: String, facts: ClipFacts)] = [:]
    @ObservationIgnored private var tagCounts: (revision: Int, counts: [String: Int]) = (-1, [:])
    @ObservationIgnored private var warming: Task<Void, Never>?
    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// From this many clips on, words are looked up in a postings index instead of scanning every
    /// clip's text (which stays the way below it, and while the index catches up).
    static let indexFrom = 20_000
    /// The clip index, when there are that many, and the revision it matches.
    @ObservationIgnored private(set) var clipIndex: (revision: Int, index: ClipIndex)?
    @ObservationIgnored private var indexing: Task<Void, Never>?

    init() {
        enabled = UserDefaults.standard.object(forKey: "clipboard.enabled") as? Bool ?? true
        keepSensitive = UserDefaults.standard.object(forKey: "clipboard.keepSensitive") as? Bool ?? true
        captureOnOpen = UserDefaults.standard.object(forKey: "clipboard.captureOnOpen") as? Bool ?? true
    }

    func attach(_ library: Library) async {
        self.library = library
        await reload()
    }

    func reload() async {
        guard let library else { return }
        if Date().timeIntervalSince(lastPrune) > 3_600 {
            lastPrune = Date()
            await library.pruneClips()
            await library.repairWrappedClips()
        }
        // Nothing new since last time: leave everything as it is, so nothing redraws.
        let stamp = await library.stamp(of: ["clip", "setting"])
        guard stamp != shownStamp else { return }
        shownStamp = stamp
        clips = await library.clips()
        customTags = await library.customTags()
        autoSave = await library.clipAutoSaveKinds()
        keep = await library.clipKeep()
        revision += 1
        warmFacts()
        refreshClipIndex()
        #if os(iOS)
        publishForKeyboard()
        #endif
    }

    // MARK: Searching

    /// Updates the clip index in the background with only the clips that changed.
    private func refreshClipIndex() {
        guard clips.count >= Self.indexFrom else { clipIndex = nil; return }
        indexing?.cancel()
        let snapshot = clips, revision = self.revision
        let start = clipIndex?.index ?? ClipIndex()
        indexing = Task { [weak self] in
            let built = await Task.detached(priority: .utility) { () -> ClipIndex in
                var index = start
                let live = Set(snapshot.map(\.id))
                for id in index.ids where !live.contains(id) { index.remove(id) }
                for c in snapshot where index.version(c.id) != c.record.updatedHLC { index.update(c) }
                index.prepare()
                return index
            }.value
            guard let self, !Task.isCancelled else { return }
            self.clipIndex = (revision, built)
        }
    }

    /// Clips matching `query`: from the index when there is one for these clips, else by scanning.
    func matches(_ query: ClipQuery, limit: Int) -> [Clip] {
        if !query.words.isEmpty, let clipIndex, clipIndex.revision == revision {
            let byId = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return clipIndex.index.search(query, limit: limit).ids.compactMap { byId[$0] }
        }
        return Array(clips.lazy.filter { query.matches($0, haystack: self.searchText($0)) }.prefix(limit))
    }

    /// Ids of clips matching `query`'s words via the index, or nil to scan instead.
    func indexedIDs(_ query: ClipQuery) -> Set<String>? {
        guard !query.words.isEmpty, let clipIndex, clipIndex.revision == revision else { return nil }
        return Set(clipIndex.index.search(query).ids)
    }

    /// The clip's folded search text (`Clip.searchText`), worked out once per version of the clip.
    func searchText(_ clip: Clip) -> String { facts(clip).search }

    /// A clip's row facts: from the cache, or worked out now (only for clips the background pass
    /// hasn't reached yet).
    func facts(_ clip: Clip) -> ClipFacts {
        if let hit = facts[clip.id], hit.hlc == clip.record.updatedHLC { return hit.facts }
        let made = ClipFacts(clip)
        facts[clip.id] = (clip.record.updatedHLC, made)
        return made
    }

    /// Works out the facts of new and changed clips in the background, then forgets deleted ones.
    private func warmFacts() {
        let pending = clips.filter { facts[$0.id]?.hlc != $0.record.updatedHLC }
        let live = Set(clips.map(\.id))
        facts = facts.filter { live.contains($0.key) }
        guard !pending.isEmpty else { return }
        warming?.cancel()
        warming = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { pending.map { ($0.id, $0.record.updatedHLC, ClipFacts($0)) } }.value
            guard let self, !Task.isCancelled else { return }
            for (id, hlc, f) in made where self.facts[id]?.hlc != hlc { self.facts[id] = (hlc, f) }
        }
    }

    /// How many clips have this tag (counted once per change, not per chip per draw).
    func count(ofTag tag: String) -> Int {
        if tagCounts.revision != revision {
            var counts: [String: Int] = [:]
            for c in clips { for t in c.tags { counts[t, default: 0] += 1 } }
            tagCounts = (revision, counts)
        }
        return tagCounts.counts[tag] ?? 0
    }

    func color(ofTag tag: String) -> TagColor? { customTags.first { $0.name == tag }?.color }

    // MARK: Tags

    @discardableResult
    func setTagColor(_ name: String, _ color: TagColor) async -> String? {
        let tag = await library?.setTagColor(name, color)
        await reload()
        return tag ?? nil
    }

    func deleteTag(_ name: String) async {
        await library?.deleteTag(name)
        await reload()
    }

    func toggleTag(_ tag: String, on clip: Clip) async {
        await library?.toggleClipTag(clip.id, tag)
        await reload()
    }

    // MARK: Adding

    func capture(text: String, sourceApp: String?, source: ClipSource = ClipSource()) async {
        guard enabled, let library, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if SensitiveDetector.isSensitive(text) {
            guard keepSensitive else { return }
            ephemeral.removeAll { $0.text == text }
            ephemeral.insert(EphemeralClip(text: text, sourceApp: sourceApp, expires: Date().addingTimeInterval(Self.sensitiveLifetime)), at: 0)
            lastCaptured = (Date(), true)
            scheduleExpiry()
            return
        }
        let id = await library.addClip(text: text, sourceApp: sourceApp, sourceDevice: DeviceInfo.name, source: source)
        lastCaptured = (Date(), false)
        await reload()
        await note(id, .copy, app: sourceApp, source: source)
    }

    func events(for clip: String) async -> [ClipEvent] { await library?.clipEvents(of: clip) ?? [] }

    /// Where and when a clip was copied, pasted or used again (PROTOCOL.md §8), with the place.
    func note(_ id: String?, _ type: ClipEvent.Kind, app: String?, source: ClipSource = ClipSource()) async {
        guard let id, let library else { return }
        let place = recordPlaces ? await PlaceFinder.shared.current() : nil
        await library.recordClipEvent(id, type, app: app, bundle: source.bundle, url: source.url, title: source.title,
                                      deviceName: DeviceInfo.name, place: place)
    }

    func capture(image data: Data, mime: String, sourceApp: String?, source: ClipSource = ClipSource()) async {
        guard enabled, let library else { return }
        let id = try? await library.addClip(image: data, mime: mime, sourceApp: sourceApp, sourceDevice: DeviceInfo.name, source: source)
        lastCaptured = (Date(), false)
        await reload()
        await note(id, .copy, app: sourceApp, source: source)
    }

    func capture(files: [String], sourceApp: String?) async {
        guard enabled, let library else { return }
        let id = await library.addClip(files: files, sourceApp: sourceApp, sourceDevice: DeviceInfo.name)
        lastCaptured = (Date(), false)
        await reload()
        await note(id, .copy, app: sourceApp)
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = ephemeral.map(\.expires).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.ephemeral.removeAll { $0.expires <= Date() }
            self.scheduleExpiry()
        }
    }

    // MARK: Using

    /// Puts a clip (optionally rewritten) on the system pasteboard and moves it to the top.
    /// `use: false` when the caller records where it was pasted instead.
    func copy(_ clip: Clip, transform: ClipTransform? = nil, use: Bool = true) async {
        if clip.image != nil {
            guard let picture = await image(for: clip) else { return }
            ClipPasteboard.write(image: picture)
        } else if !clip.files.isEmpty, transform == nil {
            ClipPasteboard.write(files: clip.files)
        } else {
            ClipPasteboard.write(text: transform.flatMap { $0.apply(clip.text) } ?? clip.text)
        }
        await library?.markClipUsed(clip.id)
        await reload()
        if use { await note(clip.id, .use, app: nil) }
    }

    func copy(_ clip: EphemeralClip) { ClipPasteboard.write(text: clip.text) }

    /// Several clips at once, one per line (the "stack").
    func copy(joined: [Clip]) async {
        ClipPasteboard.write(text: joined.map(\.text).joined(separator: "\n"))
        for clip in joined { await library?.markClipUsed(clip.id) }
        await reload()
    }

    func togglePin(_ clip: Clip) async {
        await library?.setClipPinned(clip.id, !clip.isPinned)
        await reload()
    }

    func delete(_ clip: Clip) async {
        await library?.deleteClip(clip.id)
        await reload()
    }

    func forget(_ clip: EphemeralClip) { ephemeral.removeAll { $0.id == clip.id } }

    /// Deletes every unpinned clip (and the sensitive ones on this device).
    func clearHistory() async {
        ephemeral = []
        for clip in clips where !clip.isPinned { await library?.deleteClip(clip.id) }
        await reload()
    }

    // MARK: Editing

    func rename(_ clip: Clip, to title: String) async {
        await library?.renameClip(clip.id, to: title)
        await reload()
    }

    func edit(_ clip: Clip, text: String) async {
        await library?.editClip(clip.id, text: text)
        await reload()
    }

    func setTags(_ clip: Clip, _ tags: [String]) async {
        await library?.setClipTags(clip.id, tags)
        await reload()
    }

    func setNote(_ clip: Clip, _ note: String) async {
        await library?.setClipNote(clip.id, note)
        await reload()
    }

    /// Kinds saved into the library as they're copied (synced to every device).
    private(set) var autoSave: Set<ClipKind> = []

    func setAutoSave(_ kind: ClipKind, _ on: Bool) async {
        var kinds = autoSave
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        await library?.setClipAutoSave(kinds)
        await reload()
    }

    /// How much history is kept (synced to every device).
    private(set) var keep: ClipKeep = .standard

    func setKeep(_ keep: ClipKeep) async {
        await library?.setClipKeep(keep)
        await reload()
    }

    func saveToLibrary(_ clip: Clip) async -> String? {
        let id = try? await library?.saveClipToLibrary(clip.id)
        await reload()
        return id ?? nil
    }

    func image(for clip: Clip) async -> PlatformImage? {
        guard let attachment = clip.image else { return nil }
        if let cached = images[attachment.id] { return cached }
        guard let data = try? await library?.attachmentData(attachment), let image = PlatformImage.fromData(data) else { return nil }
        images[attachment.id] = image
        return image
    }

    #if os(iOS)
    /// The keyboard extension can't open the vault, so the app leaves it the latest text clips.
    private func publishForKeyboard() {
        let recent = clips.filter { $0.image == nil }.prefix(120)
        SharedConfig.saveKeyboardClips(recent.map {
            SharedConfig.KeyboardClip(id: $0.id, text: String($0.text.prefix(4_000)), kind: $0.kind.rawValue, pinned: $0.isPinned,
                                      source: $0.sourceApp ?? $0.sourceDevice)
        })
    }
    #endif
}

/// What a clip's row shows and what it's searched by, worked out once per version (`ClipboardStore.facts`).
struct ClipFacts: Sendable {
    let kind: ClipKind
    let title: String
    let snippet: String?
    let color: (r: Double, g: Double, b: Double, a: Double)?
    let search: String

    nonisolated init(_ c: Clip) {
        let kind = c.kind
        self.kind = kind
        title = c.displayTitle
        let s = c.summary ?? (kind == .image ? c.ocrText?.split(separator: "\n").first.map(String.init) : c.preview)
        snippet = s.flatMap { $0.isEmpty || $0 == c.displayTitle ? nil : String($0.prefix(200)) }
        color = kind == .color ? ClipClassifier.color(c.text) : nil
        search = c.searchText
    }
}
