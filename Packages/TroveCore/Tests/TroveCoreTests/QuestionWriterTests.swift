import Foundation
import Testing
@testable import TroveCore

/// Questions in the style of real papers (learn-pivot plan §C2.3, §C9): the free code checks on fixtures that
/// pass and fail, and the whole write → check → rewrite pipeline against a fake model.
@Suite struct QuestionWriterTests {
    struct Cases: Decodable {
        struct Req: Decodable {
            struct Ex: Decodable { var id, label, question, scheme: String }
            var board, spec, paper, level: String
            var parts, totalMarks: Int
            var example: Ex
        }
        struct Case: Decodable { var name: String; var question: GeneratedQuestion; var expect: [String] }
        var request: Req
        var cases: [Case]
    }

    static func load() throws -> (QuestionRequest, Cases) {
        let url = try #require(Bundle.module.url(forResource: "question-cases", withExtension: "json", subdirectory: "Fixtures"))
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        let r = c.request
        let req = QuestionRequest(board: r.board, spec: r.spec, paper: r.paper, level: r.level,
                                  examples: [.init(id: r.example.id, label: r.example.label, question: r.example.question, scheme: r.example.scheme)],
                                  specPoints: ["3.4.1.6 Momentum"], questions: 1, parts: r.parts, totalMarks: r.totalMarks)
        return (req, c)
    }

    @Test func codeChecksCatchWhatTheyShould() throws {
        let (req, c) = try Self.load()
        #expect(c.cases.count >= 8)
        for k in c.cases {
            let kinds = Set(QuestionChecks.run(k.question, request: req).map(\.kind))
            #expect(kinds == Set(k.expect), "\(k.name): got \(kinds.sorted())")
        }
        #expect(QuestionChecks.markValue("M1") == 1 && QuestionChecks.markValue("B2") == 2 && QuestionChecks.markValue("MP3") == 1 && QuestionChecks.markValue("A1ft") == 1)
    }

    @Test func theSchemaIsClosedAndTheQuestionReads() throws {
        let (_, c) = try Self.load()
        let schema = QuestionSchemas.set
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(try JSONSerialization.data(withJSONObject: schema).count > 500)
        let good = c.cases[0].question
        #expect(good.questionText.contains("06.1 Calculate the momentum") && good.questionText.contains("[2 marks]"))
        #expect(good.schemeText.contains("MP1 M1 (AO1): p = mv") && good.schemeText.contains("accept 2.35–2.45"))
        #expect(QuestionWriter.label(board: "AQA", spec: "7408", paper: "1") == "Trove-made, in the style of AQA 7408 Paper 1")
    }

    /// A fake model: answers from a script, records what it was asked.
    final class Fake: QuestionModel, @unchecked Sendable {
        var calls: [(system: String, cached: String, prompt: String, effort: String)] = []
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func call(system: String, cached: String, prompt: String, schema: [String: Any], effort: String, maxTokens: Int,
                  about: String) async throws -> (text: String, model: String, tokens: Int) {
            calls.append((system, cached, prompt, effort))
            return (replies.isEmpty ? "{}" : replies.removeFirst(), "claude-haiku-5-5", 100)
        }
    }

    static func json(_ v: some Encodable) -> String { String(decoding: try! JSONEncoder().encode(v), as: UTF8.self) }
    static func set(_ q: GeneratedQuestion) -> String { json(GeneratedSet(brief: "v1", questions: [q])) }
    static let cleanCheck = #"{"answers":[{"label":"06.1","value":2.4,"unit":"kg m s-1","text":null},{"label":"06.2","value":2.47,"unit":"s","text":null}],"problems":[]}"#

    @Test func aGoodQuestionIsWrittenAndCheckedAtLow() async throws {
        let (req, c) = try Self.load()
        let fake = Fake([Self.set(c.cases[0].question), Self.cleanCheck])
        let report = try await QuestionWriter.write(req, model: fake)
        #expect(report.made.count == 1 && report.rewrites == 0 && report.dropped.isEmpty)
        #expect(report.made[0].effort == "low" && report.made[0].brief == "v1")
        #expect(fake.calls.map(\.effort) == ["low", "low"])
        // The brief and the examples are the stable (cached) prefix; the check never sees the scheme.
        #expect(fake.calls[0].system == QuestionBrief.system && fake.calls[0].cached.contains("<real_mark_scheme"))
        #expect(fake.calls[1].system == QuestionBrief.checkSystem && fake.calls[1].cached.isEmpty)
        #expect(!fake.calls[1].prompt.contains("MP1") && !fake.calls[1].prompt.contains("2.35"))
    }

    @Test func aFailingQuestionIsRewrittenOnceAtMedium() async throws {
        let (req, c) = try Self.load()
        let broken = c.cases.first { $0.name == "total doesn't add up" }!.question
        let fake = Fake([Self.set(broken), Self.set(c.cases[0].question), Self.cleanCheck])
        let report = try await QuestionWriter.write(req, model: fake)
        #expect(report.made.count == 1 && report.made[0].rewritten && report.made[0].effort == "medium" && report.rewrites == 1)
        #expect(fake.calls.map(\.effort) == ["low", "medium", "low"])
        #expect(fake.calls[1].prompt.contains("had these problems") && fake.calls[1].prompt.contains("marks"))
    }

    @Test func theCheckCallsDisagreementSendsItForARewriteAndASecondFailureDropsIt() async throws {
        let (req, c) = try Self.load()
        let wrong = #"{"answers":[{"label":"06.1","value":2.4,"unit":null,"text":null},{"label":"06.2","value":3.1,"unit":"s","text":null}],"problems":[{"label":"06.2","kind":"contradiction","detail":"says horizontally, then at 30°"}]}"#
        let fake = Fake([Self.set(c.cases[0].question), wrong, Self.set(c.cases[0].question), wrong])
        let report = try await QuestionWriter.write(req, model: fake)
        #expect(report.made.isEmpty && report.dropped.count == 1 && report.rewrites == 1)
        #expect(Set(report.dropped[0].problems.map(\.kind)).isSuperset(of: ["check", "contradiction"]))
    }

    @Test func noExamplesNoGeneration() async throws {
        var (req, _) = try Self.load()
        req.examples = []
        await #expect(throws: QuestionWriter.Failure.self) { _ = try await QuestionWriter.write(req, model: Fake([])) }
    }

    /// The request the app sends: the brief as a cached system block, the examples as a cached block, then the ask.
    @Test func theClaudeRequestCachesTheBriefAndExamples() async throws {
        final class Net: @unchecked Sendable {
            var body: [String: Any] = [:]
            var transport: AIClient.Transport {
                { [self] request in
                    body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                    return (Data(#"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":5,"output_tokens":5}}"#.utf8), 200)
                }
            }
        }
        let net = Net()
        var s = AISettings()
        s.apiKey = "sk-test"
        let client = AIClient(settings: s, transport: net.transport)
        _ = try await client.call(system: QuestionBrief.system, cached: "EXAMPLES", prompt: "ASK", schema: QuestionSchemas.set, effort: "low", maxTokens: 16_000, about: "t")
        let system = try #require(net.body["system"] as? [[String: Any]])
        #expect((system.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
        let content = try #require(((net.body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.map { $0["text"] as? String } == ["EXAMPLES", "ASK"])
        #expect(content[0]["cache_control"] != nil && content[1]["cache_control"] == nil)
        let output = try #require(net.body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low" && (output["format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(net.body["temperature"] == nil && net.body["top_p"] == nil && net.body["thinking"] == nil)
        #expect(net.body["model"] as? String == "claude-haiku-5-5")
    }
}
