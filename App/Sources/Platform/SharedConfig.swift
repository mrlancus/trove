import Foundation
import Security

/// Files shared between the app and its extensions through the App Group container.
/// Nothing secret lives here: extensions get the vault *public* key (they can seal, not open).
enum SharedConfig {
    /// The App Group this build was made with (Info.plist `TroveAppGroup`).
    static var configuredGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "TroveAppGroup") as? String) ?? "group.com.mrlancus.trove"
    }

    /// The App Group this install can really open, found once per launch. Sideloading re-signs the
    /// app and can rename its groups: SideStore and AltStore (free Apple ID) append the team ID
    /// (`group.com.mrlancus.trove.ABCDE12345`) and list the new names under `ALTAppGroups` in the
    /// app's Info.plist. The app and each extension work it out the same way, so they meet in the
    /// same container. Nil when none can be opened (the groups were stripped when signing).
    static let appGroupFound: String? = {
        if let group = groupCandidates().first(where: opens) { return group }
        // The team ID guesses only when nothing listed works (finding the team touches the keychain).
        return teamIDs().map { configuredGroup + "." + $0 }.first(where: opens)
    }()

    /// Whether this process can open the group's container.
    static func opens(_ group: String) -> Bool {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return false }
        #if os(iOS)
        // iOS hands out a path only for a group in the entitlements; check it's really there.
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        #else
        return true
        #endif
    }

    static var appGroup: String { appGroupFound ?? configuredGroup }

    /// Group names to try, most likely first.
    static func groupCandidates() -> [String] {
        let base = configuredGroup
        var out: [String] = []
        func add(_ group: String) { if !group.isEmpty, !out.contains(group) { out.append(group) } }
        // What the sideloading tool says it registered: this bundle's list, then the app's (an
        // extension's bundle sits in the app's PlugIns folder).
        for bundle in [Bundle.main, hostApp].compactMap({ $0 }) {
            let listed = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
            for group in listed where group.hasPrefix(base) { add(group) }
            for group in listed where !group.hasPrefix(base) { add(group) }
        }
        add(base)
        return out
    }

    /// The containing app's bundle, when this code runs in an extension.
    static var hostApp: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        // iOS: Trove.app/PlugIns/X.appex; macOS: Trove.app/Contents/PlugIns/X.appex.
        var app = url.deletingLastPathComponent().deletingLastPathComponent()
        if app.lastPathComponent == "Contents" { app = app.deletingLastPathComponent() }
        return Bundle(url: app)
    }

    /// Team IDs a re-signed install may use: the part SideStore/AltStore add to the bundle id
    /// (`com.mrlancus.trove.ABCDE12345`), and the prefix of this app's keychain access group.
    static func teamIDs() -> [String] {
        var out: [String] = []
        let original = "com.mrlancus.trove"
        for id in [hostApp?.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap({ $0 }) where id.hasPrefix(original + ".") {
            let next = id.dropFirst(original.count + 1).split(separator: ".").first.map(String.init) ?? ""
            if isTeamID(next), !out.contains(next) { out.append(next) }
        }
        if let prefix = keychainTeamID(), !out.contains(prefix) { out.append(prefix) }
        return out
    }

    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }

    /// The team prefix of the default keychain access group ("ABCDE12345.com.mrlancus.trove"),
    /// read from a throwaway item. Nil on a build without a team (CI's unsigned builds).
    static func keychainTeamID() -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "trove.team-probe",
                                   kSecAttrAccount as String: "probe"]
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #if os(macOS)
            add[kSecUseDataProtectionKeychain as String] = true
            #endif
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first.map(String.init), isTeamID(prefix) else { return nil }
        return prefix
    }

    /// Whether the app and its extensions share a container on this install.
    static var hasSharedContainer: Bool { appGroupFound != nil }

    static var container: URL {
        if let group = appGroupFound, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return url }
        // Fallback (no App Group on this install): this process's own folder, which the app and
        // its extensions do NOT share.
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
