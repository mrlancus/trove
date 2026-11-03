import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TroveCore

/// Ask inside a notebook (MASTER_PLAN G14): grounded, cited, cached, with memory and diagrams.
struct StudyChatTests {
    let context = StudyContext(title: "Biology", pages: [
        .init(key: "0", label: "Page 1", text: "Photosynthesis makes glucose\nChlorophyll absorbs light"),
        .init(key: "1", label: "Page 2", text: "Mitochondria release energy\n\nRespiration uses oxygen"),
    ])

    @Test func everyLineHasAHandleThatResolves() {
        let r = context.rendered
        #expect(r.contains("[p1.2] Chlorophyll absorbs light"))
        #expect(r.contains("[p2.2] Respiration uses oxygen"))
        #expect(context.resolve("p2.2") == .init(pageKey: "1", line: 1))
        #expect(context.resolve("p2") == .init(pageKey: "1", line: 0))
        #expect(context.resolve("p3.1") == nil)
        #expect(context.resolve("p1.9") == nil)
    }

    @Test func citationsAreCheckedAgainstTheNotes() {
        let a = StudyAnswer.parse("Glucose is made in photosynthesis [p1.1]. Light is absorbed by chlorophyll [p1.2, p9.9].", context: context)
        #expect(a.refs == [.init(pageKey: "0", line: 0), .init(pageKey: "0", line: 1)])
        #expect(a.unverified == ["p9.9"])
        #expect(a.display(context: context).contains("[p1]"))
    }

    @Test func aDiagramComesOutOfTheReply() {
        let reply = """
        Here it is.
        ```diagram
        {"kind": "cycle", "title": "Energy", "nodes": [{"id": "a", "label": "Photosynthesis", "ref": "p1.1"}, {"id": "b", "label": "Respiration", "ref": "p2.2"}]}
        ```
        """
        let a = StudyAnswer.parse(reply, context: context)
        #expect(a.text == "Here it is.")
        #expect(a.diagram?.kind == .cycle)
        #expect(a.diagram?.nodes.count == 2)
        let layout = a.diagram!.layout(origin: InkPoint(x: 100, y: 100))
        #expect(layout.boxes.count == 2)
        #expect(layout.arrows.count == 2) // a cycle with no edges links round
        // Boxes don't overlap.
        let f = layout.boxes.map(\.frame)
        #expect(!(f[0].x < f[1].maxX && f[1].x < f[0].maxX && f[0].y < f[1].maxY && f[1].y < f[0].maxY))
    }

    @Test func diagramKindsLayOut() {
        let flow = DiagramSpec(kind: .flow, nodes: [.init(id: "a", label: "Light"), .init(id: "b", label: "Glucose"), .init(id: "c", label: "Energy")])
        #expect(flow.layout().arrows.count == 2)
        let tree = DiagramSpec(kind: .tree, nodes: [.init(id: "r", label: "Cell"), .init(id: "x", label: "Nucleus"), .init(id: "y", label: "Mitochondria")],
                               edges: [.init(from: "r", to: "x"), .init(from: "r", to: "y")])
        let t = tree.layout()
        let root = t.boxes.first { $0.id == "r" }!.frame, kid = t.boxes.first { $0.id == "x" }!.frame
        #expect(kid.y > root.maxY)
        let table = DiagramSpec(kind: .table, nodes: [], rows: [["Organelle", "Job"], ["Mitochondria", "Energy"]])
        #expect(table.layout().boxes.count == 4)
        #expect(DiagramSpec.parse("not json") == nil)
        #expect(DiagramSpec.parse(flow.json) == flow)
    }

    @Test func bigNotebooksSendTheRelevantPagesAndSaySoTheRestWasntSearched() {
        var pages: [StudyContext.Page] = []
        for i in 0..<50 { pages.append(.init(key: "\(i)", label: "Page \(i + 1)", text: String(repeating: "filler words here ", count: 200))) }
        pages[37] = .init(key: "37", label: "Page 38", text: "The Krebs cycle happens in the mitochondria " + String(repeating: "x ", count: 100))
        let big = StudyContext(title: "Big", pages: pages)
        let fitted = big.fitted(for: "where does the krebs cycle happen", budget: 20_000)
        #expect(fitted.characterCount <= 20_000)
        #expect(fitted.pages.contains { $0.key == "37" })
        #expect(!fitted.omittedPages.isEmpty)
        #expect(fitted.rendered.contains("left out"))
    }

    @Test func memoryIsAMarkdownFileOnTheDevice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("study-\(UUID().uuidString)")
        let memory = StudyMemory(directory: dir)
        #expect(memory.summary(for: "nb-1") == nil)
        try memory.save("## Got wrong\n- ATP is made in mitochondria", for: "nb-1", title: "Biology")
        #expect(memory.summary(for: "nb-1")?.contains("ATP") == true)
        #expect(memory.all().count == 1)
        memory.delete("nb-1")
        #expect(memory.summary(for: "nb-1") == nil)
    }

    @Test func theRequestCachesTheNotebookAndCarriesTheRules() async throws {
        let reply = #"{"content":[{"type":"text","text":"Chlorophyll absorbs light [p1.2]. Not mitochondria."}],"stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":900}}"#
        let net = AIProviderTests.FakeNet([(200, reply)])
        var s = AISettings()
        s.apiKey = "sk-test"
        let client = AIClient(settings: s, transport: net.transport)
        let answer = try await client.studyReply("Is light absorbed by mitochondria?", context: context,
                                                 history: [StudyTurn(question: "hi", answer: "Hello.")], summary: "## Got wrong\n- light", maxTokens: 300)
        #expect(answer.refs == [.init(pageKey: "0", line: 1)])
        #expect(answer.usage?.cacheRead == 900)
        let body = net.body(0)
        let system = body["system"] as? [[String: Any]] ?? []
        #expect(system.count == 2)
        #expect((system[0]["text"] as? String)?.contains("Don't be a yes-man") == true)
        #expect((system[1]["text"] as? String)?.contains("[p2.2] Respiration uses oxygen") == true)
        #expect(system[1]["cache_control"] != nil)
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        #expect((messages.last?["content"] as? String)?.contains("Summary of earlier sessions") == true)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func shortcutsAreJustWords() {
        #expect(StudyShortcut.quiz.prompt("chapter 2").contains("One question at a time"))
        #expect(StudyShortcut.find.prompt("osmosis").contains("Cite each line"))
        #expect(StudyShortcut.allCases.allSatisfy { $0.maxTokens <= 1200 })
    }
}
