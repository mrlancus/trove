import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// MetricKit's daily reports (energy, CPU, wake-ups, disk writes, hangs, crashes), kept as JSON files
/// so Settings → Battery can show and share them (docs/ROADMAP.md §3.7 "Measuring"). The system hands
/// them over about once a day, a day after the app first runs; nothing leaves the device unless
/// the user shares a report.
final class MetricsReporter: NSObject, @unchecked Sendable {
    static let shared = MetricsReporter()
    private static let keep = 30

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Trove/metrics", isDirectory: true)
    }

    func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    /// Saved reports, newest first.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    fileprivate func store(_ data: Data, kind: String) {
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(stamp)-\(kind).json")
        try? data.write(to: url, options: .atomic)
        let all = Self.reports()
        for old in all.dropFirst(Self.keep) { try? FileManager.default.removeItem(at: old) }
    }
}

#if canImport(MetricKit)
extension MetricsReporter: MXMetricManagerSubscriber {
    #if os(iOS)
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { store(payload.jsonRepresentation(), kind: "metrics") }
    }
    #endif

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { store(payload.jsonRepresentation(), kind: "diagnostics") }
    }
}
#endif
