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

public enum TransportError: Error, Equatable {
    case notFound
    case conflict(String)
    case http(Int, String)
    case invalidResponse
}
