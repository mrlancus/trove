import Foundation
import Testing
@testable import TroveCore

/// `Fixtures/import-sample.zip` (made with Python's zipfile): Export/{Ideas.md, long.txt (~200 KB,
/// dynamic Huffman), links.csv (stored), My Clippings.txt, photo.png, nested.zip → Inner note.md},
/// plus __MACOSX and .DS_Store clutter and an empty folder.
@Suite struct FileImportTests {
    func sample() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "import-sample", withExtension: "zip", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func readsZipEntries() throws {
        let zip = try ZipArchive(try sample())
        #expect(zip.entries.count == 9)
        let long = try #require(zip.entries.first { $0.path == "Export/long.txt" })
        #expect(long.method == 8)
        let text = try zip.data(for: long)
        #expect(text.count == 196_710)
        #expect(String(decoding: text, as: UTF8.self).split(separator: "\n").count == 3000)
        let csv = try #require(zip.entries.first { $0.name == "links.csv" })
        #expect(csv.method == 0)
        #expect(String(decoding: try zip.data(for: csv), as: UTF8.self).contains("https://example.com/a"))
    }

    @Test func portableInflateMatchesFixedAndDynamicBlocks() throws {
        let zip = try ZipArchive(try sample())
        for entry in zip.entries where entry.method == 8 {
            let h = entry.localHeaderOffset
            let raw = try sample()
            let start = h + 30 + Int(raw[h + 26]) + Int(raw[h + 27]) << 8 + Int(raw[h + 28]) + Int(raw[h + 29]) << 8
            let out = try Inflate.portable(raw[start..<(start + entry.compressedSize)].withUnsafeBytes { Data($0) }, limit: entry.size)
            #expect(out.count == entry.size, "\(entry.path)")
            #expect(CRC32.checksum(out) == entry.crc32, "\(entry.path)")
        }
    }

    @Test func placedImportsKeepTheirFolders() throws {
        let placed = FileImport.placed(name: "import-sample.zip", data: try sample(), folder: ["Dropped"])
        let byName = Dictionary(placed.compactMap { p -> (String, [String])? in
            switch p.action {
            case .note(let title, _, _): return (title, p.folder)
            case .file(let name, _, _): return (name, p.folder)
            case .items: return nil
            }
        }, uniquingKeysWith: { a, _ in a })
        #expect(byName["photo.png"] == ["Dropped", "import-sample", "Export"])
        #expect(byName.values.contains(["Dropped", "import-sample", "Export", "nested"]))
        #expect(Organizer.clean(byName["photo.png"] ?? []) == ["Dropped", "import-sample", "Export"])
    }

    @Test func rejectsCorruptData() {
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive(Data("not a zip at all, just some words".utf8)) }
        #expect(throws: Inflate.Corrupt.self) { try Inflate.portable(Data([0xFF, 0xFF, 0xFF]), limit: 100) }
    }

    @Test func routesEverythingInsideAZip() throws {
        let actions = FileImport.actions(name: "export.zip", data: try sample())
        var notes: [String] = [], files: [String] = [], items: [ImportedItem] = []
        for a in actions {
            switch a {
            case .note(let title, _, _): notes.append(title)
            case .file(let name, _, let mime): files.append("\(name) \(mime)")
            case .items(let found): items += found
            }
        }
        #expect(Set(notes) == ["Big ideas", "long", "Inside"])
        #expect(files == ["photo.png image/png"])
        #expect(items.filter { $0.kind == .link }.map(\.url) == ["https://example.com/a", "https://example.org/b"])
        #expect(items.filter { $0.kind == .highlight }.map(\.title) == ["Dune"])
        #expect(items.first { $0.kind == .highlight }?.externalId == "kindle:dacb4933b882f63a") // web/test checks the same id
        #expect(FileImport.count(actions) == 7)
    }

    @Test func plainFilesAndJunk() {
        #expect(FileImport.actions(name: "Shopping.txt", data: Data("eggs\nmilk".utf8)) == [.note(title: "Shopping", body: "eggs\nmilk", tags: [])])
        #expect(FileImport.actions(name: "page.html", data: Data("<p>hi</p>".utf8)) == [.file(name: "page.html", data: Data("<p>hi</p>".utf8), mime: "text/html")])
        #expect(FileImport.actions(name: "broken.zip", data: Data("nope".utf8)).count == 1)
        #expect(FileImport.isJunk("__MACOSX/a/._b.md"))
        #expect(FileImport.isJunk("a/.DS_Store"))
        #expect(!FileImport.isJunk("a/b.md"))
    }
}

/// The same files web/test/core.test.mjs reads (web/test/fixtures/files).
@Suite struct FilePreviewTests {
    func webFixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/test/fixtures/files/\(name)")
        return try Data(contentsOf: url)
    }

    @Test func goodNotesAndIWork() throws {
        let gn = try #require(FilePreview.goodnotes(try webFixture("sample.goodnotes")))
        #expect(gn.pages == 2 && gn.thumbnail != nil)
        #expect(gn.documents.map(\.mime) == ["application/pdf", "image/png"])
        #expect(FilePreview.iworkPreview(try webFixture("sample.pages")).map { FilePreview.sniff($0) } == "image/jpeg")
        #expect(FilePreview.goodnotes(Data("not a zip".utf8)) == nil)
    }
}

@Suite struct PasteImportTests {
    func fixture(_ name: String) throws -> Data {
        let (base, ext) = (String(name[..<name.lastIndex(of: ".")!]), String(name[name.index(after: name.lastIndex(of: ".")!)...]))
        return try Data(contentsOf: try #require(Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")))
    }

    @Test func readsPasteLikeTheWebsite() throws {
        let expected = try JSONDecoder().decode([String: JSONValue].self, from: try fixture("paste-expected.json"))
        for (key, result) in [("new", try PasteImport.read(try fixture("paste-new.sqlite"), wal: try fixture("paste-new.sqlite-wal"))),
                              ("old", try PasteImport.read(try fixture("paste-old.db")))] {
            let e = try #require(expected[key]?.object)
            #expect(result.skipped == Int(e["skipped"]?.number ?? -1), "\(key) skipped")
            let want = e["entries"]?.array ?? []
            #expect(result.entries.count == want.count, "\(key) count")
            for (got, w) in zip(result.entries, want) {
                let o = w.object ?? [:]
                #expect(got.text == o["text"]?.string, "\(key) text")
                #expect(got.url == o["url"]?.string)
                #expect(got.app == o["app"]?.string)
                #expect(got.bundle == o["bundle"]?.string)
                #expect(got.title == o["title"]?.string)
                #expect(got.pinboards == (o["pinboards"]?.array ?? []).compactMap(\.string))
                #expect(got.createdAt.map { ($0.timeIntervalSince1970 * 1000).rounded() } == o["createdAt"]?.number, "\(key) date")
                #expect(got.imageMime == o["image"]?.object?["mime"]?.string)
                #expect(got.image.map { Double($0.count) } == o["image"]?.object?["size"]?.number)
            }
        }
    }

    @Test func findsPasteOnTheMac() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let direct = home.appendingPathComponent("Library/Application Support/com.wiheads.paste-direct")
        let store = home.appendingPathComponent("Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste")
        for dir in [direct, store] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: store.appendingPathComponent("db.sqlite"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: store.appendingPathComponent("db.sqlite").path)
        try Data("new".utf8).write(to: direct.appendingPathComponent("db.sqlite"))
        try Data().write(to: direct.appendingPathComponent("db.sqlite-wal"))
        try Data().write(to: direct.appendingPathComponent("index.sqlite"))
        let found = PasteImport.candidates(home: home)
        #expect(found.map(\.db.lastPathComponent) == ["db.sqlite", "db.sqlite"])
        #expect(found.first?.db.deletingLastPathComponent().lastPathComponent == "com.wiheads.paste-direct", "newest first")
        #expect(found.first?.wal?.lastPathComponent == "db.sqlite-wal")
        #expect(found.last?.wal == nil)
    }

    @Test func importsIntoTheClipboard() async throws {
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()))
        let read = try PasteImport.read(try fixture("paste-new.sqlite"), wal: try fixture("paste-new.sqlite-wal"))
        let first = await lib.importClips(read.entries)
        #expect(first.added == read.entries.count)
        let query = try #require(await lib.clips().first { $0.text == "SELECT 1 — ok" })
        #expect(query.sourceApp == "Xcode")
        #expect(query.tags.contains("snippets"))
        #expect(query.title == "Query")
        #expect(await lib.clipEvents(of: query.id).first?.type == .copy)
        let again = await lib.importClips(read.entries)
        #expect(again.added == 0 && again.merged == read.entries.count)
    }
}
