import Testing
@testable import TroveCore

struct LinkItTests {
    @Test func turnsTheFirstPlainMentionIntoALink() {
        #expect(Links.linkMention(in: "Read about photosynthesis today", title: "Photosynthesis") == "Read about [[Photosynthesis]] today")
        #expect(Links.linkMention(in: "[[Photosynthesis]] and photosynthesis", title: "Photosynthesis") == "[[Photosynthesis]] and [[Photosynthesis]]")
        #expect(Links.linkMention(in: "photosynthesiser", title: "Photosynthesis") == nil)
        #expect(Links.linkMention(in: "nothing here", title: "Cells") == nil)
    }
}
