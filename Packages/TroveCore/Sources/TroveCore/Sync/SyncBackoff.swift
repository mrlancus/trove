import Foundation

/// How long the apps' background sync loop waits before the next round (docs/ROADMAP.md §3.3).
/// Live pings, local edits and coming back to the app sync straight away on their own, so the loop
/// only catches what those miss: it waits `base` seconds after a round that changed something and
/// doubles the wait after each quiet round, up to `idleMax`. In Low Power Mode it waits at least
/// `lowPowerMin`.
public struct SyncBackoff: Sendable, Equatable {
    public let base: Double
    public let idleMax: Double
    public let lowPowerMin: Double
    public private(set) var interval: Double

    public init(base: Double, idleMax: Double = 300, lowPowerMin: Double = 120) {
        self.base = base
        self.idleMax = max(base, idleMax)
        self.lowPowerMin = lowPowerMin
        self.interval = base
    }

    /// The wait before the next round, after a round that did (or didn't) change anything.
    public mutating func next(changed: Bool, lowPower: Bool) -> Double {
        interval = changed ? base : min(interval * 2, idleMax)
        return lowPower ? max(interval, min(lowPowerMin, idleMax)) : interval
    }
}
