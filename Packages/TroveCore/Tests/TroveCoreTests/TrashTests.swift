import Foundation
import Testing
@testable import TroveCore

struct TrashTests {
    @Test func deletedItemsComeBack() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let a = await lib.addNote(title: "Keep me", body: "x")
        await lib.delete(a)
        #expect(await lib.item(a) == nil)
        let trash = await lib.recentlyDeleted()
        #expect(trash.map(\.id) == [a])
        await lib.restore(a)
        #expect(await lib.item(a)?.title == "Keep me")
        #expect(await lib.recentlyDeleted().isEmpty)
        // Older than 30 days: not listed.
        await lib.delete(a)
        #expect(await lib.recentlyDeleted(now: Date().addingTimeInterval(31 * 86_400)).isEmpty)
    }
}
