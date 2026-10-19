import Foundation

/// Files shared between the app and its extensions through the App Group container.
/// Nothing secret lives here: extensions get the vault *public* key (they can seal, not open).
enum SharedConfig {
    static var appGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "TroveAppGroup") as? String) ?? "group.com.mrlancus.trove"
    }

    static var container: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        // Fallback (e.g. App Group not provisioned yet): the app's own support folder.
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TroveShared")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Sealed envelopes dropped by the share extension when the relay isn't set up (or is offline).
    static var localInbox: URL {
        let url = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Capture settings for extensions

    struct Capture: Codable, Equatable {
        var vaultPublicKey: String          // b64u X25519
        var relayURL: String?
        var relayVaultId: String?
        var inboxToken: String?
    }

    static var captureURL: URL { container.appendingPathComponent("capture.json") }

    static func loadCapture() -> Capture? {
        guard let data = try? Data(contentsOf: captureURL) else { return nil }
        return try? JSONDecoder().decode(Capture.self, from: data)
    }

    static func saveCapture(_ capture: Capture?) {
        if let capture, let data = try? JSONEncoder().encode(capture) {
            try? data.write(to: captureURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: captureURL)
        }
    }

    // MARK: Widget snapshot

    struct WidgetItem: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var pinned: Bool
    }

    struct WidgetSnapshot: Codable {
        var updated: Date
        var recent: [WidgetItem]
        var pinned: [WidgetItem]
        var counts: [String: Int]
    }

    static var widgetURL: URL { container.appendingPathComponent("widget.json") }

    static func loadWidget() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: widgetURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func saveWidget(_ snapshot: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: widgetURL, options: .atomic) }
    }

    // MARK: Clipboard history for the keyboard extension

    /// Recent text clips the Trove keyboard shows. Written by the app, read by the keyboard (which
    /// has no vault keys). Sensitive clips never get here.
    struct KeyboardClip: Codable, Hashable, Identifiable {
        var id: String
        var text: String
        var kind: String
        var pinned: Bool
        var source: String?
    }

    static var keyboardClipsURL: URL { container.appendingPathComponent("keyboard-clips.json") }

    static func loadKeyboardClips() -> [KeyboardClip] {
        guard let data = try? Data(contentsOf: keyboardClipsURL) else { return [] }
        return (try? JSONDecoder().decode([KeyboardClip].self, from: data)) ?? []
    }

    static func saveKeyboardClips(_ clips: [KeyboardClip]) {
        if let data = try? JSONEncoder().encode(clips) { try? data.write(to: keyboardClipsURL, options: .atomic) }
    }
}
