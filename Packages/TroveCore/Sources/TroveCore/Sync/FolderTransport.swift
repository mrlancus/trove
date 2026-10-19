import Foundation

/// The iCloud Drive vault (PROTOCOL.md §3): `.sync/<device>/<first>-<last>.trv` journals and
/// `.blobs/<aa>/<id>.trv` attachments. Files are written once and never modified, and each device
/// writes only inside its own `.sync/<device>/` folder, so iCloud never sees a conflict.
///
/// Works with any folder. On Apple platforms the app wraps calls in NSFileCoordinator and asks
/// iCloud to download placeholders (see `FolderTransport.coordinate`).
public struct FolderTransport: SyncTransport {
    public let root: URL
    /// Unique per transport (the engine tracks push state by name).
    public let name: String

    /// Hook for the app to wrap file access (NSFileCoordinator / startDownloadingUbiquitousItem).
    public var coordinate: @Sendable (_ url: URL, _ write: Bool, _ body: (URL) throws -> Void) throws -> Void

    public init(root: URL, name: String? = nil, coordinate: (@Sendable (_ url: URL, _ write: Bool, _ body: (URL) throws -> Void) throws -> Void)? = nil) {
        self.root = root
        self.name = name ?? "folder:\(root.standardizedFileURL.path)"
        self.coordinate = coordinate ?? { url, _, body in try body(url) }
    }

    var syncDir: URL { root.appendingPathComponent(".sync", isDirectory: true) }
    var blobDir: URL { root.appendingPathComponent(".blobs", isDirectory: true) }

    // MARK: vault.json

    public struct VaultInfo: Codable, Equatable, Sendable {
        public var v: Int = 1
        public var vaultId: String
        public var vaultPublicKey: String
        public var createdAt: String
        public var encrypted: Bool
        public var relayURL: String?

        public init(vaultId: String, vaultPublicKey: String, encrypted: Bool = true, relayURL: String? = nil, createdAt: Date = Date()) {
            self.vaultId = vaultId
            self.vaultPublicKey = vaultPublicKey
            self.encrypted = encrypted
            self.relayURL = relayURL
            self.createdAt = ISO8601DateFormatter().string(from: createdAt)
        }
    }

    public func readVaultInfo() throws -> VaultInfo? {
        let url = root.appendingPathComponent("vault.json")
        var info: VaultInfo?
        try coordinate(url, false) { u in
            guard FileManager.default.fileExists(atPath: u.path) else { return }
            info = try JSONDecoder().decode(VaultInfo.self, from: Data(contentsOf: u))
        }
        return info
    }

    public func writeVaultInfo(_ info: VaultInfo) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try coordinate(root.appendingPathComponent("vault.json"), true) { try data.write(to: $0, options: .atomic) }
    }

    // MARK: SyncTransport

    public func listSegments() async throws -> [SegmentRef] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: syncDir.path) else { return [] }
        var refs: [SegmentRef] = []
        for device in try fm.contentsOfDirectory(atPath: syncDir.path) where !device.hasPrefix(".") {
            let dir = syncDir.appendingPathComponent(device, isDirectory: true)
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                // iCloud placeholders look like ".name.trv.icloud"; report them so the app downloads them.
                let name = file.hasPrefix(".") && file.hasSuffix(".icloud") ? String(file.dropFirst().dropLast(7)) : file
                if let (first, last) = Segment.parseFileName(name) {
                    refs.append(SegmentRef(device: device, first: first, last: last))
                }
            }
        }
        return refs.sorted { ($0.device, $0.first) < ($1.device, $1.first) }
    }

    func segmentURL(_ ref: SegmentRef) -> URL {
        syncDir.appendingPathComponent(ref.device, isDirectory: true)
            .appendingPathComponent(Segment.fileName(first: ref.first, last: ref.last))
    }

    public func fetchSegment(_ ref: SegmentRef) async throws -> Data {
        try read(segmentURL(ref))
    }

    public func pushSegment(_ ref: SegmentRef, data: Data) async throws {
        let url = segmentURL(ref)
        if FileManager.default.fileExists(atPath: url.path) {
            if try read(url) == data { return }
            throw TransportError.conflict("segment \(ref.key) already exists with different contents")
        }
        try writeOnce(url, data)
    }

    func blobURL(_ id: String) -> URL {
        blobDir.appendingPathComponent(String(id.prefix(2)), isDirectory: true).appendingPathComponent("\(id).trv")
    }

    public func hasBlob(_ id: String) async throws -> Bool {
        let url = blobURL(id)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(id).trv.icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    public func pushBlob(_ id: String, data: Data) async throws {
        if try await hasBlob(id) { return }
        try writeOnce(blobURL(id), data)
    }

    public func fetchBlob(_ id: String) async throws -> Data {
        try read(blobURL(id))
    }

    // MARK: Helpers

    private func read(_ url: URL) throws -> Data {
        var data: Data?
        try coordinate(url, false) { u in
            guard FileManager.default.fileExists(atPath: u.path) else { throw TransportError.notFound }
            data = try Data(contentsOf: u)
        }
        guard let data else { throw TransportError.notFound }
        return data
    }

    private func writeOnce(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinate(url, true) { u in
            // Write to a temp name then move, so readers never see half a file.
            let temp = u.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
            try data.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: u)
        }
    }
}
