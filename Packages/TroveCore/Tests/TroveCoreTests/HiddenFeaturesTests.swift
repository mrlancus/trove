import Foundation
import Testing
@testable import TroveCore

/// Plan §3 A2 / review R9: hidden bridges are paused, remembered in a synced setting, and resumed exactly.
@Suite struct BridgePauseTests {
    typealias S = BridgePause.State

    @Test func hidingPausesOnlyRunningBridgesOfHiddenKinds() {
        let bridges = [S(id: "gh1", kind: "github", enabled: true), S(id: "gh2", kind: "github", enabled: false),
                       S(id: "tg", kind: "telegram", enabled: true), S(id: "rss", kind: "rss", enabled: true),
                       S(id: "hook", kind: "webhook", enabled: true)]
        let plan = BridgePause.plan(bridges: bridges, hiddenKinds: ["github", "telegram"], paused: [])
        #expect(plan.changes == [.init(id: "gh1", enabled: false), .init(id: "tg", enabled: false)])
        // gh2 was off already: it isn't Trove's to switch back on later.
        #expect(plan.paused == ["gh1", "tg"])
    }

    @Test func pausingTwiceChangesNothing() {
        let bridges = [S(id: "gh1", kind: "github", enabled: false)]
        let plan = BridgePause.plan(bridges: bridges, hiddenKinds: ["github"], paused: ["gh1"])
        #expect(plan.changes.isEmpty)
        #expect(plan.paused == ["gh1"])
    }

    @Test func showingAgainResumesExactlyWhatWasPaused() {
        let bridges = [S(id: "gh1", kind: "github", enabled: false), S(id: "gh2", kind: "github", enabled: false),
                       S(id: "tg", kind: "telegram", enabled: true)]
        let plan = BridgePause.plan(bridges: bridges, hiddenKinds: [], paused: ["gh1", "tg", "gone"])
        // gh2 was never paused by Trove; tg was switched on again by hand; "gone" was deleted.
        #expect(plan.changes == [.init(id: "gh1", enabled: true)])
        #expect(plan.paused.isEmpty)
    }

    @Test func thePausedListSyncs() async {
        let keys = VaultKeys.generate()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mac = Library(engine: SyncEngine(device: "MAC", keys: keys, transports: [FolderTransport(root: folder)]))
        let ipad = Library(engine: SyncEngine(device: "IPAD", keys: keys, transports: [FolderTransport(root: folder)]))
        #expect(await mac.pausedBridges().isEmpty)
        await mac.setPausedBridges(["gh1", "tg"])
        _ = await mac.engine.sync()
        _ = await ipad.engine.sync()
        #expect(await ipad.pausedBridges() == ["gh1", "tg"])
    }
}
