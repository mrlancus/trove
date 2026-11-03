import Foundation

/// The predicted next paste (docs/MASTER_PLAN.md C3, Paste's "Intelligent Clipboard" without AI):
/// what kinds of clips you paste into each app, counted on this device, so when the palette opens
/// over Terminal the recent code is picked, over Mail the recent email address, and so on.
public struct PasteHabits: Codable, Equatable, Sendable {
    /// app bundle id → clip kind → pastes (recent ones weigh more: counts decay by 10 % a paste).
    public var counts: [String: [String: Double]] = [:]

    public init() {}

    public mutating func notePaste(kind: ClipKind, app: String) {
        var c = counts[app] ?? [:]
        for k in c.keys { c[k]! *= 0.9 }
        c[kind.rawValue, default: 0] += 1
        counts[app] = c
    }

    /// The kind usually pasted into `app`, when it's a clear habit (at least ~3 pastes and 60 %).
    public func likelyKind(for app: String) -> ClipKind? {
        guard let c = counts[app], let best = c.max(by: { $0.value < $1.value }) else { return nil }
        let total = c.values.reduce(0, +)
        guard best.value >= 2.5, best.value / total >= 0.6 else { return nil }
        return ClipKind(rawValue: best.key)
    }

    /// Which of the newest clips to pick first: the newest of the likely kind among the first
    /// `window`, else the newest of all (index into `kinds`).
    public func suggestion(for app: String, kinds: [ClipKind], window: Int = 10) -> Int {
        guard let kind = likelyKind(for: app) else { return 0 }
        return kinds.prefix(window).firstIndex(of: kind) ?? 0
    }
}
