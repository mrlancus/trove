import Foundation
import Testing
@testable import TroveCore

/// Notebooks (MASTER_PLAN G1, G2, G5): page names for the outline, covers, insert space.
struct NotebookTests {
    @Test func pageNamesRoundTripAndSurviveRewrites() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addSketch(title: "Lectures")
        let first = await lib.item(id)!.sketchPageList[0].id
        await lib.setPageName(first, of: id, to: "  Week 1: Cells  ")
        #expect(await lib.item(id)?.sketchPageList[0].name == "Week 1: Cells")
        // Other page changes keep the name.
        await lib.setPage(first, of: id, color: "#fff8e7")
        #expect(await lib.item(id)?.sketchPageList[0].name == "Week 1: Cells")
        await lib.setPageName(first, of: id, to: "")
        #expect(await lib.item(id)?.sketchPageList[0].name == nil)
        #expect(InkPage(id: "x", name: String(repeating: "a", count: 300)).name?.count == 120)
    }

    @Test func coversRoundTrip() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addSketch(title: "Maths")
        #expect(await lib.item(id)?.cover == nil)
        await lib.setCover(id, NotebookCover(color: "#33658a", pattern: .grid))
        #expect(await lib.item(id)?.cover == NotebookCover(color: "#33658a", pattern: .grid))
        await lib.setCover(id, nil)
        #expect(await lib.item(id)?.cover == nil)
        #expect(NotebookCover(json: .object(["color": .string("red")])) == nil)
    }

    @Test func insertSpaceMovesOnlyWhatsBelow() {
        let t = InkEditing.spaceTargets(strokes: [("above", 50), ("on", 100), ("below", 140)], elements: [("box", 120), ("title", 10)], at: 100)
        #expect(t.strokes == ["on", "below"])
        #expect(t.elements == ["box"])
        // Taking space away stops at the highest thing below the line.
        #expect(InkEditing.clampedSpace(-80, at: 100, highestBelow: 140) == -40)
        #expect(InkEditing.clampedSpace(50, at: 100, highestBelow: 140) == 50)
    }
}
