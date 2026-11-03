import Foundation
import Testing
@testable import TroveCore

struct PlannerTests {
    @Test func aYearOfPages() {
        #expect(Planner.pages(.monthly, year: 2027).count == 12)
        #expect(Planner.pages(.daily, year: 2028).count == 366)
        let weeks = Planner.pages(.weekly, year: 2027)
        #expect(weeks.count >= 52 && weeks.count <= 54)
        // January 2027 starts on a Friday: day 1 sits in the 5th column.
        let jan = Planner.pages(.monthly, year: 2027)[0]
        #expect(jan.name == "January")
        let one = jan.labels.first { $0.text == "1" }!
        #expect(one.x == 52 + 4 * 96)
    }

    @Test func plannerNotebookHasNamedPagesAndLabels() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addPlanner(.monthly, year: 2027)
        let item = await lib.item(id)!
        #expect(item.sketchPageList.count == 12)
        #expect(item.sketchPageList.map(\.name).first == "January")
        let first = item.sketchPageList[0].id
        let labels = await lib.elements(on: id, pageKey: first)
        #expect(labels.count == 1 + 7 + 31)
    }
}
