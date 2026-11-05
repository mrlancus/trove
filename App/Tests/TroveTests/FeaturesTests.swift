import XCTest
@testable import Trove

/// Hidden features (docs/plans/learn-pivot-plan.md §3, review R10): the Mac's mirror leaves the Obsidian
/// folder alone while `Features.obsidian` is off, and writes the readable copy only when it's chosen.
@MainActor
final class FeaturesTests: XCTestCase {
    private func config(owner: Bool = true, readable: Bool? = nil, obsidian: String? = "/Users/me/Obsidian") -> VaultConfig {
        var c = VaultConfig(vaultId: "v", deviceId: "d", encrypted: true, storage: .none, relay: nil, mirrorOwner: owner)
        c.obsidianFolder = obsidian
        c.readableCopy = readable
        return c
    }

    func testTheObsidianFolderIsLeftAloneWhileHidden() {
        XCTAssertNil(config().mirrorPlan(obsidian: false).obsidianFolder)
        // The code still works with the flag on (`-TroveFeatures obsidian`).
        XCTAssertEqual(config().mirrorPlan(obsidian: true).obsidianFolder, "/Users/me/Obsidian")
    }

    func testTheReadableCopyIsOffUnlessChosen() {
        XCTAssertFalse(config(readable: nil).mirrorPlan(obsidian: false).exportNotes)
        XCTAssertFalse(config(readable: false).mirrorPlan(obsidian: false).exportNotes)
        XCTAssertTrue(config(readable: true).mirrorPlan(obsidian: false).exportNotes)
        XCTAssertTrue(config(readable: nil, obsidian: nil).mirrorPlan(obsidian: false).isEmpty)
    }

    func testOnlyTheMirrorOwnerWritesAnything() {
        XCTAssertTrue(config(owner: false, readable: true).mirrorPlan(obsidian: true).isEmpty)
    }

    /// Configs written before `readableCopy` existed still decode (and mean "off").
    func testAnOlderConfigDecodes() throws {
        let old = #"{"vaultId":"v","deviceId":"d","encrypted":true,"storage":{"none":{}},"mirrorOwner":true,"cloudAI":false,"screenshotsImport":false,"appleNotesImport":false}"#
        let c = try JSONDecoder().decode(VaultConfig.self, from: Data(old.utf8))
        XCTAssertNil(c.readableCopy)
        XCTAssertFalse(c.mirrorPlan(obsidian: false).exportNotes)
    }

    func testHiddenBridgeKinds() {
        // Shipped builds hide both; the UI tests' `-TroveFeatures all` shows them.
        if !Features.githubBridge { XCTAssertTrue(Features.hiddenBridgeKinds.contains("github")) }
        if !Features.telegramBridge { XCTAssertTrue(Features.hiddenBridgeKinds.contains("telegram")) }
    }
}
