import Foundation
import TroveCore

/// Hidden features (docs/plans/learn-pivot-plan.md §3, `Features`): nothing hidden keeps running.
extension AppModel {
    /// Pauses the relay's bridges whose feature is hidden (GitHub, Telegram), remembering them in the synced
    /// `settings.features` record, and switches exactly those back on when a build shows the feature again.
    /// Runs once per launch, after the first sync has had time to bring in another device's list.
    func pauseHiddenBridges() async {
        try? await Task.sleep(for: .seconds(20))
        guard let library, let client = vault.relayClient else { return }
        guard let bridges = try? await client.bridges() else { return }
        let remembered = await library.pausedBridges()
        let plan = BridgePause.plan(
            bridges: bridges.map { BridgePause.State(id: $0.id, kind: $0.kind, enabled: $0.enabled) },
            hiddenKinds: Features.hiddenBridgeKinds, paused: remembered)
        var paused = Set(plan.paused)
        for change in plan.changes {
            do {
                _ = try await client.updateBridge(change.id, enabled: change.enabled)
            } catch {
                // Not changed: remember it only if it's still running and hidden, so the next launch tries again.
                if change.enabled { paused.insert(change.id) } else { paused.remove(change.id) }
            }
        }
        await library.setPausedBridges(paused.sorted())
    }

    /// The readable copy's folder (`<vault>/Notes`), if this device has the vault folder.
    var readableCopyFolder: URL? { (try? vault.folderURL())?.appendingPathComponent("Notes", isDirectory: true) }

    /// Settings → "Delete the copy": removes `<vault>/Notes` (after the person confirmed). Trove never reads
    /// it, so nothing in the vault changes.
    func deleteReadableCopy() {
        guard let folder = readableCopyFolder else { return }
        try? FileManager.default.removeItem(at: folder)
        toast = "The readable copy is deleted"
    }
}
