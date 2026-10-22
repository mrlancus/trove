import os

/// Signposts for Instruments (Points of Interest / os_signpost), so launch, sync and the battery
/// work can be measured on a device: "Open library" (snapshot to first screen), "Sync" (one round),
/// "Enrich", "Read handwriting", "Reload ink" and "Checkpoint". docs/ROADMAP.md §3.3, §3.7.
enum Perf {
    private static let signposter = OSSignposter(subsystem: "com.mrlancus.trove", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// A moment, not an interval (say a checkpoint written inside a sync).
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
