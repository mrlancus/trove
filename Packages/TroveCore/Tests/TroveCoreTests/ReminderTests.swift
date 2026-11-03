import Foundation
import Testing
@testable import TroveCore

struct ReminderTests {
    @Test func setAndClear() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addNote(title: "Call the dentist", body: "")
        let when = Date(timeIntervalSince1970: 1_900_000_000)
        await lib.setReminder(id, at: when)
        #expect(await lib.item(id)?.remindAt == when)
        await lib.setReminder(id, at: nil)
        #expect(await lib.item(id)?.remindAt == nil)
    }
}
