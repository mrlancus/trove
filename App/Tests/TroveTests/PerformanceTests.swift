import XCTest
import TroveCore
@testable import Trove

/// Performance on the macOS runner with trove-gen vaults (docs/PERF_AUDIT.md §2). Times on shared
/// CI machines are trends, not budgets; counts are exact and fail on any change. The medians are
/// also written to $TROVE_PERF_OUT (a JSON file) for scripts/ci-app-tests.sh to keep.
final class PerformanceTests: XCTestCase {
    static let size = TroveGen.Size.small

    static func clock(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func record(_ name: String, _ ms: Double) {
        guard let path = ProcessInfo.processInfo.environment["TROVE_PERF_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Double] ?? [:]
        all[name] = ms
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    func testMaterialiseAVault() {
        let ops = TroveGen.ops(Self.size)
        var times: [Double] = []
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            times.append(Self.clock { var s = RecordStore(); s.apply(ops) })
        }
        Self.record("materialiseSmall", times.sorted()[times.count / 2])
    }

    func testSearchKeystrokes() {
        var store = RecordStore()
        store.apply(TroveGen.ops(Self.size))
        var index = SearchIndex()
        for r in store.visible(kind: "item") { index.update(Item(r)) }
        index.prepare()
        var times: [Double] = []
        for phrase in ["plum jam", "momentum", "lecture notes", "orbit"] {
            for end in phrase.indices.dropFirst() + [phrase.endIndex] {
                let q = SearchQuery.parse(String(phrase[..<end]))
                times.append(Self.clock { _ = index.search(q) })
            }
        }
        times.sort()
        Self.record("searchKeyP90Small", times[Int(Double(times.count) * 0.9)])
    }

    /// Opening one page reads only that page's strokes (PERF_AUDIT B2): a count, so it's exact.
    func testOnePageReadsOnlyItsStrokes() {
        var store = RecordStore()
        store.apply(TroveGen.ops(TroveGen.Size.tiny))
        XCTAssertEqual(store.ink(on: TroveGen.notebookId, layer: "", pageKey: "1").count, TroveGen.Size.tiny.strokesPerPage)
    }

    func testTroveGenIsFastEnoughForUITests() {
        let ms = Self.clock { _ = TroveGen.build(Self.size) }
        Self.record("trovegenSmall", ms)
        XCTAssertLessThan(ms, 60_000)
    }
}
