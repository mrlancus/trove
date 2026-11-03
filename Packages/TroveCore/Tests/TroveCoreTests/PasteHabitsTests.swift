import Testing
@testable import TroveCore

struct PasteHabitsTests {
    @Test func learnsWhatGoesWhere() {
        var h = PasteHabits()
        #expect(h.suggestion(for: "com.apple.Terminal", kinds: [.text, .code]) == 0)
        for _ in 0..<4 { h.notePaste(kind: .code, app: "com.apple.Terminal") }
        h.notePaste(kind: .text, app: "com.apple.Terminal")
        #expect(h.likelyKind(for: "com.apple.Terminal") == .code)
        #expect(h.suggestion(for: "com.apple.Terminal", kinds: [.text, .link, .code, .code]) == 2)
        // Nothing of that kind recently: the newest clip.
        #expect(h.suggestion(for: "com.apple.Terminal", kinds: [.text, .link]) == 0)
        // Not a clear habit: no guess.
        var mixed = PasteHabits()
        for k in [ClipKind.text, .link, .code, .text, .link, .code] { mixed.notePaste(kind: k, app: "x") }
        #expect(mixed.likelyKind(for: "x") == nil)
    }
}
