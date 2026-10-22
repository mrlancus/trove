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
}
