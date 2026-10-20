import Foundation
import Testing
@testable import TroveCore

@Suite struct ClipTests {
    @Test func classifies() {
        #expect(ClipClassifier.classify("https://example.com/a?b=1") == .link)
        #expect(ClipClassifier.classify("me@example.com") == .email)
        #expect(ClipClassifier.classify("+44 20 7946 0958") == .phone)
        #expect(ClipClassifier.classify("#ff8a3d") == .color)
        #expect(ClipClassifier.classify("rgb(255, 138, 61)") == .color)
        #expect(ClipClassifier.classify("hsl(24, 100%, 62%)") == .color)
        #expect(ClipClassifier.classify("1,299.50") == .number)
        #expect(ClipClassifier.classify("~/Documents/notes.md") == .path)
        #expect(ClipClassifier.classify(#"{"a": [1, 2]}"#) == .json)
        #expect(ClipClassifier.classify("func hello() {\n    return 1\n}") == .code)
        #expect(ClipClassifier.classify("const x = a => a + 1;\nconsole.log(x(1));") == .code)
        #expect(ClipClassifier.classify("Remember to buy milk and eggs") == .text)
        #expect(ClipClassifier.classify("facade") == .text)
        let c = ClipClassifier.color("#fff")!
        #expect(c.r == 1 && c.g == 1 && c.b == 1 && c.a == 1)
    }

    @Test func spotsSecrets() {
        for secret in ["sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "Tr0ub4dor&3x!",
                       "482913", "AKIAIOSFODNN7EXAMPLE", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc", "q8Zr2LmX9vB4nT7cK1pW5sY3hJ6gD0fA"] {
            #expect(SensitiveDetector.isSensitive(secret), "\(secret)")
        }
        for normal in ["Remember to buy milk", "https://example.com/Page?id=1&X=2", "me@example.com", "hello", "1,299", "~/Documents/My File.txt",
                       "#ff8a3d", "iPhone 17 Pro", #"{"b":1,"a":2}"#, "rgb(1,2,3)",
                       "Tuesday,", "Hello-World!", "Trove-macOS.zip", "Report2024.pdf"] {
            #expect(!SensitiveDetector.isSensitive(normal), "\(normal)")
        }
    }

    @Test func transforms() {
        #expect(ClipTransform.cleanLink.apply("https://example.com/a?utm_source=x&id=2") == "https://example.com/a?id=2")
        #expect(ClipTransform.prettyJSON.apply(#"{"b":1,"a":[1,2]}"#) == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}")
        #expect(ClipTransform.minifiedJSON.apply("{ \"a\" : 1 }") == #"{"a":1}"#)
        #expect(ClipTransform.singleLine.apply("one\n  two\n\nthree") == "one two three")
        #expect(ClipTransform.titleCase.apply("hello world") == "Hello World")
        #expect(ClipTransform.available(for: "plain words").contains(.uppercase))
        #expect(!ClipTransform.available(for: "plain words").contains(.prettyJSON))
    }

    @Test func historyDedupesPinsPrunesAndSaves() async throws {
        let box = ClockBox(Date(timeIntervalSince1970: 1_760_000_000))
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()), now: { box.now })
        let a = try #require(await lib.addClip(text: "first", sourceApp: "Notes"))
        box.advance(10)
        let b = try #require(await lib.addClip(text: "https://example.com/x", sourceApp: "Safari"))
        #expect(await lib.clips().map(\.id) == [b, a])
        box.advance(10)
        #expect(await lib.addClip(text: "first", sourceApp: "Mail") == a)          // same text: back to the top
        #expect(await lib.clips().map(\.id) == [a, b])
        #expect(await lib.clip(a)?.sourceApp == "Mail")
        #expect(await lib.addClip(text: "   ") == nil)

        let image = try #require(try await lib.addClip(image: Data([1, 2, 3]), mime: "image/png"))
        #expect(await lib.clip(image)?.kind == .image)
        #expect(try await lib.attachmentData(try #require(await lib.clip(image)?.image)) == Data([1, 2, 3]))
        #expect(try await lib.addClip(image: Data([1, 2, 3])) == image)

        await lib.setClipPinned(b, true)
        box.advance(31 * 86_400)
        _ = await lib.addClip(text: "fresh")
        #expect(await lib.pruneClips() == 2)                                         // "first" and the image expired
        #expect(Set(await lib.clips().map(\.text)) == ["https://example.com/x", "fresh"])

        let item = try #require(try await lib.saveClipToLibrary(b))
        #expect(await lib.item(item)?.url?.absoluteString == "https://example.com/x")
        #expect(await lib.clip(b)?.savedItem == item)
        #expect(try await lib.saveClipToLibrary(b) == item)
        #expect(await lib.items().count == 1)                                        // clips aren't library items
    }

    /// Fixtures/clip-cases.json comes from web/test/make-clip-fixture.mjs (clips.js `insights`).
    @Test func insightsMatchTheWebsite() throws {
        struct Case: Decodable {
            var text, autoTitle: String
            var chars, words, lines: Int
            var links, emails, phones, colors, hashtags: [String]
        }
        struct Cases: Decodable { var insights: [Case] }
        let url = try #require(Bundle.module.url(forResource: "clip-cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        #expect(cases.insights.count >= 10)
        for c in cases.insights {
            let got = ClipInsights.of(c.text)
            #expect(got == ClipInsights(autoTitle: c.autoTitle, chars: c.chars, words: c.words, lines: c.lines, links: c.links,
                                        emails: c.emails, phones: c.phones, colors: c.colors, hashtags: c.hashtags), "\(c.text)")
        }
    }

    @Test func editingRenamingTaggingAndSaving() async throws {
        let box = ClockBox(Date(timeIntervalSince1970: 1_760_000_000))
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()), now: { box.now })
        let source = ClipSource(bundle: "com.google.Chrome", url: "https://news.example.com/story", title: "A story")
        let id = try #require(await lib.addClip(text: "Call +44 20 7946 0958 about #budget", sourceApp: "Chrome", source: source))
        var clip = try #require(await lib.clip(id))
        #expect(clip.displayTitle == "Call +44 20 7946 0958 about #budget")
        #expect(clip.insights.phones == ["+44 20 7946 0958"] && clip.insights.hashtags == ["budget"])
        #expect(clip.sourceURL?.absoluteString == "https://news.example.com/story" && clip.sourceTitle == "A story")
        #expect(clip.sourceBundle == "com.google.Chrome" && clip.needsEnrichment && clip.uses == 0)

        await lib.applyClipEnrichment(id, ocrText: "", tier: .basic, by: "PHONE")
        #expect(await lib.clipsNeedingEnrichment(below: .basic).isEmpty)            // the phone has done what it can
        #expect(await lib.clipsNeedingEnrichment(below: .onDevice).map(\.id) == [id])  // the iPad still looks
        await lib.applyClipEnrichment(id, title: "Budget call", summary: "Ring about the budget.", tags: ["Finance"], tier: .onDevice, by: "IPAD")
        await lib.applyClipEnrichment(id, title: "Worse", tier: .basic, by: "PHONE")  // a weaker tier never overwrites
        clip = try #require(await lib.clip(id))
        #expect(clip.displayTitle == "Budget call" && !clip.needsEnrichment && clip.enrichment?.tier == .onDevice)
        #expect(await lib.clipsNeedingEnrichment().isEmpty)

        await lib.renameClip(id, to: "  Ring Anna ")
        await lib.setClipTags(id, ["#Work", "work", " finance "])
        await lib.setClipNote(id, "before Friday")
        clip = try #require(await lib.clip(id))
        #expect(clip.displayTitle == "Ring Anna" && clip.tags == ["work", "finance"] && clip.note == "before Friday")
        #expect(clip.matches("tag:work anna") && clip.matches("app:chrome") && clip.matches("friday") && clip.matches("story"))
        #expect(!clip.matches("is:pinned") && !clip.matches("tag:home"))

        box.advance(5)
        await lib.editClip(id, text: "Email anna@example.org about #budget")
        clip = try #require(await lib.clip(id))
        #expect(clip.text == "Email anna@example.org about #budget" && clip.hash == Clip.hash(text: clip.text))
        #expect(clip.insights.emails == ["anna@example.org"] && clip.insights.phones.isEmpty)
        #expect(clip.aiTitle == nil && clip.summary == nil && clip.needsEnrichment && clip.editedAt != nil && clip.enrichment == nil)
        #expect(await lib.clipsNeedingEnrichment(below: .onDevice).map(\.id) == [id])
        #expect(clip.displayTitle == "Ring Anna")                                      // your name survives an edit

        _ = await lib.addClip(text: "Email anna@example.org about #budget")
        #expect(await lib.clip(id)?.uses == 1)                                         // copied again

        let item = try #require(try await lib.saveClipToLibrary(id))
        let saved = try #require(await lib.item(item))
        #expect(saved.title == "Ring Anna" && saved.source == .clipboard && Set(["finance", "work"]).isSubset(of: saved.tags))
        #expect(saved.body.contains("before Friday"))
        let origin = try #require(saved.record[Field.origin]?.object)
        #expect(origin["clip"]?.string == id && origin["app"]?.string == "Chrome" && origin["url"]?.string == "https://news.example.com/story")

        await lib.renameClip(id, to: "")
        #expect(await lib.clip(id)?.displayTitle == "Email anna@example.org about #budget")
    }

    @Test func limitKeepsTheNewest() async {
        let box = ClockBox(Date(timeIntervalSince1970: 1_760_000_000))
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()), now: { box.now })
        for i in 0..<12 { box.advance(1); _ = await lib.addClip(text: "clip \(i)") }
        #expect(await lib.pruneClips(limit: 5) == 7)
        #expect(await lib.clips().map(\.text) == (7..<12).reversed().map { "clip \($0)" })
    }

    @Test func clipsSyncBetweenDevices() async throws {
        let keys = VaultKeys.generate()
        let folder = FolderTransport(root: FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)"))
        let mac = Library(engine: SyncEngine(device: "MAC", keys: keys, transports: [folder]))
        let phone = Library(engine: SyncEngine(device: "PHONE", keys: keys, transports: [folder]))
        let id = try #require(await mac.addClip(text: "copied on the Mac", sourceApp: "Xcode", sourceDevice: "MacBook"))
        _ = await mac.sync()
        _ = await phone.sync()
        let clip = try #require(await phone.clip(id))
        #expect(clip.text == "copied on the Mac" && clip.sourceDevice == "MacBook" && clip.device == "MAC")
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
