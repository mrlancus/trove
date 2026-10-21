import Foundation
import Testing
@testable import TroveCore

/// Timings for the hot paths (docs/ROADMAP.md §3.6), on a seeded synthetic vault like
/// web/test/bench.mjs: 50,000 items, 100,000 strokes on 500 pages. Off unless TROVE_BENCH is set:
///   TROVE_BENCH=1 swift test --filter Benchmarks
/// TROVE_BENCH_SCALE=0.1 makes the vault smaller; TROVE_BENCH_OUT=<file> writes the numbers as JSON.
/// They print and are written, not gated: CI machines vary too much for a fixed Swift baseline yet.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TROVE_BENCH"] != nil))
struct Benchmarks {
    static let scale = Double(ProcessInfo.processInfo.environment["TROVE_BENCH_SCALE"] ?? "") ?? 1
    static let items = Int(50_000 * scale)
    static let pages = max(1, Int(500 * scale))
    static let strokesPerPage = 200
    static let words = ["plum", "jam", "cardamom", "river", "map", "lecture", "limits", "physics", "draft", "budget",
                        "invoice", "recipe", "garden", "ticket", "train", "meeting", "notes", "idea", "sketch", "chapter"]

    /// A small seeded generator (SplitMix64), so every run builds the same vault.
    struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func word() -> String { Benchmarks.words[Int(next() % UInt64(Benchmarks.words.count))] }
    }

    static func makeOps() -> [Op] {
        var random = Seeded(state: 42)
        var ops: [Op] = []
        ops.reserveCapacity(items + pages * strokesPerPage + 1)
        var seq = 0
        func hlc() -> String {
            seq += 1
            return HLC(millis: 1_700_000_000_000 + Int64(seq), counter: 0, device: "BENCH").description
        }
        for i in 0..<items {
            let title = (0..<4).map { _ in random.word() }.joined(separator: " ")
            let fields: [String: JSONValue] = [
                "kind": .string(i % 3 == 0 ? "link" : "note"), "title": .string(title),
                "tags": .array([.string(random.word())]), "source": .string("web"),
            ]
            ops.append(Op(device: "BENCH", seq: seq + 1, hlc: hlc(), record: "item-\(i)", recordKind: "item", type: .set, fields: fields, text: nil))
        }
        ops.append(Op(device: "BENCH", seq: seq + 1, hlc: hlc(), record: "notebook", recordKind: "item", type: .set,
                      fields: ["kind": .string("sketch"), "title": .string("Notebook"), "pages": .number(Double(pages))], text: nil))
        var n = 0
        for page in 0..<pages {
            for _ in 0..<strokesPerPage {
                var x = random.unit() * 700 + 30, y = random.unit() * 950 + 30
                var points: [InkPoint] = []
                for k in 0..<(20 + Int(random.next() % 40)) {
                    x += random.unit() * 6 - 3
                    y += random.unit() * 6 - 3
                    points.append(InkPoint(x: x, y: y, pressure: 0.5 + random.unit() * 0.5, t: Double(k) * 0.008))
                }
                n += 1
                let fields: [String: JSONValue] = [
                    "on": .string("notebook"), "layer": .string(""), "page": .string("p\(page)"), "tool": .string("pen"),
                    "color": .string("#1c1c1e"), "width": .number(2), "points": .string(InkPoints.encode(points)), "createdAt": .number(Double(n)),
                ]
                ops.append(Op(device: "BENCH", seq: seq + 1, hlc: hlc(), record: "stroke-\(n)", recordKind: "stroke", type: .set, fields: fields, text: nil))
            }
        }
        return ops
    }

    /// Median milliseconds of `runs` runs.
    static func time(_ runs: Int = 3, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<runs {
            let d = clock.measure(body)
            times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        return times.sorted()[times.count / 2]
    }

    @Test func coreHotPaths() throws {
        let ops = Self.makeOps()
        var results: [String: Double] = [:]

        var store = RecordStore()
        results["recordStoreApply"] = Self.time { var s = RecordStore(); s.apply(ops); store = s }
        #expect(store.visible(kind: "stroke").count == Self.pages * Self.strokesPerPage)

        let items = store.visible(kind: "item").map(Item.init)
        var index = SearchIndex()
        results["searchIndexBuild"] = Self.time(1) {
            var i = SearchIndex()
            for item in items { i.update(item) }
            i.prepare()
            index = i
        }
        var hits = 0
        results["searchKeystrokes"] = Self.time(5) {
            for query in ["p", "pl", "plu", "plum", "plum j", "plum ja", "plum jam"] { hits += index.search(SearchQuery.parse(query)).count }
        }
        #expect(hits > 0)

        let strokes = store.visible(kind: "stroke")
        var decoded = 0
        results["decodeAllStrokes"] = Self.time(2) {
            decoded = 0
            for r in strokes { decoded += InkPoints.decode(r["points"]?.string ?? "").count }
        }
        #expect(decoded > 0)
        results["notebookPage"] = Self.time(5) {
            let page = store.ink(on: "notebook").filter { $0["page"]?.string == "p0" }
            decoded = page.map { InkPoints.decode($0["points"]?.string ?? "").count }.reduce(0, +)
        }

        let page = store.ink(on: "notebook").filter { $0["page"]?.string == "p0" }.map { InkPoints.decode($0["points"]?.string ?? "") }
        var random = Seeded(state: 7)
        let path = (0..<100).map { _ in InkPoint(x: random.unit() * 760, y: random.unit() * 1010) }
        var touched = 0
        results["eraserHits"] = Self.time(5) {
            touched = 0
            for p in path { for s in page where InkGeometry.hits(s, width: 2, x: p.x, y: p.y, radius: 8) { touched += 1 } }
        }
        results["partialErase"] = Self.time(5) {
            for s in page { _ = InkGeometry.erase(s, along: Array(path.prefix(20)), radius: 8) }
        }

        let lines = results.keys.sorted().map { "  \($0.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%9.1f", results[$0]!)) ms" }
        print("TroveCore benchmarks (\(ops.count) ops, scale \(Self.scale)):\n" + lines.joined(separator: "\n"))
        if let out = ProcessInfo.processInfo.environment["TROVE_BENCH_OUT"] {
            let payload: [String: Any] = ["scale": Self.scale, "ops": ops.count, "metrics": results]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }
}
