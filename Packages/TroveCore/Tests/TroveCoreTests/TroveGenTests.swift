import Foundation
import Testing
@testable import TroveCore

/// trove-gen (docs/PERF_AUDIT.md step 0): the same seed always gives the same vault, and the vault it
/// writes opens like any folder vault.
struct TroveGenTests {
    @Test func theSameSeedGivesTheSameOps() throws {
        let a = TroveGen.ops(.tiny), b = TroveGen.ops(.tiny)
        #expect(a == b)
        var other = TroveGen.Size.tiny
        other.seed = 7
        #expect(TroveGen.ops(other) != a)
        // Contiguous sequence numbers from 1, increasing HLCs: a valid journal.
        #expect(a.map(\.seq) == Array(1...a.count))
        #expect(zip(a, a.dropFirst()).allSatisfy { $0.hlc < $1.hlc })
    }

    @Test func itMakesWhatTheSizeSays() {
        let size = TroveGen.Size.tiny
        var store = RecordStore()
        store.apply(TroveGen.ops(size))
        let items = store.visible(kind: "item")
        #expect(items.count == size.items + 2 + size.pdfs + 1) // + notebook, whiteboard, big PDF
        #expect(store.visible(kind: "clip").count == size.clips)
        #expect(store.ink(on: TroveGen.notebookId).count == size.notebookPages * size.strokesPerPage)
        #expect(store.ink(on: TroveGen.whiteboardId).count == size.whiteboardStrokes)
        let notes = items.map(Item.init).filter { $0.kind == .note }
        #expect(!notes.isEmpty && notes.allSatisfy { !$0.body.isEmpty })
        #expect(Item(store.record(TroveGen.bigPDFId)!).attachments.first?.mime == "application/pdf")
    }

    @Test func itsPDFsAreWellFormed() throws {
        let data = TroveGen.pdf(pages: 3, title: "A (test)")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("%PDF-1.4"))
        #expect(text.contains("/Count 3"))
        #expect(text.contains("A \\(test\\)"))
        // Every xref offset points at "n 0 obj".
        let startxref = try #require(text.range(of: "startxref\n")).upperBound
        let xrefAt = Int(text[startxref...].prefix { $0.isNumber })!
        let bytes = Array(data)
        #expect(String(decoding: bytes[xrefAt..<(xrefAt + 4)], as: UTF8.self) == "xref")
        let table = text[text.index(text.startIndex, offsetBy: xrefAt)...].split(separator: "\n").dropFirst(3).prefix(9)
        for (i, line) in table.enumerated() {
            let offset = Int(line.prefix(10))!
            #expect(String(decoding: bytes[offset..<(offset + 10)], as: UTF8.self).hasPrefix("\(i + 1) 0 obj"))
        }
    }

    @Test func segmentsStayUnderTheLimit() throws {
        let ops = TroveGen.ops(TroveGen.Size.small.scaled(0.2))
        let segments = try TroveGen.segments(ops)
        #expect(segments.count > 1)
        #expect(segments.flatMap(\.ops) == ops)
        for s in segments { #expect(try s.plaintext().count <= Segment.maxPlaintextBytes) }
    }

    @Test func theFolderVaultOpensOnANewDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trove-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let size = TroveGen.Size.tiny
        let id = try await TroveGen.writeFolderVault(at: root, size)
        #expect(try FolderTransport(root: root).readVaultInfo()?.encrypted == false)
        // Writing again is a no-op.
        #expect(try await TroveGen.writeFolderVault(at: root, size) == id)

        let engine = SyncEngine(device: "READER", keys: nil, encrypted: false, transports: [FolderTransport(root: root)])
        let report = await engine.sync()
        #expect(report.errors.isEmpty)
        #expect(await engine.records(kind: "clip").count == size.clips)
        #expect(await engine.ink(on: TroveGen.notebookId).count == size.notebookPages * size.strokesPerPage)
        let pdf = Item(try #require(await engine.record(TroveGen.bigPDFId)))
        let bytes = try await FolderTransport(root: root).fetchBlob(try #require(pdf.attachments.first).id)
        #expect(bytes.prefix(5) == Data("%PDF-".utf8))
    }
}
