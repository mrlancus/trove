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
