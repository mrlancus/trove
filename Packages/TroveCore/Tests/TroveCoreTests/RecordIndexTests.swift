import Foundation
import Testing
@testable import TroveCore

/// The record store's indexes (by kind, ink by item) stay right through deletes and rebuilds.
@Suite struct RecordIndexTests {
    @Test func indexesByKindAndInkByItem() {
        var store = RecordStore()
        var seq = 0
        func op(_ hlc: String, _ record: String, _ kind: String?, _ fields: [String: JSONValue]) -> Op {
            seq += 1
            return Op(device: "D", seq: seq, hlc: hlc, record: record, recordKind: kind, type: .set, fields: fields, text: nil)
        }
        store.apply([
            op("0001", "a", "stroke", ["on": .string("s1")]),
            op("0002", "b", "stroke", ["on": .string("s2")]),
            op("0003", "c", "element", ["on": .string("s1")]),
            op("0004", "i", "item", ["kind": .string("note")]),
        ])
        #expect(Set(store.ink(on: "s1").map(\.id)) == ["a", "c"])
        #expect(store.visible(kind: "stroke").count == 2)
        #expect(store.stamp(of: ["stroke"]) == (2, "0002"))
        store.apply([op("0005", "a", nil, ["_deleted": .bool(true)])])
        #expect(store.ink(on: "s1").map(\.id) == ["c"])
        #expect(store.stamp(of: ["stroke"]) == (2, "0005"))
        // An older op arriving late rebuilds everything: the indexes must match.
        store.apply([op("0000", "z", "stroke", ["on": .string("s1")])])
        #expect(Set(store.ink(on: "s1").map(\.id)) == ["c", "z"])
        #expect(store.visible(kind: "item").map(\.id) == ["i"])
        #expect(store.stamp(of: ["stroke"]) == (3, "0005"))
    }
}

/// The page index (`RecordStore.ink(on:layer:pageKey:)`, docs/PERF_AUDIT.md B2) always says what a
/// scan of the item's ink would: through page moves, layer changes, deletes, late ops and rebuilds.
@Suite struct InkPageIndexTests {
    static func scan(_ store: RecordStore, _ on: String, _ layer: String, _ page: String) -> Set<String> {
        Set(store.ink(on: on).filter { $0.fields["on"]?.string == on && ($0.fields["layer"]?.string ?? "") == layer && InkPage.key($0.fields["page"]) == page }.map(\.id))
    }

    @Test func matchesAScanThroughRandomEdits() {
        var random = TroveGen.Seeded(11)
        var store = RecordStore()
        var seq = 0
        let pages = ["0", "1", "2"], layers = ["", "att"], items = ["s1", "s2"]
        func check() {
            for on in items { for layer in layers { for page in pages {
                #expect(Set(store.ink(on: on, layer: layer, pageKey: page).map(\.id)) == Self.scan(store, on, layer, page))
            } } }
        }
        for step in 0..<400 {
            seq += 1
            let id = "k\(random.int(40))"
            var fields: [String: JSONValue] = [:]
            switch random.int(5) {
            case 0: fields["_deleted"] = .bool(random.int(2) == 0)
            case 1: fields["page"] = random.int(2) == 0 ? .string(pages[random.int(3)]) : .number(Double(random.int(3)))
            case 2: fields["layer"] = .string(layers[random.int(2)])
            default: fields = ["on": .string(items[random.int(2)]), "page": .string(pages[random.int(3)]), "layer": .string(layers[random.int(2)])]
            }
            // Now and then an op from the past, which rebuilds the store.
            let millis = step % 37 == 36 ? Int64(random.int(step)) : Int64(step * 10)
            let hlc = HLC(millis: 1_000 + millis, counter: seq, device: "D").description
            store.apply([Op(device: "D", seq: seq, hlc: hlc, record: id, recordKind: random.int(4) == 0 ? "element" : "stroke", type: .set, fields: fields, text: nil)])
            if step % 20 == 0 { check() }
        }
        check()
    }

    @Test func libraryReadsOnePageFromTheIndex() async {
        let engine = SyncEngine(device: "A", keys: nil, encrypted: false)
        let library = Library(engine: engine)
        for page in ["0", "1"] {
            for n in 0..<3 {
                await library.addStroke(on: "nb", pageKey: page, tool: .pen, color: "#000", width: 2, points: [InkPoint(x: Double(n), y: 0)])
            }
        }
        let strokes = await library.strokes(on: "nb", pageKey: "1")
        #expect(strokes.count == 3)
        #expect(strokes.allSatisfy { (s: InkStroke) -> Bool in s.pageKey == "1" })
        // Oldest first, as the editor draws them.
        let times: [Double] = strokes.map { (s: InkStroke) -> Double in s.record[InkStroke.Field.createdAt]?.number ?? 0 }
        let sortedTimes: [Double] = times.sorted()
        #expect(times == sortedTimes)
    }
}

@Suite struct InkByItemTests {
    /// A stroke moved to another item (or whose kind changes) leaves the first item's ink.
    @Test func movingInkLeavesTheOldItem() {
        var store = RecordStore()
        func op(_ seq: Int, _ fields: [String: JSONValue], kind: String = "stroke") -> Op {
            Op(device: "D", seq: seq, hlc: HLC(millis: 1_000 + Int64(seq), counter: 0, device: "D").description, record: "k", recordKind: kind, type: .set, fields: fields, text: nil)
        }
        store.apply([op(1, ["on": .string("a"), "page": .string("0")])])
        store.apply([op(2, ["on": .string("b")])])
        #expect(store.ink(on: "a").isEmpty)
        #expect(store.ink(on: "b").map(\.id) == ["k"])
        #expect(store.ink(on: "a", layer: "", pageKey: "0").isEmpty)
        #expect(store.ink(on: "b", layer: "", pageKey: "0").map(\.id) == ["k"])
        store.apply([op(3, [:], kind: "item")])
        #expect(store.ink(on: "b").isEmpty)
    }
}
