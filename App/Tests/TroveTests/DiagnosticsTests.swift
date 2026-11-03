import XCTest
@testable import Trove

/// The lag watchdog and its numbers (docs/PERF_AUDIT.md step 0).
@MainActor
final class DiagnosticsTests: XCTestCase {
    func testPercentiles() {
        XCTAssertNil(Diagnostics.percentile([], 0.9))
        XCTAssertEqual(Diagnostics.percentile([5], 0.9), 5)
        XCTAssertEqual(Diagnostics.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5), 6)
        XCTAssertEqual(Diagnostics.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9)
    }

    /// Blocking the main thread for 300 ms is reported once, as about 300 ms.
    func testTheWatchdogSeesABlockedMainThread() {
        let watchdog = Watchdog()
        let seen = expectation(description: "hang reported")
        let reports = Reports()
        watchdog.onHang = { ms in
            reports.add(ms)
            seen.fulfill()
        }
        watchdog.start()
        // Let the first pings through, then block.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        Thread.sleep(forTimeInterval: 0.3)
        wait(for: [seen], timeout: 2)
        watchdog.stop()
        let all = reports.all
        XCTAssertEqual(all.count, 1)
        XCTAssertGreaterThanOrEqual(all.first ?? 0, 100)
        XCTAssertLessThan(all.first ?? 0, 450)
    }

    func testTheExportHasTheDeviceAndBudgets() throws {
        let url = try Diagnostics.shared.exportFile()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["format"] as? Int, 1)
        XCTAssertNotNil((json["system"] as? [String: Any])?["os"])
        XCTAssertEqual((json["budgets"] as? [String: Any])?["hangMs"] as? Double, 100)
    }
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ v: Double) { lock.lock(); list.append(v); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}
