import os

/// Signposts for Instruments (Points of Interest / os_signpost), so launch and sync can be measured
/// on a device: "Open library" (snapshot to first screen) and "Sync" (one round). docs/ROADMAP.md §3.3.
@MainActor
enum Perf {
    private static let signposter = OSSignposter(subsystem: "com.mrlancus.trove", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
