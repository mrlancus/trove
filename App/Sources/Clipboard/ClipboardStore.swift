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
/// sensitive ones. The Mac's watcher feeds it; the iPhone adds with the Paste button.
@MainActor
@Observable
final class ClipboardStore {
    static let sensitiveLifetime: TimeInterval = 120

    private(set) var clips: [Clip] = []
    private(set) var ephemeral: [EphemeralClip] = []
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "clipboard.enabled") } }
    /// Keep sensitive copies for two minutes on this device (off: ignore them entirely).
    var keepSensitive: Bool { didSet { UserDefaults.standard.set(keepSensitive, forKey: "clipboard.keepSensitive") } }

    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init() {
        enabled = UserDefaults.standard.object(forKey: "clipboard.enabled") as? Bool ?? true
        keepSensitive = UserDefaults.standard.object(forKey: "clipboard.keepSensitive") as? Bool ?? true
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
        }
        clips = await library.clips()
        #if os(iOS)
        publishForKeyboard()
        #endif
    }

    // MARK: Adding

    func capture(text: String, sourceApp: String?) async {
        guard enabled, let library, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if SensitiveDetector.isSensitive(text) {
            guard keepSensitive else { return }
            ephemeral.removeAll { $0.text == text }
            ephemeral.insert(EphemeralClip(text: text, sourceApp: sourceApp, expires: Date().addingTimeInterval(Self.sensitiveLifetime)), at: 0)
            scheduleExpiry()
            return
        }
        await library.addClip(text: text, sourceApp: sourceApp, sourceDevice: DeviceInfo.name)
        await reload()
    }

    func capture(image data: Data, mime: String, sourceApp: String?) async {
        guard enabled, let library else { return }
        _ = try? await library.addClip(image: data, mime: mime, sourceApp: sourceApp, sourceDevice: DeviceInfo.name)
        await reload()
    }

    func capture(files: [String], sourceApp: String?) async {
        guard enabled, let library else { return }
        await library.addClip(files: files, sourceApp: sourceApp, sourceDevice: DeviceInfo.name)
        await reload()
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
    func copy(_ clip: Clip, transform: ClipTransform? = nil) async {
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
