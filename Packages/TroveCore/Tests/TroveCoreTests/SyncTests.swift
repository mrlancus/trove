import Foundation
import Testing
@testable import TroveCore

@Suite struct HLCAndOpTests {
    @Test func hlcFormatsSortsAndIsMonotonic() {
        nonisolated(unsafe) var t: Int64 = 1_000
        var clock = HLCClock(device: "A", now: { t })
        let a = clock.tick()
        let b = clock.tick()       // same millis → counter bump
        t = 999                    // wall clock went backwards
        let c = clock.tick()
        #expect(a < b && b < c)
        #expect(a.description == "0000000001000-0000-A")
        #expect(HLC(b.description) == b)
        clock.observe(HLC(millis: 5_000, counter: 3, device: "B"))
        #expect(clock.tick() > HLC(millis: 5_000, counter: 3, device: "B"))
    }

    @Test func opJSONUsesCompactKeys() throws {
        let op = Op.set(["title": "Hi"], record: "r1", kind: "item", device: "D", seq: 1, hlc: HLC(millis: 1, counter: 0, device: "D"))
        let json = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
        #expect(json.contains("\"d\":\"D\"") && json.contains("\"r\":\"r1\"") && json.contains("\"t\":\"set\""))
        #expect(try JSONDecoder().decode(Op.self, from: Data(json.utf8)) == op)
    }
}

@Suite struct TextMergeTests {
    @Test func cleanMerges() {
        let base = "one\ntwo\nthree\nfour"
        #expect(TextMerge.merge(base: base, ours: "ONE\ntwo\nthree\nfour", theirs: "one\ntwo\nthree\nFOUR") == "ONE\ntwo\nthree\nFOUR")
        #expect(TextMerge.merge(base: base, ours: base, theirs: "x") == "x")
        #expect(TextMerge.merge(base: base, ours: "x", theirs: base) == "x")
        #expect(TextMerge.merge(base: "a\nb", ours: "a\nb\nc", theirs: "z\na\nb") == "z\na\nb\nc")
        #expect(TextMerge.merge(base: "", ours: "same", theirs: "same") == "same")
    }

    @Test func conflictingEditsReturnNil() {
        #expect(TextMerge.merge(base: "a\nb\nc", ours: "a\nX\nc", theirs: "a\nY\nc") == nil)
    }

    @Test func myersMatchesAreALongestCommonSubsequence() {
        let a = "a b c d e f".split(separator: " ")
        let b = "a x c d y f".split(separator: " ")
        let m = TextMerge.matches(a, b)
        #expect(m.compactMap { $0 }.count == 4)
        #expect(m[0] == 0 && m[2] == 2 && m[3] == 3 && m[5] == 5)
    }
}

@Suite struct RecordStoreTests {
    func ops(_ device: String, start: Int64, _ makes: [(inout Journal) -> Op]) -> [Op] {
        nonisolated(unsafe) var t = start
        var j = Journal(state: .init(device: device), now: { t += 1; return t })
        return makes.map { $0(&j) }
    }

    @Test func lastWriterWinsPerFieldInAnyOrder() {
        let a = ops("A", start: 100, [{ $0.set(["title": "A title", "tags": ["x"]], record: "r", kind: "item") }])
        let b = ops("B", start: 200, [{ $0.set(["title": "B title"], record: "r") }])
        var s1 = RecordStore(); s1.apply(a); s1.apply(b)
        var s2 = RecordStore(); s2.apply(b); s2.apply(a)
        #expect(s1.records == s2.records)
        #expect(s1.record("r")?["title"] == "B title")
        #expect(s1.record("r")?["tags"] == ["x"])
        #expect(s1.record("r")?.kind == "item")
    }

    @Test func deleteAndUndelete() {
        var store = RecordStore()
        store.apply(ops("A", start: 1, [
            { $0.set(["title": "x"], record: "r", kind: "item") },
            { $0.set(["_deleted": true], record: "r") },
        ]))
        #expect(store.visible.isEmpty)
        store.apply(ops("B", start: 50, [{ $0.set(["_deleted": false], record: "r") }]))
        #expect(store.visible.count == 1)
    }

    @Test func concurrentTextEditsMergeOrBecomeConflicts() {
        let base = ops("A", start: 10, [{ $0.text("body", value: "intro\nmiddle\nend", previous: "", record: "n", kind: "item") }])
        let editA = ops("A", start: 20, [{ j in Op.text("body", value: "INTRO\nmiddle\nend", base: "intro\nmiddle\nend".sha256Hex, record: "n", device: "A", seq: 2, hlc: HLC(millis: 20, counter: 0, device: "A")) }])
        let editB = ops("B", start: 21, [{ j in Op.text("body", value: "intro\nmiddle\nEND", base: "intro\nmiddle\nend".sha256Hex, record: "n", device: "B", seq: 1, hlc: HLC(millis: 21, counter: 0, device: "B")) }])
        var s1 = RecordStore(); s1.apply(base); s1.apply(editB); s1.apply(editA)
        var s2 = RecordStore(); s2.apply(editA + base + editB)
        #expect(s1.record("n")?.texts["body"] == "INTRO\nmiddle\nEND")
        #expect(s1.records == s2.records)

        let clash = ops("C", start: 22, [{ j in Op.text("body", value: "intro\nmiddle\nFIN", base: "intro\nmiddle\nend".sha256Hex, record: "n", device: "C", seq: 1, hlc: HLC(millis: 22, counter: 0, device: "C")) }])
        s1.apply(clash)
        #expect(s1.record("n")?.texts["body"] == "INTRO\nmiddle\nEND")
        #expect(s1.record("n")?.conflicts["body"] == ["intro\nmiddle\nFIN"])
    }

    @Test func duplicateOpsAreIgnored() {
        let a = ops("A", start: 1, [{ $0.set(["n": 1], record: "r", kind: "item") }])
        var s = RecordStore()
        s.apply(a); s.apply(a)
        #expect(s.opCount == 1)
    }
}

@Suite struct SegmentTests {
    @Test func fileNamesRoundTrip() {
        #expect(Segment.fileName(first: 1, last: 40) == "000000000001-000000000040.trv")
        #expect(Segment.parseFileName("000000000001-000000000040.trv")! == (1, 40))
        #expect(Segment.parseFileName("bad.trv") == nil)
    }

    @Test func encryptDecryptAndContiguity() throws {
        let keys = VaultKeys.generate()
        var j = Journal(state: .init(device: "DEV"))
        _ = j.set(["title": "a"], record: "1", kind: "item")
        _ = j.text("body", value: "hello", previous: "", record: "1")
        let segments = try j.takeSegments()
        #expect(segments.count == 1)
        #expect(j.pending.isEmpty)
        let seg = segments[0]
        #expect(seg.first == 1 && seg.last == 2)
        let back = try Segment.decrypt(seg.encrypted(with: keys), device: "DEV", keys: keys)
        #expect(back == seg)
        #expect(try Segment.decodeAny(seg.plaintext(), device: "DEV", keys: nil) == seg)
        #expect(throws: SegmentError.notContiguous) { try Segment(device: "DEV", ops: [seg.ops[1], seg.ops[0]]) }
    }

    @Test func largeJournalsAreCutIntoSegments() throws {
        var j = Journal(state: .init(device: "D"))
        let big = String(repeating: "x", count: 100_000)
        for i in 0..<12 { _ = j.text("body", value: big + "\(i)", previous: "", record: "r\(i)") }
        let segments = try j.takeSegments()
        #expect(segments.count >= 3)
        #expect(segments.first?.first == 1 && segments.last?.last == 12)
        for pair in zip(segments, segments.dropFirst()) { #expect(pair.0.last + 1 == pair.1.first) }
        for s in segments { #expect(try s.plaintext().count <= Segment.maxPlaintextBytes) }
    }
}

@Suite struct EngineTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func threeDevicesConvergeThroughAFolder() async throws {
        let keys = VaultKeys.generate()
        let folder = FolderTransport(root: tempDir())
        let mac = SyncEngine(device: "MAC", keys: keys, transports: [folder])
        let phone = SyncEngine(device: "PHONE", keys: keys, transports: [folder])
        let ipad = SyncEngine(device: "IPAD", keys: keys, transports: [folder])

        await mac.set(["title": "From Mac"], record: "a", kind: "item")
        await phone.set(["title": "From Phone"], record: "b", kind: "item")
        await ipad.editText("body", value: "iPad note", record: "c", kind: "item")
        for e in [mac, phone, ipad] { _ = await e.sync() }
        for e in [mac, phone, ipad] { _ = await e.sync() }

        let a = await mac.records.sorted { $0.id < $1.id }
        let b = await phone.records.sorted { $0.id < $1.id }
        let c = await ipad.records.sorted { $0.id < $1.id }
        #expect(a.count == 3)
        #expect(a == b && b == c)

        // Files are encrypted and each device wrote only its own folder.
        let refs = try await folder.listSegments()
        #expect(Set(refs.map(\.device)) == ["MAC", "PHONE", "IPAD"])
        let raw = try await folder.fetchSegment(refs[0])
        #expect(TRV1.mode(of: raw) == .symmetric)
    }

    @Test func snapshotRestoresStateAndUnpushedWork() async throws {
        let keys = VaultKeys.generate()
        let engine = SyncEngine(device: "D", keys: keys)
        await engine.set(["title": "x"], record: "r", kind: "item")
        let snap = await engine.snapshot()
        let data = try JSONEncoder().encode(snap)
        let restored = SyncEngine(device: "D", keys: keys, snapshot: try JSONDecoder().decode(SyncEngine.Snapshot.self, from: data))
        #expect(await restored.record("r")?["title"] == "x")
        // Pending op is still pushed after restore.
        let folder = FolderTransport(root: tempDir())
        await restored.addTransport(folder)
        let report = await restored.sync()
        #expect(report.pushed == 1)
        #expect(try await folder.listSegments().count == 1)
    }

    @Test func bridgeCopiesSegmentsBetweenTransports() async throws {
        let keys = VaultKeys.generate()
        let icloud = FolderTransport(root: tempDir())
        let relayStandIn = FolderTransport(root: tempDir())
        let phone = SyncEngine(device: "PHONE", keys: keys, transports: [relayStandIn])
        let mac = SyncEngine(device: "MAC", keys: keys, transports: [icloud, relayStandIn], bridge: true)
        await phone.set(["title": "only on relay"], record: "p", kind: "item")
        _ = await phone.sync()
        _ = await mac.sync()
        #expect(try await icloud.listSegments().contains { $0.device == "PHONE" })
        let ipad = SyncEngine(device: "IPAD", keys: keys, transports: [icloud])
        _ = await ipad.sync()
        #expect(await ipad.record("p")?["title"] == "only on relay")
    }

    @Test func blobsAreEncryptedAndDeduplicated() async throws {
        let keys = VaultKeys.generate()
        let folder = FolderTransport(root: tempDir())
        let engine = SyncEngine(device: "D", keys: keys, transports: [folder])
        let data = Data("a photo".utf8)
        let id1 = try await engine.storeBlob(data)
        let id2 = try await engine.storeBlob(data)
        #expect(id1 == id2)
        #expect(try await engine.loadBlob(id1) == data)
        #expect(try await folder.fetchBlob(id1) != data)
    }

    @Test func unencryptedVaultWritesReadableJSONL() async throws {
        let folder = FolderTransport(root: tempDir())
        let engine = SyncEngine(device: "D", keys: nil, encrypted: false, transports: [folder])
        await engine.set(["title": "plain"], record: "r", kind: "item")
        _ = await engine.sync()
        let raw = try await folder.fetchSegment(try await folder.listSegments()[0])
        #expect(String(decoding: raw, as: UTF8.self).contains("\"plain\""))
    }

    @Test func vaultInfoRoundTrip() throws {
        let folder = FolderTransport(root: tempDir())
        #expect(try folder.readVaultInfo() == nil)
        let info = FolderTransport.VaultInfo(vaultId: "v1", vaultPublicKey: "pk")
        try folder.writeVaultInfo(info)
        #expect(try folder.readVaultInfo() == info)
    }
}
