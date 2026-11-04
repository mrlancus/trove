import Foundation
import Testing
@testable import TroveCore

/// Locked pictures and boxes (PROTOCOL.md §10 `locked`): the lasso can't move them; you write over them.
struct LockTests {
    private func picture(_ lib: Library) async throws -> (sketch: String, page: String, element: String) {
        let id = await lib.addSketch(title: "Locked")
        let page = await lib.item(id)!.sketchPageList[0].id
        let e = try await lib.addPicture(Data([0x89, 0x50, 0x4E, 0x47]), mime: "image/png", on: id, pageKey: page,
                                         frame: InkGeometry.Rect(x: 10, y: 20, width: 100, height: 50))
        return (id, page, e)
    }

    @Test func aLockedPictureDoesNotMove() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let p = try await picture(lib)
        await lib.setLocked([p.element], true)
        await lib.transformElements([p.element], by: InkGeometry.Transform(dx: 40, dy: 40))
        let e = await lib.elements(on: p.sketch, pageKey: p.page).first { $0.id == p.element }!
        #expect(e.locked)
        #expect(e.frame.x == 10 && e.frame.y == 20)
    }

    @Test func unlockingLetsItMoveAgain() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let p = try await picture(lib)
        await lib.setLocked([p.element], true)
        await lib.setLocked([p.element], false)
        await lib.transformElements([p.element], by: InkGeometry.Transform(dx: 40, dy: 0))
        let e = await lib.elements(on: p.sketch, pageKey: p.page).first { $0.id == p.element }!
        #expect(!e.locked)
        #expect(e.frame.x == 50)
    }

    @Test func undoPutsUnlockedBack() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let p = try await picture(lib)
        // A picture that was never locked has no field; undo's snapshot must still say "unlocked".
        #expect(await lib.inkFields(p.element, [InkElement.Field.locked])[InkElement.Field.locked] == .bool(false))
    }
}
