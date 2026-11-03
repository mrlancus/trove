import XCTest
@testable import TroveCore

/// The change feed (docs/MASTER_PLAN.md P1): readers learn exactly which records changed.
final class ChangeFeedTests: XCTestCase {
    func makeLibrary() -> Library {
        Library(engine: SyncEngine(device: "dev-a", keys: nil, encrypted: false))
    }

    func testFirstLookIsEverythingThenOnlyWhatChanged() async throws {
        let lib = makeLibrary()
        let a = await lib.addNote(title: "Alpha", body: "one")
        let first = await lib.engine.changes(since: -1)
        XCTAssertTrue(first.all)
        var none = await lib.engine.changes(since: first.token)
        XCTAssertTrue(none.isEmpty)
        let b = await lib.addNote(title: "Beta", body: "two")
        let next = await lib.engine.changes(since: first.token)
        XCTAssertFalse(next.all)
        XCTAssertEqual(next.ids("item"), [b])
        XCTAssertFalse(next.ids("item").contains(a))
        XCTAssertTrue(next.touches(["item"]))
        XCTAssertFalse(next.touches(["folder"]))
        none = await lib.engine.changes(since: next.token)
        XCTAssertTrue(none.isEmpty)
    }

    func testItemsStayInOrderAcrossIncrementalChanges() async throws {
        let clock = Clock()
        let lib = Library(engine: SyncEngine(device: "dev-a", keys: nil, encrypted: false), now: { clock.next() })
        var ids: [String] = []
        for i in 0..<20 { ids.append(await lib.addNote(title: "Note \(i)", body: "body \(i)")) }
        let full = await lib.items()
        XCTAssertEqual(full.map(\.id), ids.reversed())
        // Edit one, delete one, add one: the list must equal a fresh, fully sorted read.
        await lib.update(ids[5], [Field.title: .string("Renamed")])
        await lib.delete(ids[7])
        let added = await lib.addNote(title: "Newest", body: "x")
        let incremental = await lib.items()
        let fresh = await Library.freshItems(lib)
        XCTAssertEqual(incremental.map(\.id), fresh.map(\.id))
        XCTAssertEqual(incremental.first?.id, added)
        XCTAssertFalse(incremental.contains { $0.id == ids[7] })
        XCTAssertEqual(incremental.first { $0.id == ids[5] }?.title, "Renamed")
    }

    func testItemChangesReportsChangedAndRemoved() async throws {
        let lib = makeLibrary()
        let a = await lib.addNote(title: "A", body: "")
        let b = await lib.addNote(title: "B", body: "")
        let start = await lib.itemChanges(since: -1)
        XCTAssertTrue(start.all)
        await lib.update(a, [Field.title: .string("A2")])
        await lib.delete(b)
        let c = await lib.itemChanges(since: start.token)
        XCTAssertFalse(c.all)
        XCTAssertEqual(c.changed.map(\.id), [a])
        XCTAssertEqual(c.removed, [b])
    }

    func testSearchStaysCorrectIncrementally() async throws {
        let lib = makeLibrary()
        let a = await lib.addNote(title: "Photosynthesis", body: "chlorophyll light")
        var hits = await lib.search("chlorophyll").map(\.id)
        XCTAssertEqual(hits, [a])
        await lib.update(a, [Field.title: .string("Respiration")])
        hits = await lib.search("respiration").map(\.id)
        XCTAssertEqual(hits, [a])
        hits = await lib.search("photosynthesis").map(\.id)
        XCTAssertEqual(hits, [])
        await lib.delete(a)
        hits = await lib.search("respiration").map(\.id)
        XCTAssertEqual(hits, [])
    }

    func testRebuildReportsEverything() {
        var store = RecordStore()
        let late = Op(device: "d", seq: 2, hlc: "0000000000002-0000-d", record: "r1", recordKind: "item", type: .set, fields: ["title": .string("b")], text: nil)
        let early = Op(device: "d", seq: 1, hlc: "0000000000001-0000-d", record: "r2", recordKind: "item", type: .set, fields: ["title": .string("a")], text: nil)
        store.apply([late])
        let token = store.changeVersion
        store.apply([early])   // older than what's applied: the store rebuilds
        XCTAssertTrue(store.changes(since: token).all)
    }
}

/// A clock that ticks one second per call, so items get distinct, ordered dates.
final class Clock: @unchecked Sendable {
    private var t = 1_700_000_000.0
    private let lock = NSLock()
    func next() -> Date { lock.withLock { t += 1; return Date(timeIntervalSince1970: t) } }
}

extension Library {
    /// The old way: every item decoded and sorted, to compare with the incremental list.
    static func freshItems(_ lib: Library) async -> [Item] {
        await lib.engine.records(kind: "item").filter { !$0.isStrayItem }.map(Item.init).sorted(by: Library.newestFirst)
    }
}

/// The relay's batched segment download (MASTER_PLAN P10, PROTOCOL.md §4 `segments/batch`).
final class SegmentBatchTests: XCTestCase {
    func testSplitsLengthsAndMissing() throws {
        var d = Data()
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
        d += le32(3) + Data("abc".utf8) + le32(0xFFFF_FFFF) + le32(0)
        let parts = try RelayClient.splitBatch(d, count: 3)
        XCTAssertEqual(parts, [Data("abc".utf8), nil, Data()])
        XCTAssertThrowsError(try RelayClient.splitBatch(le32(10) + Data("short".utf8), count: 1))
    }
}
