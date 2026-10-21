import Foundation
import Observation
import TroveCore

/// Non-secret vault settings for this device (Application Support/Trove/config.json).
/// Secrets (vault keys, relay device token) live in the Keychain.
struct VaultConfig: Codable, Equatable {
    enum Storage: Codable, Equatable {
        /// Mac: a plain path inside iCloud Drive (~/Library/Mobile Documents/com~apple~CloudDocs/Trove).
        case path(String)
        /// iPhone/iPad: a folder the user picked in Files, kept with a security-scoped bookmark.
        case bookmark(Data)
        /// No shared folder on this device (it syncs through the relay only).
        case none
    }

    struct Relay: Codable, Equatable {
        var url: String
        var vaultId: String
        var inboxToken: String?
        var cursor: Int = 0
        var inboxCursor: Int = 0
    }

    var vaultId: String
    var deviceId: String
    var encrypted: Bool
    var storage: Storage
    var relay: Relay?
    /// This device writes the readable Markdown mirror (only one device should; default: the Mac).
    var mirrorOwner: Bool
    var obsidianFolder: String?
    var cloudAI: Bool = false
    var screenshotsImport: Bool = false
    var lastScreenshotImport: Date?
    var appleNotesImport: Bool = false
}

enum VaultError: LocalizedError {
    case noKeys, folderUnavailable(String), notAVault, alreadyExists, differentVault

    var errorDescription: String? {
        switch self {
        case .noKeys: "This device doesn't have the vault keys. Pair it again from another device."
        case .folderUnavailable(let why): "Couldn't open the Trove folder: \(why)"
        case .notAVault: "That folder isn't a Trove vault (no vault.json)."
        case .alreadyExists: "There's already a Trove vault in that folder. Choose “Join” instead."
        case .differentVault: "That folder holds a different Trove vault. Choose another folder, or skip it and sync through the relay."
        }
    }
}

/// Owns the on-disk state of one vault on this device and builds the sync engine for it.
@MainActor
@Observable
final class VaultStore {
    static let keysAccount = "vault.keys"
    static let relayTokenAccount = "relay.deviceToken"

    let supportDir: URL
    private(set) var config: VaultConfig?
    private(set) var keys: VaultKeys?
    @ObservationIgnored private var scopedURL: URL?

    init() {
        supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trove", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        config = Self.read(VaultConfig.self, from: configURL)
        keys = Keychain.codable(VaultKeys.Exported.self, for: Self.keysAccount).flatMap { try? VaultKeys($0) }
    }

    var configURL: URL { supportDir.appendingPathComponent("config.json") }
    var snapshotURL: URL { supportDir.appendingPathComponent("state.json") }
    var blobCacheURL: URL { supportDir.appendingPathComponent("blobs", isDirectory: true) }
    var isSetUp: Bool { config != nil && keys != nil }

    func save(_ config: VaultConfig) {
        self.config = config
        Self.write(config, to: configURL)
        publishCaptureSettings()
    }

    /// Lets the share extension and widgets seal into the inbox (public key only).
    func publishCaptureSettings() {
        guard let config, let keys else { SharedConfig.saveCapture(nil); return }
        SharedConfig.saveCapture(.init(vaultPublicKey: keys.publicKeyBase64URL, relayURL: config.relay?.url,
                                       relayVaultId: config.relay?.vaultId, inboxToken: config.relay?.inboxToken))
    }

    // MARK: Folder location

    #if os(macOS)
    /// The default iCloud Drive location on the Mac.
    static var macICloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Trove", isDirectory: true)
    }

    static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: macICloudFolder.deletingLastPathComponent().path)
    }
    #endif

    func folderURL() throws -> URL? {
        guard let config else { return nil }
        switch config.storage {
        case .none: return nil
        case .path(let p): return URL(fileURLWithPath: p, isDirectory: true)
        case .bookmark(let data):
            if let scopedURL { return scopedURL }
            var stale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            guard url.startAccessingSecurityScopedResource() else { throw VaultError.folderUnavailable("permission was not granted") }
            scopedURL = url
            if stale, let fresh = try? Self.bookmark(for: url) {
                var c = config
                c.storage = .bookmark(fresh)
                save(c)
            }
            return url
        }
    }

    static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// NSFileCoordinator + iCloud download, so placeholders are fetched and writes are safe.
    nonisolated static let coordinate: @Sendable (URL, Bool, (URL) throws -> Void) throws -> Void = { url, write, body in
        var coordinationError: NSError?
        var bodyError: Error?
        let coordinator = NSFileCoordinator()
        if write {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        } else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        }
        if let e = coordinationError ?? bodyError { throw e }
    }

    // MARK: Create / join

    /// Creates a brand new vault. `folder` nil = relay-only (no iCloud folder on this device).
    func createVault(folder: URL?, encrypted: Bool, picked: Bool) throws {
        let keys = VaultKeys.generate()
        let vaultId = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URL
        var storage = VaultConfig.Storage.none
        if let folder {
            let transport = FolderTransport(root: folder, coordinate: Self.coordinate)
            if try transport.readVaultInfo() != nil { throw VaultError.alreadyExists }
            try transport.writeVaultInfo(.init(vaultId: vaultId, vaultPublicKey: keys.publicKeyBase64URL, encrypted: encrypted))
            storage = picked ? .bookmark(try Self.bookmark(for: folder)) : .path(folder.path)
        }
        try Keychain.setCodable(keys.exported(), for: Self.keysAccount)
        self.keys = keys
        #if os(macOS)
        let owner = true
        #else
        let owner = false
        #endif
        save(VaultConfig(vaultId: vaultId, deviceId: UUID().uuidString, encrypted: encrypted, storage: storage, relay: nil, mirrorOwner: owner))
    }

    /// Joins with a scanned QR / pasted setup code. The folder is optional (relay-only devices).
    func join(_ payload: PairingPayload, folder: URL?, picked: Bool) async throws {
        let keys = try VaultKeys(payload.keys)
        var storage = VaultConfig.Storage.none
        if let folder {
            let transport = FolderTransport(root: folder, coordinate: Self.coordinate)
            if let info = try transport.readVaultInfo() {
                guard info.vaultId == payload.vaultId else { throw VaultError.differentVault }
            } else {
                // A vault made on the website has no iCloud folder yet; this device starts one and
                // copies the relay's journals into it. Only in an empty folder: anything else may be
                // a vault iCloud hasn't downloaded yet.
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                guard contents.allSatisfy({ $0 == ".DS_Store" }) else { throw VaultError.notAVault }
                try transport.writeVaultInfo(.init(vaultId: payload.vaultId, vaultPublicKey: keys.publicKeyBase64URL,
                                                   encrypted: payload.encrypted, relayURL: payload.relayURL))
            }
            storage = picked ? .bookmark(try Self.bookmark(for: folder)) : .path(folder.path)
        }
        let deviceId = UUID().uuidString
        var relay: VaultConfig.Relay?
        if let url = payload.relayURL.flatMap(URL.init(string:)), let code = payload.pairingCode {
            let reg = try await RelayClient.join(baseURL: url, vaultId: payload.relayVaultId ?? payload.vaultId, pairingCode: code,
                                                 deviceName: DeviceInfo.name, deviceKind: DeviceInfo.kind, deviceId: deviceId)
            try Keychain.set(Data(reg.deviceToken.utf8), for: Self.relayTokenAccount)
            relay = .init(url: url.absoluteString, vaultId: reg.vaultId, inboxToken: payload.inboxToken)
        }
        try Keychain.setCodable(keys.exported(), for: Self.keysAccount)
        self.keys = keys
        save(VaultConfig(vaultId: payload.vaultId, deviceId: deviceId, encrypted: payload.encrypted, storage: storage, relay: relay, mirrorOwner: false))
    }

    /// Registers this vault with a relay (first device) or attaches using an existing relay vault.
    func connectRelay(_ url: URL) async throws {
        guard var config, let keys else { throw VaultError.noKeys }
        let reg = try await RelayClient.createVault(baseURL: url, publicKey: keys.publicKeyBase64URL, deviceName: DeviceInfo.name,
                                                    deviceKind: DeviceInfo.kind, deviceId: config.deviceId)
        try Keychain.set(Data(reg.deviceToken.utf8), for: Self.relayTokenAccount)
        if reg.deviceId != config.deviceId {
            // Extremely unlikely (id collision); keep journals consistent by adopting the relay's id for new ops.
            config.deviceId = reg.deviceId
        }
        config.relay = .init(url: url.absoluteString, vaultId: reg.vaultId, inboxToken: reg.inboxToken)
        if let folder = try folderURL() {
            let t = FolderTransport(root: folder, coordinate: Self.coordinate)
            if var info = try t.readVaultInfo() {
                info.relayURL = url.absoluteString
                try t.writeVaultInfo(info)
            }
        }
        save(config)
    }

    func disconnectRelay() {
        guard var config else { return }
        config.relay = nil
        Keychain.delete(Self.relayTokenAccount)
        save(config)
    }

    var relayClient: RelayClient? {
        guard let relay = config?.relay, let url = URL(string: relay.url),
              let token = Keychain.get(Self.relayTokenAccount).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        return RelayClient(baseURL: url, vaultId: relay.vaultId, token: token)
    }

    /// QR payload for adding another device (includes a fresh single-use relay pairing code).
    func pairingPayload() async throws -> PairingPayload {
        guard let config, let keys else { throw VaultError.noKeys }
        var payload = PairingPayload(vaultId: config.vaultId, keys: keys.exported(), encrypted: config.encrypted)
        if let relay = config.relay, let client = relayClient {
            payload.relayURL = relay.url
            payload.relayVaultId = relay.vaultId
            payload.pairingCode = try await client.createPairing().pairingCode
            payload.inboxToken = relay.inboxToken
        }
        return payload
    }

    func browserSetupCode() -> String? {
        guard let relay = config?.relay, let inbox = relay.inboxToken, let keys else { return nil }
        return BrowserSetupCode(relayURL: relay.url, vaultId: relay.vaultId, inboxToken: inbox, vaultPublicKey: keys.publicKeyBase64URL).code
    }

    // MARK: Engine

    func makeEngine() throws -> SyncEngine {
        guard let config, let keys else { throw VaultError.noKeys }
        var transports: [any SyncTransport] = []
        if let folder = try folderURL() {
            transports.append(FolderTransport(root: folder, name: "icloud", coordinate: Self.coordinate))
        }
        if let client = relayClient {
            let configURL = self.configURL
            transports.append(RelayTransport(client: client, cursor: config.relay?.cursor ?? 0, saveCursor: { cursor in
                Task { @MainActor in
                    guard var c = Self.read(VaultConfig.self, from: configURL) else { return }
                    c.relay?.cursor = cursor
                    Self.write(c, to: configURL)
                }
            }))
        }
        let snapshot = Self.read(SyncEngine.Snapshot.self, from: snapshotURL)
        // Bridge when this device has both, so iCloud-less devices' journals land in iCloud too.
        return SyncEngine(device: config.deviceId, keys: keys, encrypted: config.encrypted, transports: transports,
                          bridge: transports.count > 1, blobCache: blobCacheURL, snapshot: snapshot)
    }

    func saveSnapshot(_ snapshot: SyncEngine.Snapshot) {
        Self.write(snapshot, to: snapshotURL)
    }

    /// Forget this vault on this device (the vault itself is untouched).
    func reset() {
        Keychain.delete(Self.keysAccount)
        Keychain.delete(Self.relayTokenAccount)
        for url in [configURL, snapshotURL, blobCacheURL] { try? FileManager.default.removeItem(at: url) }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        config = nil
        keys = nil
        SharedConfig.saveCapture(nil)
    }

    // MARK: JSON helpers

    nonisolated static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Writes vault snapshots one at a time, off the main thread, never an older one over a newer one.
actor SnapshotWriter {
    static let shared = SnapshotWriter()
    private var written = -1

    func write(_ snapshot: SyncEngine.Snapshot, to url: URL) {
        // Ops only ever grow, so a snapshot with fewer is older than one already saved.
        guard snapshot.ops.count >= written else { return }
        written = snapshot.ops.count
        VaultStore.write(snapshot, to: url)
    }
}
