import Foundation

/// Somewhere segments and attachments live: the iCloud Drive vault folder, or the Cloudflare relay.
/// Both carry exactly the same encrypted bytes (PROTOCOL.md §3–4).
public protocol SyncTransport: Sendable {
    var name: String { get }
    /// Segments this transport has that the caller may not have seen. Folder transports return all;
    /// the relay returns those after its saved cursor.
    func listSegments() async throws -> [SegmentRef]
    func fetchSegment(_ ref: SegmentRef) async throws -> Data
    func pushSegment(_ ref: SegmentRef, data: Data) async throws
    func hasBlob(_ id: String) async throws -> Bool
    func pushBlob(_ id: String, data: Data) async throws
    func fetchBlob(_ id: String) async throws -> Data
}

/// A checkpoint somewhere (PROTOCOL.md §3 "Checkpoints"), without its contents.
public struct CheckpointInfo: Codable, Sendable, Equatable {
    public var id: String
    public var device: String
    public var size: Int
    /// Unix milliseconds.
    public var createdAt: Double

    public init(id: String, device: String, size: Int, createdAt: Double) {
        self.id = id; self.device = device; self.size = size; self.createdAt = createdAt
    }
}

/// A transport that also keeps checkpoints (the relay and the iCloud folder).
public protocol CheckpointTransport: SyncTransport {
    /// Newest first.
    func listCheckpoints() async throws -> [CheckpointInfo]
    func fetchCheckpoint(_ id: String) async throws -> Data
    func pushCheckpoint(_ id: String, data: Data) async throws
}

public enum TransportError: Error, Equatable {
    case notFound
    case conflict(String)
    case http(Int, String)
    case invalidResponse
}
