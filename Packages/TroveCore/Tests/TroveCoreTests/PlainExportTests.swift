import Foundation
import Testing
@testable import TroveCore

struct PlainExportTests {
    @Test func notesBecomeMarkdownInTheirFolders() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let a = await lib.addNote(title: "Cells: intro", body: "Mitochondria [[ATP]]", tags: ["bio"])
        let b = await lib.addNote(title: "Cells: intro", body: "second")
        let (data, count) = await lib.exportPlain([a, b])
        #expect(count == 2)
        let zip = try ZipArchive(data)
        let names = zip.entries.map(\.path).sorted()
        #expect(names.map { ($0 as NSString).lastPathComponent } == ["Cells- intro 2.md", "Cells- intro.md"])
        let text = String(decoding: try zip.data(for: zip.entries[0]), as: UTF8.self)
        #expect(text.contains("tags: [bio]") && text.contains("Mitochondria [[ATP]]"))
    }
}
