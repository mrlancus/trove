import Foundation
import Observation
import TroveCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

/// This device's power state for `PowerPolicy` (docs/ROADMAP.md §3.7), the Settings → Battery mode
/// (per device, not synced) and the counters shown under it: what the current sketch session, the
/// last one and this launch cost in pushes, pulls, requests, reloads, Vision pages and AI calls.
@MainActor
@Observable
final class PowerMonitor {
    private static let modeKey = "powerMode"
    private static let lastSketchKey = "powerLastSketch"

    var mode: PowerState.Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// Since the app started.
    private(set) var sinceLaunch = PowerCounters()
    /// The sketch open now, if any.
    private(set) var sketch: PowerCounters?
    /// The last sketch that closed (kept across launches).
    private(set) var lastSketch: PowerCounters?

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(PowerState.Mode.init(rawValue:)) ?? .automatic
        if let data = UserDefaults.standard.data(forKey: Self.lastSketchKey) {
            lastSketch = try? JSONDecoder().decode(PowerCounters.self, from: data)
        }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    /// The device right now (cheap to read: Low Power Mode, heat and the charger are plain lookups).
    func state(sketching: Bool) -> PowerState {
        PowerState(mode: mode, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                   charging: Self.charging, thermal: Self.thermal, sketching: sketching)
    }

    func policy(sketching: Bool) -> PowerPolicy { PowerPolicy(state(sketching: sketching)) }

    static var thermal: PowerState.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// Hot enough to stop enrichment mid-batch (read from any thread).
    nonisolated static var tooHot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

    static var charging: Bool {
        #if os(iOS)
        let battery = UIDevice.current.batteryState
        return battery == .charging || battery == .full
        #elseif os(macOS)
        // A Mac on mains power (or one without a battery) reports an unlimited time remaining (-2).
        return IOPSGetTimeRemainingEstimate() == -2.0
        #else
        return true
        #endif
    }

    // MARK: Counters

    func count(_ change: (inout PowerCounters) -> Void) {
        change(&sinceLaunch)
        if sketch != nil { change(&sketch!) }
    }

    func sketchOpened() {
        sketch = PowerCounters()
    }

    func sketchClosed() {
        guard var finished = sketch else { return }
        finished.ended = Date()
        lastSketch = finished
        sketch = nil
        if let data = try? JSONEncoder().encode(finished) { UserDefaults.standard.set(data, forKey: Self.lastSketchKey) }
    }
}
