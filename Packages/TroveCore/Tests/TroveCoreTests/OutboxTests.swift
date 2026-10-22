import Foundation
import Testing
@testable import TroveCore

/// Segments not yet pushed when the app quit are pushed again after it starts, each no bigger than
/// when it was cut (the relay refuses bodies over 1 MiB with 413).
@Suite struct OutboxTests {
    /// Refuses pushes while `down`, like a relay that can't be reached; keeps what it was given.
    final class Flaky: SyncTransport, @unchecked Sendable {
        let name = "relay"
        private let lock = NSLock()
        private var _down = true
        private var _pushed: [String: Data] = [:]
        var down: Bool {
            get { lock.withLock { _down } }
            set { lock.withLock { _down = newValue } }
        }
        var pushed: [String: Data] { lock.withLock { _pushed } }
        struct Offline: Error {}
        func listSegments() async throws -> [SegmentRef] { [] }
        func fetchSegment(_ ref: SegmentRef) async throws -> Data { throw Offline() }
        func pushSegment(_ ref: SegmentRef, data: Data) async throws {
            if down { throw Offline() }
            if data.count > 1024 * 1024 { throw Offline() } // the relay's limit
            lock.withLock { _pushed[ref.key] = data }
        }
        func hasBlob(_ id: String) async throws -> Bool { true }
        func pushBlob(_ id: String, data: Data) async throws {}
        func fetchBlob(_ id: String) async throws -> Data { throw Offline() }
    }

    @Test func restartedOutboxKeepsSegmentsSmall() async throws {
        let keys = VaultKeys.generate()
        let relay = Flaky()
        let engine = SyncEngine(device: "D", keys: keys, transports: [relay])
        let text = String(repeating: "lorem ipsum ", count: 9_000) // ~100 KB per note
        for i in 0..<20 { await engine.set(["title": .string("Note \(i)"), "kind": .string("note")], record: "n\(i)", kind: "item")
            await engine.editText("body", value: "\(i) " + text, record: "n\(i)", kind: "item") }
        _ = await engine.sync() // cut into segments, none pushed
        let snapshot = await engine.snapshot()
        #expect(snapshot.unpushed["relay"]?.count ?? 0 >= 3)

        // The app starts again: the outbox is rebuilt from the snapshot.
        let again = SyncEngine(device: "D", keys: keys, transports: [relay], snapshot: snapshot)
        relay.down = false
        let report = await again.sync()
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(relay.pushed.count == snapshot.unpushed["relay"]?.count)
        #expect(relay.pushed.values.allSatisfy { $0.count <= 1024 * 1024 })
        // Every note made it, with its text.
        var seen: Set<String> = []
        for data in relay.pushed.values {
            let seg = try Segment.decodeAny(data, device: "D", keys: keys)
            for op in seg.ops { seen.insert(op.record) }
        }
        #expect(seen == Set((0..<20).map { "n\($0)" }))
        #expect(await again.snapshot().unpushed["relay"]?.isEmpty ?? true)
    }

    /// Like the relay: one segment per start, a different one at the same start refused with 409 and its end.
    final class Strict: SyncTransport, @unchecked Sendable {
        let name = "relay"
        private let lock = NSLock()
        private var held: [Int: (last: Int, data: Data)] = [:]
        var segments: [Int: Int] { lock.withLock { held.mapValues(\.last) } }
        func preload(first: Int, last: Int) { lock.withLock { held[first] = (last, Data("earlier upload".utf8)) } }
        func listSegments() async throws -> [SegmentRef] { [] }
        func fetchSegment(_ ref: SegmentRef) async throws -> Data { throw TransportError.notFound }
        func pushSegment(_ ref: SegmentRef, data: Data) async throws {
            try lock.withLock {
                if let h = held[ref.first] {
                    if h.data == data { return }
                    throw TransportError.conflict(#"{"error":"a different segment with this start already exists","last":\#(h.last)}"#)
                }
                held[ref.first] = (ref.last, data)
            }
        }
        func hasBlob(_ id: String) async throws -> Bool { true }
        func pushBlob(_ id: String, data: Data) async throws {}
        func fetchBlob(_ id: String) async throws -> Data { throw TransportError.notFound }
    }

    /// An upload that went through but wasn't recorded is sealed again with new bytes and refused for
    /// ever ("relay push …: conflict"). Now the ops the relay already has count as sent, and the rest
    /// go up as a new segment.
    @Test func aConflictingSegmentIsNotRetriedForEver() async throws {
        let relay = Strict()
        let engine = SyncEngine(device: "D", keys: .generate(), transports: [relay])
        for i in 1...5 { await engine.set(["title": .string("Note \(i)")], record: "n\(i)", kind: "item") }
        relay.preload(first: 1, last: 3) // ops 1-3 arrived earlier
        let report = await engine.sync()
        #expect(report.errors.isEmpty, "\(report.errors)")
        let second = await engine.sync()
        #expect(second.errors.isEmpty && second.pushed == 1)
        #expect(relay.segments == [1: 3, 4: 5])
        #expect(await engine.snapshot().unpushed["relay"]?.isEmpty ?? true)

        // Everything already there: nothing more to send.
        let other = Strict()
        let e2 = SyncEngine(device: "E", keys: .generate(), transports: [other])
        await e2.set(["title": .string("x")], record: "x", kind: "item")
        other.preload(first: 1, last: 4)
        #expect(await e2.sync().errors.isEmpty)
        #expect(await e2.snapshot().unpushed["relay"]?.isEmpty ?? true)
    }
}
