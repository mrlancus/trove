import Foundation
import Testing
@testable import TroveCore

/// Timings for the hot paths (docs/ROADMAP.md §3.6, docs/PERF_AUDIT.md), on trove-gen's budget vault
/// (`TroveGen.Size.full`: 50,000 items, 50,000 clips, 100,000 strokes on 500 pages, a 10k-stroke whiteboard). Off unless TROVE_BENCH is set:
///   TROVE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter Benchmarks
/// TROVE_BENCH_SCALE=0.1 makes the vault smaller; TROVE_BENCH_OUT=<file> writes the numbers as JSON.
/// They print and are written, not gated: CI machines vary too much for a fixed Swift baseline yet.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TROVE_BENCH"] != nil))
struct Benchmarks {
    static let scale = Double(ProcessInfo.processInfo.environment["TROVE_BENCH_SCALE"] ?? "") ?? 1
    /// The budget vault from trove-gen (`TroveGen.Size.full`), scaled.
    static let size = TroveGen.Size.full.scaled(scale)
    typealias Seeded = TroveGen.Seeded

    static func makeOps() -> [Op] { TroveGen.ops(size) }

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
        #expect(store.visible(kind: "stroke").count == Self.size.notebookPages * Self.size.strokesPerPage + Self.size.whiteboardStrokes)

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
            let page = store.ink(on: TroveGen.notebookId).filter { $0["page"]?.string == "0" }
            decoded = page.map { InkPoints.decode($0["points"]?.string ?? "").count }.reduce(0, +)
        }

        let page = store.ink(on: TroveGen.notebookId).filter { $0["page"]?.string == "0" }.map { InkPoints.decode($0["points"]?.string ?? "") }
        var random = Seeded(7)
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
