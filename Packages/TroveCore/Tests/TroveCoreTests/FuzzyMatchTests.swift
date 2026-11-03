import Testing
@testable import TroveCore

struct FuzzyMatchTests {
    @Test func lettersInOrderWithWordStartsFirst() {
        #expect(FuzzyMatch.score("phsyn", "Photosynthesis") != nil)
        #expect(FuzzyMatch.score("xyz", "Photosynthesis") == nil)
        let titles = ["Weekly review", "Week 3 notes", "Networking", "Café menu"]
        #expect(FuzzyMatch.rank("wk3", titles) { $0 }.first == "Week 3 notes")
        #expect(FuzzyMatch.rank("cafe", titles) { $0 } == ["Café menu"])
        #expect(FuzzyMatch.rank("", titles, limit: 2) { $0 }.count == 2)
        // A word start beats letters buried in the middle.
        #expect(FuzzyMatch.score("net", "Networking")! > FuzzyMatch.score("net", "Planet earth")!)
    }
}
