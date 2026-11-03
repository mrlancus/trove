import Testing
@testable import TroveCore

/// The live notes editor's styling (MASTER_PLAN N1).
struct MarkdownSyntaxTests {
    typealias S = MarkdownSyntax.Span

    func styles(_ line: String) -> [MarkdownSyntax.Style] { MarkdownSyntax.spans(line: line).map(\.style) }

    @Test func headingsQuotesAndLists() {
        #expect(MarkdownSyntax.spans(line: "## Title") == [S(0, 3, .marker), S(0, 8, .heading(2)), ])
        #expect(styles("#tag only").contains(.tag))
        #expect(styles("> quoted").contains(.quote))
        let task = MarkdownSyntax.spans(line: "- [x] done thing")
        #expect(task.contains(S(0, 2, .bullet)))
        #expect(task.contains(S(2, 3, .checkbox(checked: true))))
        #expect(task.contains(S(6, 10, .done)))
        #expect(styles("- [ ] todo").contains(.checkbox(checked: false)))
        #expect(styles("12. numbered").first == .bullet)
        #expect(!styles("2024-01 not a list").contains(.bullet))
    }

    @Test func inlineStyles() {
        let s = MarkdownSyntax.spans(line: "a **b** *c* `d` ==e== ~~f~~ [[G]] [h](u) #t https://x.io")
        let kinds = s.map(\.style)
        for k in [MarkdownSyntax.Style.bold, .italic, .code, .highlight, .strike, .wikilink, .link, .tag] { #expect(kinds.contains(k)) }
        // The bold text is exactly "b".
        #expect(s.contains(S(4, 1, .bold)))
        // Nothing inside code is styled.
        #expect(!styles("`**x**`").contains(.bold))
        // Unclosed markers stay plain.
        #expect(styles("2 * 3 = 6") == [])
        #expect(styles("a [[open") == [])
    }

    @Test func fencedCode() {
        let all = MarkdownSyntax.spans(text: "x\n```swift\nlet a = **1**\n```\n**y**")
        #expect(all[1].contains { $0.style == .codeBlock })
        #expect(all[2] == [S(0, 13, .codeBlock)])
        #expect(all[4].contains { $0.style == .bold })
    }

    @Test func emojiCountsInUTF16() {
        // 👍 is two UTF-16 units: the bold span starts after it.
        let s = MarkdownSyntax.spans(line: "👍 **ok**")
        #expect(s.contains(S(5, 2, .bold)))
    }

    @Test func wikilinkAutocompleteAndListContinuation() {
        let text = "see [[Photo"
        #expect(MarkdownSyntax.openWikilink(in: text, cursor: text.utf16.count)?.query == "Photo")
        #expect(MarkdownSyntax.openWikilink(in: "[[Done]] x", cursor: 10) == nil)
        #expect(MarkdownSyntax.continuation(of: "- [x] milk")?.insert == "\n- [ ] ")
        #expect(MarkdownSyntax.continuation(of: "3. step")?.insert == "\n4. ")
        #expect(MarkdownSyntax.continuation(of: "  - nested")?.insert == "\n  - ")
        #expect(MarkdownSyntax.continuation(of: "- ")?.endList == true)
        #expect(MarkdownSyntax.continuation(of: "plain") == nil)
    }
}

struct SlashMenuTests {
    @Test func slashAtLineStart() {
        #expect(MarkdownSyntax.openSlash(in: "hello\n/che", cursor: 10)?.query == "che")
        #expect(MarkdownSyntax.openSlash(in: "a/b", cursor: 3) == nil)
        #expect(MarkdownSyntax.slashMatches("check").map(\.title) == ["Checklist"])
        #expect(MarkdownSyntax.slashMatches("").count == MarkdownSyntax.slashCommands.count)
    }
}
