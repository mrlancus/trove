import Foundation
import Testing
@testable import TroveCore

/// The apps' SQLite local copy and checkpoints through the sync engine (docs/ROADMAP.md §3.1).
@Suite struct LocalDatabaseTests {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Counts the segments a transport hands out.
    final class Counting: SyncTransport, CheckpointTransport, @unchecked Sendable {
        let inner: FolderTransport
        private let lock = NSLock()
        private var _fetched = 0
        var fetched: Int { lock.withLock { _fetched } }
        init(_ inner: FolderTransport) { self.inner = inner }
        var name: String { inner.name }
        func listSegments() async throws -> [SegmentRef] { try await inner.listSegments() }
        func fetchSegment(_ ref: SegmentRef) async throws -> Data {
            lock.withLock { _fetched += 1 }
            return try await inner.fetchSegment(ref)
        }
        func pushSegment(_ ref: SegmentRef, data: Data) async throws { try await inner.pushSegment(ref, data: data) }
        func hasBlob(_ id: String) async throws -> Bool { try await inner.hasBlob(id) }
        func pushBlob(_ id: String, data: Data) async throws { try await inner.pushBlob(id, data: data) }
        func fetchBlob(_ id: String) async throws -> Data { try await inner.fetchBlob(id) }
        func listCheckpoints() async throws -> [CheckpointInfo] { try await inner.listCheckpoints() }
        func fetchCheckpoint(_ id: String) async throws -> Data { try await inner.fetchCheckpoint(id) }
        func pushCheckpoint(_ id: String, data: Data) async throws { try await inner.pushCheckpoint(id, data: data) }
    }

    static func view(_ records: [Record]) -> [String: String] {
        var out: [String: String] = [:]
        for r in records { out[r.id] = "\(r.kind)|\(r["title"]?.string ?? "")|\(r.texts["body"] ?? "")" }
        return out
    }

    @Test func savesOnlyWhatChangedAndReopens() async throws {
        let dir = Self.tempDir()
        let keys = VaultKeys.generate()
        let engine = SyncEngine(device: "MAC", keys: keys)
        for i in 0..<20 { await engine.set(["title": .string("note \(i)"), "kind": "note", "createdAt": 1], record: "n\(i)", kind: "item") }
        _ = await engine.editText("body", value: "hello", record: "n1")
        let db = try LocalDatabase(url: dir.appendingPathComponent("vault.sqlite"))
        #expect(try db.load() == nil)
        let first = await engine.takeSaveDelta()
        #expect(first.rewrite && first.newOps.count == 21)
        try db.save(first)
        await engine.set(["title": "changed"], record: "n2")
        let second = await engine.takeSaveDelta()
        #expect(!second.rewrite && second.newOps.count == 1)
        try db.save(second)
        #expect(try db.opCount() == 22)

        let snapshot = try #require(try db.load())
        let reopened = SyncEngine(device: "MAC", keys: keys, snapshot: snapshot)
        #expect(Self.view(await reopened.records) == Self.view(await engine.records))
        #expect(snapshot.pending.count == 22) // never synced: all still to push
        await reopened.markSaved()
        #expect(await reopened.takeSaveDelta().newOps.isEmpty)
    }

    @Test func aNewDeviceStartsFromACheckpointAndKeepsIt() async throws {
        let dir = Self.tempDir()
        let vault = dir.appendingPathComponent("vault")
        let keys = VaultKeys.generate()
        let a = SyncEngine(device: "AAAA", keys: keys, transports: [FolderTransport(root: vault, name: "icloud")])
        for i in 0..<12 {
            await a.set(["title": .string("note \(i)"), "kind": "note", "createdAt": 1], record: "n\(i)", kind: "item")
            _ = await a.editText("body", value: "body \(i)", record: "n\(i)")
            _ = await a.sync()
        }
        let wrote = await a.writeCheckpoint()
        #expect(wrote.errors.isEmpty)
        #expect(wrote.wroteCheckpoint != nil)
        #expect(await a.checkpointId == wrote.wroteCheckpoint)
        await a.set(["title": "after"], record: "n0")
        _ = await a.sync()
        #expect(try await FolderTransport(root: vault, name: "x").listCheckpoints().count == 1)

        // B: one checkpoint plus the one segment after it, not 13 segments.
        let counting = Counting(FolderTransport(root: vault, name: "icloud"))
        let b = SyncEngine(device: "BBBB", keys: keys, transports: [counting])
        let report = await b.sync()
        #expect(report.errors.isEmpty)
        #expect(report.loadedCheckpoint != nil)
        #expect(counting.fetched == 1)
        #expect(Self.view(await b.records) == Self.view(await a.records))

        // Its SQLite copy holds the checkpoint and only the ops after it.
        let db = try LocalDatabase(url: dir.appendingPathComponent("b.sqlite"))
        try db.save(await b.takeSaveDelta())
        #expect(try db.opCount() == 1)
        let snapshot = try #require(try db.load())
        #expect(snapshot.base != nil)
        let reopened = SyncEngine(device: "BBBB", keys: keys, transports: [counting], snapshot: snapshot)
        #expect(Self.view(await reopened.records) == Self.view(await a.records))
        _ = await reopened.sync()
        #expect(counting.fetched == 1, "nothing new to download")

        // A's own copy adopted its checkpoint too: a save drops the ops it covers.
        let dbA = try LocalDatabase(url: dir.appendingPathComponent("a.sqlite"))
        try dbA.save(await a.takeSaveDelta())
        #expect(try dbA.opCount() == 1)
        // Edits keep flowing both ways.
        await reopened.set(["title": "from b"], record: "n5")
        _ = await reopened.sync()
        _ = await a.sync()
        #expect(await a.record("n5")?["title"]?.string == "from b")
    }

    @Test func legacyJSONSnapshotsStillOpenAndMoveIntoTheDatabase() async throws {
        let keys = VaultKeys.generate()
        let engine = SyncEngine(device: "MAC", keys: keys)
        await engine.set(["title": "old", "kind": "note", "createdAt": 1], record: "n1", kind: "item")
        // A snapshot as older apps wrote it (no base, no checkpoint time).
        let json = try JSONEncoder().encode(await engine.snapshot())
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains("\"base\""))
        let old = try JSONDecoder().decode(SyncEngine.Snapshot.self, from: json)
        let migrated = SyncEngine(device: "MAC", keys: keys, snapshot: old)
        let db = try LocalDatabase(url: Self.tempDir().appendingPathComponent("v.sqlite"))
        try db.save(await migrated.takeSaveDelta())
        let back = SyncEngine(device: "MAC", keys: keys, snapshot: try db.load())
        #expect(await back.record("n1")?["title"]?.string == "old")
    }
}
