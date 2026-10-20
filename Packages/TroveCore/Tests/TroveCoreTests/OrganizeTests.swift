import Foundation
import Testing
@testable import TroveCore

/// Folders, the organiser, versions and links. The fixtures are shared with web/test/core.test.mjs.
@Suite struct OrganizeTests {
    func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func makeLibrary(_ device: String = "D", transports: [any SyncTransport] = [], keys: VaultKeys = .generate()) -> Library {
        Library(engine: SyncEngine(device: device, keys: keys, transports: transports))
    }

    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("trove-\(UUID())") }

    @Test func organiserMatchesTheSharedCases() throws {
        let f = try fixture("organize-cases")
        for c in try #require(f["paths"] as? [[String: Any]]) {
            let path = Organizer.path(kind: ItemKind(rawValue: c["kind"] as! String)!,
                                      category: (c["category"] as? String).flatMap(ItemCategory.init(rawValue:)),
                                      source: ItemSource(rawValue: c["source"] as! String)!,
                                      fileName: c["fileName"] as? String, collection: c["collection"] as? String,
                                      importPath: c["importPath"] as? [String] ?? [])
            #expect(path == c["expect"] as! [String], "\(c)")
        }
        for c in try #require(f["ids"] as? [[String: Any]]) {
            #expect(Organizer.folderId(parent: c["parent"] as? String, name: c["name"] as! String) == c["expect"] as! String)
        }
    }

    @Test func newItemsAreFiledAndFoldersAreShared() async throws {
        let lib = makeLibrary()
        let pdf = try await lib.addFile(Data("pdf".utf8), name: "Tax.pdf", mime: "application/pdf")
        let sheet = try await lib.addFile(Data("x".utf8), name: "Budget.xlsx", mime: FileImport.mime(forExtension: "xlsx"))
        let note = await lib.addNote(body: "hello")
        let imported = await lib.addNote(title: "Week 1", body: "x", source: .import, folder: ["Uni", "Maths"])
        let folders = await lib.folders()
        let byId = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        func path(_ id: String) async -> [String] {
            guard let f = await lib.item(id)?.folder else { return [] }
            return Folder.path(of: f, in: folders).map(\.name)
        }
        #expect(await path(pdf) == ["Documents"])
        #expect(await path(sheet) == ["Documents", "Spreadsheets"])
        #expect(await path(note) == ["Notes"])
        #expect(await path(imported) == ["Uni", "Maths"])
        #expect(byId["folder:documents"]?.isAuto == true)
        #expect(folders.filter { $0.name == "Documents" }.count == 1)
        #expect(await lib.item(pdf)?.isAutoFiled == true)

        // Two devices filing into "Documents" at once end up with one folder.
        let keys = VaultKeys.generate()
        let shared = FolderTransport(root: tempDir())
        let a = makeLibrary("A", transports: [shared], keys: keys), b = makeLibrary("B", transports: [shared], keys: keys)
        _ = try await a.addFile(Data("1".utf8), name: "a.pdf", mime: "application/pdf")
        _ = try await b.addFile(Data("2".utf8), name: "b.pdf", mime: "application/pdf")
        _ = await a.sync(); _ = await b.sync(); _ = await a.sync()
        #expect(await a.folders().map(\.id) == ["folder:documents"])
        #expect(await b.items().allSatisfy { $0.folder == "folder:documents" })
    }

    @Test func movingRenamingDeletingAndTidyingUp() async throws {
        let lib = makeLibrary()
        let id = await lib.addNote(body: "x")
        let uni = await lib.createFolder("Uni")
        let maths = await lib.createFolder("Maths", in: uni)
        await lib.move(id, to: maths)
        let moved = await lib.item(id)
        #expect(moved?.folder == maths && moved?.isAutoFiled == false)
        await lib.renameFolder(uni, to: "University")
        #expect(await lib.ensureFolder(["university", "MATHS"]) == maths)  // matched by name, ignoring case
        await lib.moveFolder(uni, into: maths)                               // no cycles
        #expect(await lib.folders().first { $0.id == uni }?.parent == nil)
        await lib.deleteFolder(maths)
        #expect(await lib.item(id)?.folder == uni)
        await lib.deleteFolder(uni)
        #expect(await lib.item(id)?.folder == nil)
        #expect(await lib.tidyUp() == 1)
        #expect(await lib.item(id)?.folder == "folder:notes")
        #expect(await lib.tidyUp() == 0)
    }

    @Test func enrichmentRefilesAutoFiledLinksOnly() async throws {
        let lib = makeLibrary()
        let (auto, _) = await lib.addLink(URL(string: "https://food.example/ramen")!)
        let (manual, _) = await lib.addLink(URL(string: "https://food.example/udon")!)
        let mine = await lib.createFolder("Mine")
        await lib.move(manual, to: mine)
        for id in [auto, manual] { await lib.applyEnrichment(id, fields: [Field.category: "recipe"], tier: .basic, by: "D") }
        #expect(await lib.item(auto)?.folder == "folder:recipes")
        #expect(await lib.item(manual)?.folder == mine)
    }

    @Test func fileVersionsKeepEveryEdit() async throws {
        let lib = makeLibrary()
        let id = try await lib.addFile(Data("v1".utf8), name: "notes.txt", mime: "text/plain")
        try await lib.replaceFile(id, data: Data("v2".utf8))
        try await lib.replaceFile(id, data: Data("v3".utf8))
        var item = try #require(await lib.item(id))
        #expect(try await lib.attachmentData(item.attachments[0]) == Data("v3".utf8))
        #expect(item.fileVersions.count == 2)
        #expect(try await lib.attachmentData(item.fileVersions[0].attachment) == Data("v2".utf8))
        await lib.restoreFileVersion(id, item.fileVersions[1])
        item = try #require(await lib.item(id))
        #expect(try await lib.attachmentData(item.attachments[0]) == Data("v1".utf8))
        #expect(item.fileVersions.count == 2)  // v3 and v2 are kept

        // A newer GoodNotes backup keeps the previous one as a version.
        let env = { (body: String) in InboxEnvelope(header: .init(source: "webdav", name: "Bio.goodnotes", meta: ["davPath": "/Bio.goodnotes"]), body: Data(body.utf8)) }
        let nb = try await lib.importInbox(env("one"))
        _ = try await lib.importInbox(env("two"))
        let notebook = try #require(await lib.item(nb))
        #expect(notebook.fileVersions.count == 1 && notebook.kind == .file && notebook.source == .goodnotes)
        #expect(notebook.folder == "folder:handwritten")
    }

    @Test func textVersionsGroupEditingSessions() async throws {
        nonisolated(unsafe) var t: Int64 = 1_000_000
        let engine = SyncEngine(device: "D", keys: .generate(), now: { t })
        let lib = Library(engine: engine)
        let id = await lib.addNote(body: "a")
        t += 10_000; await lib.setBody(id, "ab")
        t += 10_000; await lib.setBody(id, "abc")      // same session
        t += 600_000; await lib.setBody(id, "abcd")    // later session
        let versions = await lib.textVersions(id)
        #expect(versions.map(\.text) == ["abcd", "abc"])
    }

    @Test func inboxEntriesImportedTwiceMakeOneItem() async throws {
        let keys = VaultKeys.generate()
        let shared = FolderTransport(root: tempDir())
        let web = makeLibrary("WEB", transports: [shared], keys: keys), mac = makeLibrary("MAC", transports: [shared], keys: keys)
        let envelope = InboxEnvelope(header: .init(source: "web", mime: "text/plain", title: "A thought"), body: Data("remember this".utf8))
        let a = try await web.importInbox(envelope, entryId: "E1")
        let b = try await mac.importInbox(envelope, entryId: "E1")
        #expect(a == b && a == "inbox-e1")
        _ = await web.sync(); _ = await mac.sync(); _ = await web.sync()
        #expect(await web.items().count == 1)
        #expect(await mac.item(a)?.body == "remember this")
        #expect(await mac.item(a)?.hasConflicts == false)
    }

    @Test func bridgeCopiesAttachmentsToo() async throws {
        let keys = VaultKeys.generate()
        let icloud = FolderTransport(root: tempDir())
        let relayStandIn = FolderTransport(root: tempDir())
        let web = Library(engine: SyncEngine(device: "WEB", keys: keys, transports: [relayStandIn]))
        let mac = SyncEngine(device: "MAC", keys: keys, transports: [icloud, relayStandIn], bridge: true)
        let id = try await web.addFile(Data("photo".utf8), name: "p.jpg", mime: "image/jpeg")
        _ = await web.sync()
        _ = await mac.sync()
        let blob = try #require(await web.item(id)?.attachments.first?.id)
        #expect(try await icloud.hasBlob(blob))
        let phone = Library(engine: SyncEngine(device: "PHONE", keys: keys, transports: [icloud]))
        _ = await phone.sync()
        let att = try #require(await phone.item(id)?.attachments.first)
        #expect(try await phone.attachmentData(att) == Data("photo".utf8))
    }

    @Test func linksMatchTheSharedCases() throws {
        let f = try fixture("links-cases")
        for c in try #require(f["wikilinks"] as? [[String: Any]]) {
            #expect(Links.wikilinks(in: c["text"] as! String) == c["expect"] as! [String])
        }
        let items: [Item] = try #require(f["items"] as? [[String: Any]]).map { o in
            var r = Record(id: o["id"] as! String, kind: "item", createdHLC: "", updatedHLC: "")
            r.fields = [Field.title: .string(o["title"] as! String), Field.createdAt: .number(o["createdAt"] as! Double),
                        Field.tags: JSONValue(o["tags"] as? [String] ?? [])]
            if let links = o["links"] as? [String] { r.fields[Field.links] = JSONValue(links) }
            r.texts = [Field.body: o["body"] as! String]
            return Item(r)
        }
        let graph = Links.graph(items)
        let expected = try #require(f["graph"] as? [String: [String: [String]]])
        #expect(graph.outgoing == expected["outgoing"])
        #expect(graph.incoming == expected["incoming"])
        #expect(graph.unresolved == expected["unresolved"])
        let a = items[0]
        let mentions = Links.mentions(of: a, in: items, linked: Set(graph.neighbours(of: a.id)))
        #expect(mentions.map(\.id) == (f["mentions"] as! [String: [String]])["a"])
        #expect(Links.related(to: a, in: items).map(\.id) == (f["related"] as! [String: [String]])["a"])
    }
}
