import Foundation

// MARK: - Bridges paused while their feature is hidden (docs/plans/learn-pivot-plan.md §3 A2, review R9)

/// The GitHub and Telegram bridges are hidden in the apps and the website. So nothing hidden keeps running
/// on the relay, the first device that starts with a flag off pauses those bridges (`enabled: false`) and
/// remembers their ids in the synced setting `settings.features` → `pausedBridges`. When the flag is turned
/// back on, exactly those bridges are switched on again, unless they've been changed since (deleted, or
/// switched on already).
public enum BridgePause {
    /// What the planner needs to know about one bridge.
    public struct State: Equatable, Sendable {
        public var id: String
        public var kind: String
        public var enabled: Bool
        public init(id: String, kind: String, enabled: Bool) { self.id = id; self.kind = kind; self.enabled = enabled }
    }

    /// One bridge to switch on or off.
    public struct Change: Equatable, Sendable {
        public var id: String
        public var enabled: Bool
        public init(id: String, enabled: Bool) { self.id = id; self.enabled = enabled }
    }

    public struct Plan: Equatable, Sendable {
        public var changes: [Change]
        /// The ids to remember as paused afterwards (sorted, so devices write the same value).
        public var paused: [String]
    }

    /// - Parameters:
    ///   - bridges: the relay's bridges now.
    ///   - hiddenKinds: bridge kinds whose feature is hidden on this build ("github", "telegram").
    ///   - paused: the ids remembered as paused by Trove.
    public static func plan(bridges: [State], hiddenKinds: Set<String>, paused: [String]) -> Plan {
        var changes: [Change] = []
        var keep = Set<String>()
        let remembered = Set(paused)
        for b in bridges {
            if hiddenKinds.contains(b.kind) {
                if b.enabled { changes.append(Change(id: b.id, enabled: false)); keep.insert(b.id) }
                else if remembered.contains(b.id) { keep.insert(b.id) }
                // A bridge that was already off before Trove paused anything stays off and isn't remembered,
                // so showing the feature again doesn't switch on something you'd switched off yourself.
            } else if remembered.contains(b.id) {
                // Shown again: switch back on what Trove paused, unless it's already on.
                if !b.enabled { changes.append(Change(id: b.id, enabled: true)) }
            }
        }
        // Ids of bridges deleted since are forgotten.
        return Plan(changes: changes, paused: keep.sorted())
    }
}

extension Library {
    public static let featureSettingsId = "settings.features"

    /// Bridge ids Trove paused because their feature is hidden (see `BridgePause`).
    public func pausedBridges() async -> [String] {
        guard let r = await engine.record(Self.featureSettingsId), !r.isDeleted else { return [] }
        return r["pausedBridges"]?.stringArray ?? []
    }

    public func setPausedBridges(_ ids: [String]) async {
        guard await pausedBridges() != ids else { return }
        await engine.set(["pausedBridges": JSONValue(ids)], record: Self.featureSettingsId, kind: "setting")
    }
}
