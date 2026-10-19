import Foundation

/// An immutable batch of consecutive ops from one device: the unit stored in iCloud and on the relay.
public struct Segment: Sendable, Equatable {
    public static let maxPlaintextBytes = 512 * 1024

    public let device: String
    public let first: Int
    public let last: Int
    public let ops: [Op]

    public init(device: String, ops: [Op]) throws {
        guard let firstOp = ops.first, let lastOp = ops.last else { throw SegmentError.empty }
        for (offset, op) in ops.enumerated() {
            guard op.device == device, op.seq == firstOp.seq + offset else { throw SegmentError.notContiguous }
        }
        self.device = device
        self.first = firstOp.seq
        self.last = lastOp.seq
        self.ops = ops
    }

    public var fileName: String { Self.fileName(first: first, last: last) }

    public static func fileName(first: Int, last: Int) -> String {
        func pad(_ n: Int) -> String { let s = String(n); return String(repeating: "0", count: max(0, 12 - s.count)) + s }
        return "\(pad(first))-\(pad(last)).trv"
    }

    /// Parses `000000000001-000000000040.trv` → (1, 40).
    public static func parseFileName(_ name: String) -> (first: Int, last: Int)? {
        guard name.hasSuffix(".trv") else { return nil }
        let parts = name.dropLast(4).split(separator: "-")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= a else { return nil }
        return (a, b)
    }

    // MARK: Encoding

    public func plaintext() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for op in ops {
            out.append(try encoder.encode(op))
            out.append(0x0A)
        }
        return out
    }

    public static func decode(plaintext: Data, device: String) throws -> Segment {
        let decoder = JSONDecoder()
        let ops = try plaintext.split(separator: 0x0A).map { try decoder.decode(Op.self, from: Data($0)) }
        return try Segment(device: device, ops: ops)
    }

    public func encrypted(with keys: VaultKeys) throws -> Data {
        try TRV1.encrypt(plaintext(), key: keys.segmentKey)
    }

    public static func decrypt(_ data: Data, device: String, keys: VaultKeys) throws -> Segment {
        try decode(plaintext: TRV1.decrypt(data, key: keys.segmentKey), device: device)
    }

    /// For vaults created with encryption turned off (files readable in Finder / Files).
    public static func decodeAny(_ data: Data, device: String, keys: VaultKeys?) throws -> Segment {
        if TRV1.mode(of: data) != nil {
            guard let keys else { throw TRV1.Failure.missingKey }
            return try decrypt(data, device: device, keys: keys)
        }
        return try decode(plaintext: data, device: device)
    }
}

public enum SegmentError: Error, Equatable { case empty, notContiguous, tooLarge }

/// Reference to a segment somewhere (folder or relay) without its contents.
public struct SegmentRef: Hashable, Sendable {
    public let device: String
    public let first: Int
    public let last: Int
    public var key: String { "\(device)/\(first)" }

    public init(device: String, first: Int, last: Int) {
        self.device = device
        self.first = first
        self.last = last
    }
}
