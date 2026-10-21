import Foundation
import Testing
@testable import TroveCore

/// Checkpoints (PROTOCOL.md §3 "Checkpoints"), checked against the website's
/// Fixtures/checkpoint-cases.json (web/test/make-checkpoint-fixture.mjs).
@Suite struct CheckpointTests {
    struct Rec: Codable, Equatable {
        var kind: String
        var fields: [String: JSONValue]
        var texts: [String: String]
        var conflicts: [String: [String]]
        var created: String
        var updated: String
    }

    struct Fixture: Codable {
        var ops: [Op]
        var inCheckpoint: [String]
        var checkpoint: Checkpoint
        var deflated: String
        var plain: String
        var expectedAtCheckpoint: [String: Rec]
        var expected: [String: Rec]
        var restCount: Int
    }

    static func view(_ store: RecordStore) -> [String: Rec] {
        store.records.mapValues { Rec(kind: $0.kind, fields: $0.fields, texts: $0.texts, conflicts: $0.conflicts, created: $0.createdHLC, updated: $0.updatedHLC) }
    }

    static func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures/checkpoint-cases", withExtension: "json")!
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func fullReplayMatchesTheWebsite() throws {
        let f = try Self.fixture()
        var full = RecordStore()
        full.apply(f.ops)
        #expect(Self.view(full) == f.expected)
    }

    @Test func websiteCheckpointLoadsAndLaterOpsApplyLikeAFullReplay() throws {
        let f = try Self.fixture()
        #expect(try Checkpoint.decode(Data(base64URL: f.plain)!) == f.checkpoint)
        #expect(try Checkpoint.decode(Data(base64URL: f.deflated)!) == f.checkpoint)
        let inside = Set(f.inCheckpoint)
        let rest = f.ops.filter { !inside.contains($0.id) }
        #expect(rest.count == f.restCount)
        for order in [rest, rest.reversed()] {
            var store = RecordStore()
            let took = store.useBase(f.checkpoint.base)
            #expect(took)
            #expect(Self.view(store) == f.expectedAtCheckpoint)
            for op in order { store.apply([op]) }
            store.apply(f.ops) // covered or duplicates
            #expect(Self.view(store) == f.expected)
        }
    }

    @Test func swiftCheckpointsRoundTripAndStack() throws {
        let f = try Self.fixture()
        let inside = Set(f.inCheckpoint)
        var part = RecordStore()
        part.apply(f.ops.filter { inside.contains($0.id) })
        let made = Checkpoint.make(from: part, cursor: 12, device: "AAAA")
        let decoded = try Checkpoint.decode(made.encoded())
        #expect(decoded == made)
        var store = RecordStore()
        store.useBase(decoded.base)
        #expect(Self.view(store) == f.expectedAtCheckpoint)
        let rest = f.ops.filter { !inside.contains($0.id) }
        store.apply(Array(rest.prefix(rest.count / 2)))
        // A checkpoint of a checkpoint, then the other ops.
        var second = RecordStore()
        second.useBase(try Checkpoint.decode(Checkpoint.make(from: store, cursor: nil, device: "AAAA").encoded()).base)
        let tookOlder = second.useBase(decoded.base)
        #expect(!tookOlder) // an older one is not taken over a newer one
        second.apply(Array(rest.suffix(rest.count - rest.count / 2)))
        #expect(Self.view(second) == f.expected)
    }

    /// `TROVE_CHECKPOINT_FIXTURE=path swift test --filter CheckpointTests` writes the Swift-made
    /// checkpoint of the fixture's ops for web/test/checkpoint.test.mjs (web/test/fixtures/swift-checkpoint.json).
    @Test func writesTheSwiftCheckpointForTheWebsite() throws {
        let f = try Self.fixture()
        let inside = Set(f.inCheckpoint)
        var part = RecordStore()
        part.apply(f.ops.filter { inside.contains($0.id) })
        let encoded = try Checkpoint.make(from: part, cursor: 12, device: "SWIFT", createdAt: Date(timeIntervalSince1970: 1_760_000_100)).encoded()
        guard let path = ProcessInfo.processInfo.environment["TROVE_CHECKPOINT_FIXTURE"] else { return }
        let out: [String: String] = ["note": "Made by CheckpointTests.writesTheSwiftCheckpointForTheWebsite from Fixtures/checkpoint-cases.json's inCheckpoint ops.",
                                     "encoded": encoded.base64URL]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: URL(fileURLWithPath: path))
    }

    @Test func sealedWithTheSegmentKey() throws {
        let keys = VaultKeys.generate()
        let f = try Self.fixture()
        let sealed = try f.checkpoint.sealed(with: keys)
        #expect(TRV1.mode(of: sealed) == .symmetric)
        #expect(try Checkpoint.open(sealed, keys: keys) == f.checkpoint)
        #expect(throws: (any Error).self) { try Checkpoint.open(sealed, keys: VaultKeys.generate()) }
    }
}
