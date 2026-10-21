import Foundation
import Testing
@testable import TroveCore

/// Inbox entries from bridges (PROTOCOL.md §4 "Bridges"), on the fixture shared with web/test/bridges.test.mjs.
@Suite struct BridgeInboxTests {
    @Test func bridgeEntriesBecomeTheSameItemsAsOnTheWebsite() async throws {
        let url = try #require(Bundle.module.url(forResource: "inbox-bridges", withExtension: "json", subdirectory: "Fixtures"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()))
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let headerJSON = try JSONSerialization.data(withJSONObject: try #require(c["header"]))
            let header = try JSONDecoder().decode(InboxEnvelope.Header.self, from: headerJSON)
            let body = Data((c["body"] as? String ?? "").utf8)
            let id = try await lib.importInbox(InboxEnvelope(header: header, body: body), entryId: c["entry"] as? String)
            let e = try #require(c["expect"] as? [String: Any])
            let item = try #require(await lib.item(id))
            let folders = await lib.folders()
            let path = item.folder.map { Folder.path(of: $0, in: folders).map(\.name) } ?? []
            #expect(id == e["id"] as? String, "\(name)")
            #expect(item.kind.rawValue == e["kind"] as? String, "\(name)")
            #expect(item.title == e["title"] as? String, "\(name)")
            #expect(item.url?.absoluteString == e["url"] as? String, "\(name)")
            #expect(item.source.rawValue == e["source"] as? String, "\(name)")
            #expect(path == e["folder"] as? [String], "\(name)")
            #expect(item.isAutoFiled == e["folderAuto"] as? Bool, "\(name)")
            #expect(item.tags == e["tags"] as? [String], "\(name)")
            #expect(item.body == e["body"] as? String, "\(name)")
            #expect(item.record[Field.origin]?.object?["bridge"]?.string == e["bridge"] as? String, "\(name)")
            #expect(item.attachments.count == e["attachments"] as? Int, "\(name)")
        }
    }

    @Test func headersRoundTripAndOldOnesStillRead() throws {
        let header = InboxEnvelope.Header(source: "rss", url: "https://a.example", title: "A", folder: ["Feeds", "A"], tags: ["x"])
        let envelope = InboxEnvelope(header: header, body: Data("hi".utf8))
        let back = try InboxEnvelope(decoding: envelope.encoded())
        #expect(back == envelope)
        // Entries written before bridges have no folder or tags; odd values never break an entry.
        let old = try JSONDecoder().decode(InboxEnvelope.Header.self, from: Data(#"{"v":1,"source":"web","receivedAt":"2026-01-01T00:00:00Z"}"#.utf8))
        #expect(old.folder == nil && old.tags == nil && old.folderPath.isEmpty)
        let odd = try JSONDecoder().decode(InboxEnvelope.Header.self, from: Data(#"{"v":1,"source":"rss","receivedAt":"x","folder":7,"tags":[" #A ","a","b"]}"#.utf8))
        #expect(odd.folderPath.isEmpty && odd.tagList == ["a", "b"])
    }
}
