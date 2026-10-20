import Foundation
import Testing
@testable import TroveCore

@Suite struct SearchTests {
    func item(_ id: String, _ fields: [String: JSONValue], body: String = "") -> Item {
        var r = Record(id: id, kind: "item", createdHLC: "", updatedHLC: "")
        r.fields = fields
        r.texts = [Field.body: body]
        return Item(r)
    }

    @Test func tokenizerFoldsStemsAndDropsStopwords() {
        #expect(Tokenizer.terms("The Café's RECIPES, boxes & ideas!") == ["cafe", "recipe", "box", "idea"])
    }

    @Test func rankingPrefixAndFilters() {
        var index = SearchIndex()
        let now = Date()
        index.update(item("1", [Field.title: "Miso ramen recipe", Field.tags: ["food"], Field.category: "recipe", Field.kind: "link", Field.createdAt: JSONValue(now)]))
        index.update(item("2", [Field.title: "Trip notes", Field.kind: "note", Field.createdAt: JSONValue(now)], body: "We had ramen in Tokyo"))
        index.update(item("3", [Field.title: "Desk lamp", Field.category: "product", Field.kind: "link", Field.pinned: true, Field.createdAt: JSONValue(now)]))

        #expect(index.search(.parse("ramen")).map(\.item.id) == ["1", "2"])        // title beats body
        #expect(index.search(.parse("ram")).map(\.item.id).first == "1")             // prefix
        #expect(index.search(.parse("ramen tokyo")).map(\.item.id) == ["2"])         // all words
        #expect(index.search(.parse("ramen type:note")).map(\.item.id) == ["2"])
        #expect(index.search(.parse("is:recipe")).map(\.item.id) == ["1"])
        #expect(index.search(.parse("tag:food")).map(\.item.id) == ["1"])
        #expect(index.search(.parse("is:pinned")).map(\.item.id) == ["3"])
        #expect(index.search(.parse("lamp"), semantic: ["2": 0.9]).count == 2)      // semantic hits join
        index.remove("1")
        #expect(index.search(.parse("miso")).isEmpty)
    }

    @Test func smartCollections() {
        let r = item("1", [Field.category: "recipe", Field.createdAt: JSONValue(Date())])
        #expect(SmartCollection.recipes.contains(r))
        #expect(SmartCollection.recent.contains(r))
        #expect(!SmartCollection.places.contains(r))
        #expect(SmartCollection.handwriting.contains(item("2", [Field.source: "goodnotes"])))
    }
}

@Suite struct LibraryTests {
    func makeLibrary(_ device: String = "D", transports: [any SyncTransport] = [], keys: VaultKeys = .generate()) -> Library {
        Library(engine: SyncEngine(device: device, keys: keys, transports: transports))
    }

    @Test func priceWatchesApplyOntoItemsAndReportNewDrops() async throws {
        let lib = makeLibrary()
        let (id, _) = await lib.addLink(URL(string: "https://shop.example/kettle")!, title: "Kettle")
        await lib.update(id, [Field.category: "product"])
        let url = try #require(await lib.item(id)?.watchableURL)
        await lib.setWatching(id, url: url)
        #expect(await lib.item(id)?.priceWatch?.url == "https://shop.example/kettle")

        func watch(_ prices: [Double], droppedAt: Double?) -> RelayClient.Watch {
            RelayClient.Watch(id: id, url: url.absoluteString, itemId: id, createdAt: 0, checkedAt: 2000, error: nil, price: prices.last,
                              currency: "GBP", lowest: prices.min(), history: prices.enumerated().map { .init(at: Double($0.offset), price: $0.element) },
                              droppedAt: droppedAt)
        }
        #expect(await lib.applyWatches([watch([59.99], droppedAt: nil)]).isEmpty)
        #expect(await lib.item(id)?.priceWatch?.price == 59.99)

        let drops = await lib.applyWatches([watch([59.99, 44], droppedAt: 5000)])
        #expect(drops == [PriceDrop(itemId: id, title: "Kettle", price: 44, previous: 59.99, currency: "GBP")])
        #expect(await lib.item(id)?.priceWatch?.lowest == 44)
        #expect(await lib.applyWatches([watch([59.99, 44], droppedAt: 5000)]).isEmpty) // already seen

        await lib.setWatching(id, url: nil)
        #expect(await lib.item(id)?.priceWatch == nil)
        #expect(await lib.applyWatches([watch([59.99, 30], droppedAt: 9000)]).isEmpty) // tracking is off

        let link = PublishedLink(slug: "abc123def", url: URL(string: "https://relay.example/p/v/abc123def")!)
        await lib.setPublished(id, link)
        #expect(await lib.item(id)?.published == link)
        await lib.setPublished(id, nil)
        #expect(await lib.item(id)?.published == nil)
    }

    @Test func notesLinksDedupeAndSearch() async throws {
        let lib = makeLibrary()
        let note = await lib.addNote(title: "Ideas", body: "Build a #garden app")
        let (link, isNew) = await lib.addLink(URL(string: "https://example.com/post?utm_source=tw")!)
        let (again, isNew2) = await lib.addLink(URL(string: "https://www.example.com/post/")!)
        #expect(isNew && !isNew2 && link == again)
        #expect(await lib.item(link)?.url?.absoluteString == "https://example.com/post")
        #expect(await lib.item(note)?.tags == ["garden"])
        #expect(await lib.search("garden").map(\.id) == [note])
        await lib.setPinned(note, true)
        #expect(await lib.items(in: .pinned).map(\.id) == [note])
        await lib.delete(note)
        #expect(await lib.search("garden").isEmpty)
        #expect(await lib.items().count == 1)
    }

    @Test func duplicatesFromAnotherSourceAreListedThereToo() async {
        let lib = makeLibrary()
        let (id, _) = await lib.addLink(URL(string: "https://example.com/post")!, source: .import)
        let (again, isNew) = await lib.addLink(URL(string: "https://www.example.com/post/?utm_source=x")!, source: .email)
        #expect(again == id && !isNew)
        #expect(await lib.item(id)?.sources == [.import, .email])
        _ = await lib.addLink(URL(string: "https://example.com/post")!, source: .email)
        #expect(await lib.item(id)?.sources == [.import, .email])
        #expect(await lib.search("from:email").map(\.id) == [id])
    }

    @Test func enrichmentRespectsTiersAndUserTitles() async {
        let lib = makeLibrary()
        let (id, _) = await lib.addLink(URL(string: "https://cook.example/r")!, title: "My ramen")
        #expect(await lib.enrichmentQueue(below: .basic).map(\.id) == [id])  // even basic-only devices pick up new items
        #expect(await lib.applyEnrichment(id, fields: [Field.summary: "basic", Field.title: "Page title", Field.tags: ["a"]], tier: .basic, by: "D"))
        #expect(await lib.item(id)?.title == "My ramen")
        #expect(await lib.applyEnrichment(id, fields: [Field.summary: "smart", Field.tags: ["b"]], tier: .onDevice, by: "IPAD"))
        #expect(await lib.enrichmentQueue(below: .basic).isEmpty)
        #expect(await !lib.applyEnrichment(id, fields: [Field.summary: "worse"], tier: .basic, by: "D"))
        let item = await lib.item(id)
        #expect(item?.summary == "smart")
        #expect(item?.tags == ["a", "b"])
        #expect(item?.enrichment?.tier == .onDevice)
        #expect(item?.needsEnrichment == false)
        #expect(await lib.enrichmentQueue(below: .onDevice).isEmpty)
    }

    @Test func filesCollectionsAndImports() async throws {
        let lib = makeLibrary()
        let id = try await lib.addFile(Data("%PDF-1.7".utf8), name: "tax_return-2025.pdf", mime: "application/pdf")
        let item = try #require(await lib.item(id))
        #expect(item.kind == .pdf && item.title == "tax return 2025")
        #expect(try await lib.attachmentData(item.attachments[0]) == Data("%PDF-1.7".utf8))

        let c = await lib.createCollection("Uni")
        #expect(await lib.createCollection("uni") == c)
        await lib.add(id, to: c)
        #expect(await lib.search("in:\(c)").map(\.id) == [id])

        let imported = KindleClippings.parse("Dune (Frank Herbert)\n- Your Highlight on Location 1 | Added on Monday, 3 March 2025 10:00:00\n\nFear is the mind-killer.\n==========")
        #expect(await lib.importItems(imported) == 1)
        #expect(await lib.importItems(imported) == 0)
        #expect(await lib.collections().map(\.name).sorted() == ["Dune", "Uni"])
        #expect(await lib.items(in: .quotes).count == 1)
    }

    @Test func conflictsAreSurfacedAndResolvable() async {
        let keys = VaultKeys.generate()
        let folder = FolderTransport(root: FileManager.default.temporaryDirectory.appendingPathComponent("trove-\(UUID())"))
        let a = Library(engine: SyncEngine(device: "A", keys: keys, transports: [folder]))
        let b = Library(engine: SyncEngine(device: "B", keys: keys, transports: [folder]))
        let id = await a.addNote(body: "line one\nline two")
        await a.sync(); await b.sync()
        await a.setBody(id, "line one\nA's version")
        await b.setBody(id, "line one\nB's version")
        await a.sync(); await b.sync(); await a.sync()
        let itemA = await a.item(id), itemB = await b.item(id)
        #expect(itemA?.body == itemB?.body)
        #expect(itemA?.hasConflicts == true)
        await a.resolveConflicts(id, keeping: "line one\nmerged by hand")
        await a.sync(); await b.sync()
        #expect(await b.item(id)?.hasConflicts == false)
        #expect(await b.item(id)?.body == "line one\nmerged by hand")
    }

    @Test func inboxEnvelopesBecomeItems() async throws {
        let lib = makeLibrary()
        // GoodNotes backup, then a newer backup of the same notebook replaces the PDF.
        let first = InboxEnvelope(header: .init(source: "webdav", name: "Biology.pdf", mime: "application/pdf", meta: ["davPath": "/Goodnotes/Biology.pdf"]), body: Data("v1".utf8))
        let second = InboxEnvelope(header: .init(source: "webdav", name: "Biology.pdf", mime: "application/pdf", meta: ["davPath": "/Goodnotes/Biology.pdf"]), body: Data("v2".utf8))
        let id1 = try await lib.importInbox(first)
        let id2 = try await lib.importInbox(second)
        #expect(id1 == id2)
        let nb = try #require(await lib.item(id1))
        #expect(nb.source == .goodnotes && nb.kind == .pdf)
        #expect(try await lib.attachmentData(nb.attachments[0]) == Data("v2".utf8))

        // Email with an attachment in the same group.
        let mail = InboxEnvelope(header: .init(source: "email", name: "email.html", mime: "text/html", title: "Your receipt", groupId: "g1"),
                                 body: Data("<p>Thanks! Order total £20, receipt attached</p>".utf8))
        let att = InboxEnvelope(header: .init(source: "email", name: "receipt.pdf", mime: "application/pdf", groupId: "g1"), body: Data("pdf".utf8))
        let mailId = try await lib.importInbox(mail)
        #expect(try await lib.importInbox(att) == mailId)
        let m = try #require(await lib.item(mailId))
        #expect(m.kind == .email && m.category == .receipt && m.attachments.count == 1 && m.body.contains("Order total"))

        // Browser selection on a page.
        let web = InboxEnvelope(header: .init(source: "web", mime: "text/plain", url: "https://news.example/a", title: "Story"), body: Data("a quote".utf8))
        let webId = try await lib.importInbox(web)
        #expect(await lib.item(webId)?.body == "a quote")
        #expect(await lib.item(webId)?.source == .web)
    }
}
