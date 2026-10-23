import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TroveCore

/// Your own AI provider: settings round trip, and the requests and replies for Claude's Messages API
/// and OpenAI-style APIs, against a fake network.
struct AIProviderTests {
    /// Records each request and answers from a list.
    final class FakeNet: @unchecked Sendable {
        var requests: [URLRequest] = []
        var replies: [(Int, String)]
        init(_ replies: [(Int, String)]) { self.replies = replies }
        var transport: AIClient.Transport {
            { [self] request in
                requests.append(request)
                let (status, body) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
                return (Data(body.utf8), status)
            }
        }
        func body(_ i: Int) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    @Test func settingsRoundTripAndDefaults() async {
        var s = AISettings()
        #expect(!s.isReady)
        s.apiKey = "sk-test"
        #expect(s.isReady && s.model(.fast) == "claude-haiku-5-5" && s.model(.best) == "claude-opus-5-5")
        s.provider = .openrouter
        #expect(!s.isReady) // no models chosen yet
        s.models[.fast] = "some/model"
        #expect(s.isReady && s.model(.smart) == "some/model") // falls back to the fast one
        s.readHandwriting = false
        #expect(AISettings(fields: s.fields) == s)

        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        await lib.setAISettings(s)
        #expect(await lib.aiSettings() == s)
        var local = AISettings()
        local.provider = .custom
        local.customURL = "http://localhost:11434/v1/"
        local.models[.fast] = "llama"
        #expect(local.isReady && local.baseURL == "http://localhost:11434/v1") // a local server needs no key
    }

    @Test func claudeRequestAndAnswer() async throws {
        let net = FakeNet([(200, #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{\"answer\":\"Tuesday\",\"citations\":[\"a\",\"zz\"]}"}],"usage":{"input_tokens":50,"output_tokens":9}}"#)])
        var s = AISettings()
        s.apiKey = "sk-ant"
        let client = AIClient(settings: s, transport: net.transport)
        let out = try await client.ask("When?", sources: [(id: "a", text: "Meeting Tuesday"), (id: "b", text: "x")], tier: .smart)
        #expect(out.answer == "Tuesday" && out.citations == ["a"]) // ids it wasn't given are dropped
        let r = net.requests[0]
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = net.body(0)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["temperature"] == nil)
        let output = body["output_config"] as? [String: Any]
        #expect(output?["effort"] as? String == "medium")
        #expect((output?["format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func claudeReadsAPageAndExplainsFailures() async throws {
        let net = FakeNet([
            (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"text\":\"Buy milk\",\"description\":\"A cat\"}"}]}"#),
            (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
            (200, #"{"stop_reason":"refusal","content":[]}"#),
        ])
        var s = AISettings()
        s.apiKey = "k"
        let client = AIClient(settings: s, transport: net.transport)
        #expect(try await client.readPage(Data([1, 2, 3])) == "Buy milk\nA cat")
        let content = ((net.body(0)["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "image")
        #expect((content.first?["source"] as? [String: Any])?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
        #expect(net.body(0)["model"] as? String == "claude-haiku-5-5")
        await #expect(throws: AIClient.Failure.self) { _ = try await client.readPage(Data([1])) }
        do { _ = try await client.complete([.text("hi")]) } catch let e as AIClient.Failure { #expect(e.message.contains("declined")) }
    }

    @Test func openAIStyleFallsBackWhenAParameterIsRefused() async throws {
        let net = FakeNet([
            (400, #"{"error":{"message":"Unrecognized request argument: reasoning_effort"}}"#),
            (200, #"{"model":"gpt-x","choices":[{"message":{"content":"```json\n{\"text\":\"Shorter.\",\"cards\":[]}\n```"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#),
        ])
        var s = AISettings()
        s.provider = .openai
        s.apiKey = "sk-o"
        s.models[.fast] = "gpt-x"
        let client = AIClient(settings: s, transport: net.transport)
        let out = try await client.action("Make it shorter", text: "A long text")
        #expect(out.text == "Shorter." && out.model == "gpt-x")
        #expect(net.requests.count == 2)
        #expect(net.requests[0].url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(net.requests[0].value(forHTTPHeaderField: "authorization") == "Bearer sk-o")
        #expect(net.body(0)["reasoning_effort"] as? String == "medium")
        #expect(net.body(1)["reasoning_effort"] == nil)
        #expect(net.body(1)["max_completion_tokens"] as? Int == 4000)
    }

    @Test func listsModels() async throws {
        let net = FakeNet([(200, #"{"data":[{"id":"b-model"},{"id":"models/a-model"}]}"#)])
        var s = AISettings()
        s.provider = .gemini
        s.apiKey = "g"
        let models = try await AIClient(settings: s, transport: net.transport).listModels()
        #expect(models == ["a-model", "b-model"])
        #expect(net.requests[0].url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/models")
        #expect(net.requests[0].httpMethod == nil || net.requests[0].httpMethod == "GET")
    }

    /// Every request is metered: tokens, the price worked out for Claude models, and the purpose.
    @Test func metersAndLogsUsage() async throws {
        actor Log { var calls: [AIUsage.Call] = []; func add(_ c: AIUsage.Call) { calls.append(c) } }
        let log = Log()
        let net = FakeNet([(200, #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{\"text\":\"Hi\",\"description\":\"\"}"}],"usage":{"input_tokens":1000000,"output_tokens":200000,"cache_read_input_tokens":0}}"#)])
        var s = AISettings()
        s.apiKey = "k"
        let client = AIClient(settings: s, transport: net.transport, meter: { await log.add($0) })
        _ = try await client.readPage(Data([1]), about: "Page 1")
        let calls = await log.calls
        #expect(calls.count == 1 && calls[0].purpose == .handwriting && calls[0].about == "Page 1")
        // 1M input at $0.10 (over 100K prompt: $0.50) and 200K output at $2.50: Haiku 5.5's long-prompt price.
        #expect(abs((calls[0].cost ?? 0) - (0.5 + 0.5)) < 1e-9)
        #expect((net.body(0)["output_config"] as? [String: Any])?["effort"] as? String == "medium") // Haiku always at medium
        #expect(AIPrices.cost(model: "claude-opus-5-5", input: 0, output: 0, cacheRead: 1_000_000) == 0.20)
        #expect(AIPrices.cost(model: "claude-haiku-5-5", input: 10_000, output: 1_000) == (10_000 * 0.10 + 1_000 * 0.50) / 1_000_000)
        #expect(AIPrices.cost(model: "gpt-x", input: 1, output: 1) == nil)

        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let now = Date()
        await lib.recordAIUsage(AIUsage.Call(at: now, purpose: .handwriting, about: "Notebook", model: "claude-haiku-5-5", input: 2000, output: 500))
        await lib.recordAIUsage(AIUsage.Call(at: now.addingTimeInterval(1), purpose: .ask, about: "When?", model: "claude-sonnet-5-5", input: 1000, output: 100))
        let logged = await lib.aiUsage(since: now.addingTimeInterval(-60))
        #expect(logged.count == 2 && logged[0].purpose == .ask && logged[0].device == "D")
        let total = AIUsage.Total(logged)
        #expect(total.calls == 2 && total.tokens == 3600)
        #expect(abs(await lib.backgroundAISpend(now: now) - (2000 * 0.10 + 500 * 0.50) / 1_000_000) < 1e-12)
        #expect(AISettings(fields: { var a = AISettings(); a.monthlyLimit = 2.5; return a.fields }()).monthlyLimit == 2.5)
    }

    /// Ask looks things up with tools (search, then open what it needs) instead of being handed a few notes.
    @Test func researchUsesTheLibraryTools() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let keep = await lib.addNote(title: "Icarus costume", body: "Wings need 40 feathers and wire.")
        _ = await lib.addNote(title: "Shopping", body: "milk")
        let net = FakeNet([
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"","signature":"s1"},{"type":"tool_use","id":"t1","name":"search","input":{"query":"icarus"}}],"usage":{"input_tokens":900,"output_tokens":40}}"#),
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t2","name":"read","input":{"ids":["ID"]}}],"usage":{"input_tokens":1200,"output_tokens":30,"cache_read_input_tokens":800}}"#.replacingOccurrences(of: "ID", with: keep)),
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"You need **40 feathers** (from “Icarus costume”)."}],"usage":{"input_tokens":300,"output_tokens":20}}"#),
        ])
        var s = AISettings()
        s.apiKey = "k"
        actor Seen { var steps: [[String]] = []; func add(_ p: AIClient.Progress) { steps.append(p.steps) } }
        let seen = Seen()
        let client = AIClient(settings: s, transport: net.transport)
        let prior = AIChat.Turn(question: "Earlier?", answer: "Yes.")
        let out = try await client.research("How many feathers?", history: [prior], tools: AskTools(library: lib), progress: { await seen.add($0) })
        #expect(out.text.contains("40 feathers") && out.sources == [keep])
        #expect(out.progress.usage.calls == 3 && out.progress.usage.output == 90)
        #expect(out.progress.steps.count == 2 && out.progress.steps[0].contains("icarus") && out.progress.steps[1].contains("Icarus costume"))
        #expect(await seen.steps.count >= 4)
        // The first request carries the earlier turn and the tools; the second returns the tool result
        // after the assistant's turn exactly as it came, thinking block included.
        let first = net.body(0)
        #expect((first["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["overview", "index", "search", "browse", "read"])
        #expect((first["messages"] as? [[String: Any]])?.count == 3)
        let second = (net.body(1)["messages"] as? [[String: Any]]) ?? []
        let assistant = second[3]["content"] as? [[String: Any]]
        #expect(assistant?.first?["type"] as? String == "thinking" && assistant?.first?["signature"] as? String == "s1")
        let result = (second[4]["content"] as? [[String: Any]])?.first
        #expect(result?["tool_use_id"] as? String == "t1" && (result?["content"] as? String ?? "").contains("Icarus costume"))
        let third = (net.body(2)["messages"] as? [[String: Any]]) ?? []
        #expect(((third[6]["content"] as? [[String: Any]])?.first?["content"] as? String ?? "").contains("40 feathers and wire"))
    }

    @Test func researchWithOpenAIStyleFunctionCalls() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        _ = await lib.addNote(title: "Trip", body: "Lisbon in May")
        let net = FakeNet([
            (400, #"{"error":{"message":"Unrecognized request argument: reasoning_effort"}}"#),
            (200, #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"overview","arguments":"{}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#),
            (200, #"{"choices":[{"message":{"role":"assistant","content":"You have 1 item."}}],"usage":{"prompt_tokens":20,"completion_tokens":5,"cost":0.0001}}"#),
        ])
        var s = AISettings()
        s.provider = .openrouter
        s.apiKey = "k"
        s.models[.fast] = "x/y"
        let out = try await AIClient(settings: s, transport: net.transport).research("How many?", tools: AskTools(library: lib))
        #expect(out.text == "You have 1 item." && out.progress.usage.calls == 2 && out.progress.usage.cost == 0.0001)
        let msgs = (net.body(2)["messages"] as? [[String: Any]]) ?? []
        #expect(msgs.last?["role"] as? String == "tool" && msgs.last?["tool_call_id"] as? String == "c1")
        #expect((msgs.last?["content"] as? String ?? "").contains("1 items"))
    }

    @Test func hiddenItemsAreNeverShownAndPagesAreViewed() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let open = try await lib.addFile(Data([1, 2, 3]), name: "Whiteboard.pdf", mime: "application/pdf")
        let secret = await lib.addNote(title: "Diary", body: "secret whiteboard plans")
        await lib.setAIAllowed(secret, false)
        let tools = AskTools(library: lib, pages: { item, first, count, _ in
            AskTools.PageView(images: item.id == open && first == 0 ? Array(repeating: Data([0xFF, 0xD8]), count: min(count, 2)) : [], total: 2)
        }, pageBudget: 3)
        #expect(await tools.run("search", ["query": "whiteboard"]).listed == [open])
        #expect(await tools.run("read", ["ids": [.string(secret)]]).opened.isEmpty)
        let index = await tools.run("index", [:]).text
        #expect(index.contains("Whiteboard") && !index.contains("Diary") && index.hasPrefix("1 items"))
        #expect(await tools.run("overview", [:]).text.contains("1 more items are private"))
        #expect(await tools.run("read", ["ids": [.string(open)]]).text.contains("view them"))
        let viewed = await tools.run("view", ["id": .string(open), "count": 4])
        #expect(viewed.images.count == 2 && viewed.text.contains("pages 1–2 of 2") && viewed.opened == [open])
        // Three pictures allowed for the question: one left, then none.
        #expect(await tools.run("view", ["id": .string(open), "count": 2, "page": 2]).images.isEmpty) // fake has no page 2: nothing spent
        #expect(await tools.run("view", ["id": .string(open), "count": 2]).images.count == 1)
        #expect(await tools.run("view", ["id": .string(open)]).text.contains("limit"))
        #expect(await tools.run("view", ["id": .string(secret)]).images.isEmpty)

        // The pictures go back to Claude inside the tool result.
        let net = FakeNet([
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"view","input":{"id":"ID"}}],"usage":{"input_tokens":9,"output_tokens":4}}"#.replacingOccurrences(of: "ID", with: open)),
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"A plan."}],"usage":{"input_tokens":9,"output_tokens":4}}"#),
        ])
        var s = AISettings()
        s.apiKey = "k"
        let fresh = AskTools(library: lib, pages: { _, _, count, _ in AskTools.PageView(images: Array(repeating: Data([0xFF, 0xD8]), count: min(count, 1)), total: 2) })
        _ = try await AIClient(settings: s, transport: net.transport).research("What's on it?", tools: fresh)
        #expect((net.body(0)["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "view" } == true)
        let msgs = (net.body(1)["messages"] as? [[String: Any]]) ?? []
        let result = (msgs.last?["content"] as? [[String: Any]])?.first
        let parts = result?["content"] as? [[String: Any]] ?? []
        #expect(parts.first?["type"] as? String == "text" && parts.dropFirst().first?["type"] as? String == "image")

        #expect(await lib.setAIAllowedForAll(true) == 1)
        #expect(await lib.item(secret)?.aiAllowed == true)
    }

    @Test func liveReadingTakesOnlyWhatsNew() {
        var s = AISettings()
        s.liveSince = Date(timeIntervalSince1970: 2_000)
        let old = Record(id: "a", kind: "item", createdHLC: "0000001000000-0000-D", updatedHLC: "0000003000000-0000-D")
        #expect(!s.isLive(old, inkSignature: "0-"))
        #expect(!s.isLive(old, inkSignature: "4-0000001500000-0001-D"))
        #expect(s.isLive(old, inkSignature: "5-0000002500000-0000-D")) // written on since
        let new = Record(id: "b", kind: "item", createdHLC: "0000002100000-0000-D", updatedHLC: "0000002100000-0000-D")
        #expect(s.isLive(new, inkSignature: "0-"))
        #expect(AISettings(fields: s.fields).liveSince == s.liveSince)
    }

    @Test func chatsAreSaved() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        var chat = AIChat()
        chat.turns.append(AIChat.Turn(question: "Q1", answer: "A1", sources: ["x"], steps: ["Searched"], model: "m", tokens: 10, cost: 0.01))
        await lib.saveAIChat(chat)
        chat.turns.append(AIChat.Turn(question: "Q2", answer: "A2"))
        await lib.saveAIChat(chat)
        let chats = await lib.aiChats()
        #expect(chats.count == 1 && chats[0].turns.count == 2 && chats[0].displayTitle == "Q1" && chats[0].turns[0].sources == ["x"])
        await lib.deleteAIChat(chat.id)
        #expect(await lib.aiChats().isEmpty)
    }
}

struct ScreenshotRouteTests {
    @Test func routesPerDevice() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        #expect(await lib.screenshotRoutes().isEmpty)
        await lib.setScreenshotRoute(ScreenshotRoute(notes: true, clipboard: false), for: "mac1")
        await lib.setScreenshotRoute(ScreenshotRoute(notes: false, clipboard: true), for: "IPAD")
        let routes = await lib.screenshotRoutes()
        #expect(routes["MAC1"] == ScreenshotRoute(notes: true) && routes["IPAD"] == ScreenshotRoute(clipboard: true))
        let a = try await lib.addScreenshotClip(Data([1, 2, 3]), device: "iPad")
        let b = try await lib.addScreenshotClip(Data([1, 2, 3]), device: "iPhone")
        #expect(a != nil && a == b) // the same screenshot seen by two devices is one clip
    }
}

struct AIModelNameTests {
    @Test func prettyNames() {
        #expect(AIModelName.pretty("claude-sonnet-5-5") == "Claude Sonnet 5.5")
        #expect(AIModelName.pretty("anthropic/claude-haiku-5-5") == "Claude Haiku 5.5")
        #expect(AIModelName.pretty("claude-opus-4-5-20251101") == "Claude Opus 4.5")
        #expect(AIModelName.pretty("gpt-5-mini") == "GPT-5 Mini")
        #expect(AIModelName.pretty("gemini-2.5-flash") == "Gemini 2.5 Flash")
        #expect(AIModelName.pretty("llama3.2:latest") == "Llama3.2")
        #expect(AIPrices.relativeLabel("claude-haiku-5-5", to: "claude-haiku-5-5") == "1×")
        #expect(AIPrices.relativeLabel("claude-sonnet-5-5", to: "claude-haiku-5-5") == "20×")
        #expect(AIPrices.relativeLabel("claude-opus-5-5", to: "claude-haiku-5-5") == "40×")
        #expect(AIPrices.relativeLabel("x/y", to: "claude-haiku-5-5") == nil)
    }

    @Test func handlesKeywordsAndClipboard() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let a = await lib.addNote(title: "Trip", body: "Lisbon trams and pastéis, Lisbon again; Lisbon tiles.")
        _ = await lib.addNote(title: "Shopping", body: "milk eggs bread")
        _ = await lib.addClip(text: "https://example.com/recipe-pasta")
        _ = await lib.addClip(text: "hunter2-Password!9")
        let tools = AskTools(library: lib, clipboard: true)
        let index = await tools.run("index", [:]).text
        #expect(index.contains(AskTools.handle(a) + " | Trip") && index.contains("lisbon"))
        #expect(await tools.run("read", ["ids": [.string(AskTools.handle(a))]]).opened == [a])
        let found = await tools.run("clipboard", ["query": "pasta"])
        #expect(found.text.hasPrefix("1 clips match") && found.text.contains("example.com"))
        let handle = String(found.text.split(separator: "\n")[1].split(separator: " ")[0])
        #expect(await tools.run("read", ["ids": [.string(handle)]]).text.contains("recipe-pasta"))
        #expect(!(await tools.run("clipboard", [:]).text.contains("hunter2")))
        #expect(await tools.run("clipboard", ["query": "x"]).step.isEmpty == false)
        #expect(await AskTools(library: lib).run("clipboard", [:]).text.contains("no tool")) // off unless allowed
    }
}
