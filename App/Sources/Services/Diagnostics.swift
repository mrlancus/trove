import Foundation
import os
import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// On-device measuring for docs/PERF_AUDIT.md step 0: main-thread hangs, frames and hitches, and how
/// long each screen takes to show its content, labelled by the workflow on screen. Kept on this device
/// (Application Support/Trove/diagnostics); Settings → Battery shows them and exports them as one file.
/// Nothing leaves the device unless you share it (decision 15 in docs/DEVELOP_PLAN.md §F).
///
/// Costs: the hang watchdog pings the main thread every 100 ms only while Trove is the app in front
/// (one ping in flight at a time). The frame counter runs a display link only during a measuring
/// session you start (at most 10 minutes), because counting every frame keeps the CPU awake.
@MainActor
final class Diagnostics {
    static let shared = Diagnostics()

    /// Budgets (docs/prompts/develop-perf-testing.md Part 2): a hang is main-thread work over 100 ms.
    nonisolated static let hangThresholdMs = 100.0
    static let sessionLimit: TimeInterval = 600

    struct Hang: Codable, Equatable {
        var at: Date
        var ms: Double
        var workflow: String
    }

    struct Frames: Codable, Equatable {
        var frames = 0
        var hitches = 0
        /// Time beyond the expected frame time, summed over hitches.
        var hitchMs = 0.0
        var worstMs = 0.0
    }

    struct FrameSession: Codable, Equatable {
        var start: Date
        var seconds: Double
        /// The display's frame time (16.7 ms at 60 Hz, 8.3 ms at 120 Hz).
        var expectedMs: Double
        var total: Frames
        var byWorkflow: [String: Frames]
    }

    /// Time from a screen appearing to its content being shown (`ready`), per workflow.
    struct Navigation: Codable, Equatable {
        var workflow: String
        var ms: Double
        var at: Date
    }

    private(set) var workflow = "Launch"
    private(set) var hangs: [Hang] = []
    private(set) var sessions: [FrameSession] = []
    private(set) var navigations: [Navigation] = []
    private(set) var measuringFrames = false
    private var entered: [String: CFTimeInterval] = [:]
    private var screenSignposts: [String: OSSignpostIntervalState] = [:]
    private let signposter = OSSignposter(subsystem: "com.mrlancus.trove", category: .pointsOfInterest)
    private let watchdog = Watchdog()
    private var frameCounter: FrameCounter?
    private var started = false

    static var watchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "diagnostics.watch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "diagnostics.watch") }
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trove/diagnostics", isDirectory: true)
    }

    private struct Stored: Codable {
        var hangs: [Hang]
        var sessions: [FrameSession]
        var navigations: [Navigation]
    }

    func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: Self.folder.appendingPathComponent("diagnostics.json")),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            hangs = stored.hangs
            sessions = stored.sessions
            navigations = stored.navigations
        }
        watchdog.onHang = { ms in Task { @MainActor in Diagnostics.shared.recordHang(ms) } }
        let center = NotificationCenter.default
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification, inactive = UIApplication.willResignActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification, inactive = NSApplication.didResignActiveNotification
        #endif
        center.addObserver(forName: active, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Diagnostics.shared.becameActive() }
        }
        center.addObserver(forName: inactive, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Diagnostics.shared.resignedActive() }
        }
    }

    func becameActive() {
        if Self.watchEnabled { watchdog.start() }
    }

    func resignedActive() {
        watchdog.stop()
        if measuringFrames { stopFrames() }
        save()
    }

    func setWatching(_ on: Bool) {
        Self.watchEnabled = on
        if on { watchdog.start() } else { watchdog.stop() }
    }

    // MARK: Workflows

    /// A screen appeared: its name labels hangs and frames until another one appears.
    func enter(_ name: String) {
        workflow = name
        entered[name] = CACurrentMediaTime()
        if screenSignposts[name] == nil {
            screenSignposts[name] = signposter.beginInterval("Screen", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        }
    }

    func leave(_ name: String) {
        if let state = screenSignposts.removeValue(forKey: name) { signposter.endInterval("Screen", state) }
        entered[name] = nil
    }

    /// The screen's content is on screen (first page drawn, list loaded…).
    func ready(_ name: String) {
        guard let t = entered.removeValue(forKey: name) else { return }
        let ms = (CACurrentMediaTime() - t) * 1000
        navigations.append(Navigation(workflow: name, ms: ms, at: Date()))
        if navigations.count > 1000 { navigations.removeFirst(navigations.count - 1000) }
        signposter.emitEvent("Ready", "\(name, privacy: .public) \(Int(ms))ms")
    }

    // MARK: Hangs

    func recordHang(_ ms: Double) {
        hangs.append(Hang(at: Date(), ms: ms, workflow: workflow))
        if hangs.count > 500 { hangs.removeFirst(hangs.count - 500) }
        signposter.emitEvent("Hang", "\(Int(ms))ms in \(self.workflow, privacy: .public)")
    }

    // MARK: Frames

    func startFrames() {
        guard !measuringFrames else { return }
        measuringFrames = true
        let counter = FrameCounter()
        frameCounter = counter
        counter.start { [weak self] in self?.stopFrames() }
    }

    func stopFrames() {
        guard measuringFrames, let counter = frameCounter else { return }
        measuringFrames = false
        frameCounter = nil
        if let session = counter.stop() {
            sessions.append(session)
            if sessions.count > 20 { sessions.removeFirst(sessions.count - 20) }
        }
        save()
    }

    // MARK: Saving and export

    func save() {
        let stored = Stored(hangs: hangs, sessions: sessions, navigations: navigations)
        let folder = Self.folder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic) }
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    /// Navigation times per workflow: count, p50, p90, worst.
    func navigationSummary() -> [(workflow: String, count: Int, p50: Double, p90: Double, worst: Double)] {
        Dictionary(grouping: navigations, by: \.workflow).map { name, list in
            let ms = list.map(\.ms)
            return (name, ms.count, Self.percentile(ms, 0.5) ?? 0, Self.percentile(ms, 0.9) ?? 0, ms.max() ?? 0)
        }.sorted { $0.workflow < $1.workflow }
    }

    /// One JSON file with everything measured here, the device and OS, and the latest MetricKit reports.
    func exportFile() throws -> URL {
        save()
        let info = Bundle.main.infoDictionary ?? [:]
        var system: [String: String] = ["machine": Self.machine(), "device": DeviceInfo.kind]
        #if os(iOS)
        system["os"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        system["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        system["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        system["thermal"] = "\(ProcessInfo.processInfo.thermalState.rawValue)"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: encoder.encode(v))) ?? NSNull() }
        var metrics: [[String: Any]] = []
        for url in MetricsReporter.reports().prefix(5) {
            if let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) {
                metrics.append(["file": url.lastPathComponent, "payload": obj])
            }
        }
        let payload: [String: Any] = [
            "format": 1,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "app": ["version": info["CFBundleShortVersionString"] ?? "", "build": info["CFBundleVersion"] ?? ""],
            "system": system,
            "budgets": ["hangMs": Self.hangThresholdMs, "frameMs60Hz": 16.7, "frameMs120Hz": 8.3, "navigationColdMs": 200],
            "hangs": json(hangs),
            "frameSessions": json(sessions),
            "navigations": json(navigations),
            "metricKit": metrics,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-diagnostics-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Pings the main thread from a background queue; how late the ping runs is how long the main thread
/// was busy. One ping in flight at a time, so a long hang is counted once.
final class Watchdog: @unchecked Sendable {
    var onHang: (@Sendable (Double) -> Void)?
    private let queue = DispatchQueue(label: "com.mrlancus.trove.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var inFlight = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.ping() }
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func ping() {
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            let report = self.onHang
            self.lock.unlock()
            if ms >= Diagnostics.hangThresholdMs { report?(ms) }
        }
    }
}

/// Counts frames and hitches with a display link while a measuring session runs.
@MainActor
final class FrameCounter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var startedAt = Date()
    private var expected = 1.0 / 60
    private var total = Diagnostics.Frames()
    private var byWorkflow: [String: Diagnostics.Frames] = [:]
    private var timeout: (() -> Void)?

    func start(timeout: @escaping () -> Void) {
        self.timeout = timeout
        startedAt = Date()
        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #else
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let frame = link.targetTimestamp - link.timestamp
        if frame > 0 { expected = frame }
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let dt = link.timestamp - last
        let name = Diagnostics.shared.workflow
        var w = byWorkflow[name] ?? Diagnostics.Frames()
        total.frames += 1
        w.frames += 1
        let ms = dt * 1000
        total.worstMs = max(total.worstMs, ms)
        w.worstMs = max(w.worstMs, ms)
        // A hitch: the frame came at least half a frame late.
        if dt > expected * 1.5 {
            let late = (dt - expected) * 1000
            total.hitches += 1
            total.hitchMs += late
            w.hitches += 1
            w.hitchMs += late
        }
        byWorkflow[name] = w
        if Date().timeIntervalSince(startedAt) > Diagnostics.sessionLimit { timeout?() }
    }

    func stop() -> Diagnostics.FrameSession? {
        link?.invalidate()
        link = nil
        guard total.frames > 0 else { return nil }
        return Diagnostics.FrameSession(start: startedAt, seconds: Date().timeIntervalSince(startedAt), expectedMs: expected * 1000,
                                        total: total, byWorkflow: byWorkflow)
    }
}

extension View {
    /// Labels hangs and frames with this screen's workflow, and signposts it ("Screen" intervals).
    func perfWorkflow(_ name: String) -> some View {
        onAppear { Diagnostics.shared.enter(name) }
            .onDisappear { Diagnostics.shared.leave(name) }
    }
}
