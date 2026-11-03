import Foundation
import Testing
@testable import TroveCore

/// Export to GoodNotes (MASTER_PLAN G13): every file written is read back with Trove's own decoder.
struct GoodNotesWriterTests {
    func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ink.goodnotes"))
    }

    func stroke(_ pts: [(Double, Double)], color: String = "#ff0000", width: Double = 2, highlighter: Bool = false) -> GoodNotesWriter.Stroke {
        GoodNotesWriter.Stroke(color: color, width: width, points: pts.map { InkPoint(x: $0.0, y: $0.1, pressure: 1) }, highlighter: highlighter)
    }

    @Test func roundTripReplacesGoodNotesInkWithTrovesAndKeepsTheRest() throws {
        let original = try fixture()
        let before = try GoodNotesInk.read(original)
        let page = before.pages[0]
        let pictures = page.layers.filter { if case .image = $0 { true } else { false } }.count
        let fills = page.strokes.filter(\.isFill).count
        let ink = GoodNotesWriter.PageInk(strokes: [stroke([(100, 120), (150, 160), (200, 170)], color: "#123456")],
                                          texts: [.init(x: 60, y: 300, w: 160, h: 30, text: "Exported", size: 14, color: "#0000ff")])
        let (data, report) = try GoodNotesWriter.patch(original, pages: [0: ink])
        #expect(report.pages == 1 && report.strokes == 1 && report.texts == 1)
        let after = try GoodNotesInk.read(data)
        #expect(after.pages.count == before.pages.count)
        let out = after.pages[0]
        // GoodNotes' own ink and text are gone; Trove's stroke and text are there.
        let owners = Set(page.strokes.compactMap(\.fillOf))
        #expect(out.strokes.filter { !$0.isFill }.count == 1 + owners.count)
        #expect(out.texts.map { $0.runs.map(\.text).joined() } == ["Exported"])
        // Pictures and fills untouched.
        #expect(out.layers.filter { if case .image = $0 { true } else { false } }.count == pictures)
        #expect(out.strokes.filter(\.isFill).count == fills)
        // Trove's editor gets the same stroke back (positions in points, colour, width).
        let editable = GoodNotesInk.editableInk(out)
        let s = try #require(editable.strokes.first { $0.color == "#123456" })
        #expect(s.color == "#123456")
        #expect(abs(s.points[0].x - 100) < 0.05 && abs(s.points[0].y - 120) < 0.05)
        #expect(abs(s.points.last!.x - 200) < 0.05)
        #expect(abs(s.width - 2) < 0.05)
        // Other pages are unchanged.
        #expect(after.pages[1].strokes.count == before.pages[1].strokes.count)
    }

    @Test func freshNotebookAndWhiteboardReadBack() throws {
        let pages = [
            GoodNotesWriter.FreshPage(width: 595, height: 842, background: nil, ink: .init(strokes: [stroke([(50, 60), (80, 90)])])),
            GoodNotesWriter.FreshPage(width: 595, height: 842, background: nil, ink: .init(strokes: [stroke([(300, 400), (320, 420)], highlighter: true)],
                                                                                         texts: [.init(x: 40, y: 40, w: 200, h: 24, text: "Page two", size: 16, color: "#000000")])),
        ]
        let (data, report) = GoodNotesWriter.notebook(pages)
        #expect(report.pages == 2)
        let book = try GoodNotesInk.read(data)
        #expect(book.pages.count == 2)
        #expect(book.pages[0].strokes.count == 1)
        #expect(book.pages[1].strokes.first?.isHighlighter == true)
        #expect(book.pages[1].text == "Page two")
        let first = GoodNotesInk.editableInk(book.pages[0]).strokes[0]
        #expect(abs(first.points[0].x - 50) < 0.05 && abs(first.points[1].y - 90) < 0.05)

        // A whiteboard: one page, ink far from the origin, no background.
        let board = GoodNotesWriter.notebook([.init(width: 4000, height: 4000, background: nil,
                                                    ink: .init(strokes: [stroke([(3000, 2500), (3100, 2600)])]))])
        let wb = try GoodNotesInk.read(board.data)
        #expect(wb.pages.count == 1)
        #expect(wb.pages[0].strokes.count == 1)
        // Fitted to its content, and it remembers how far it moved things.
        #expect(wb.pages[0].offsetX != 0)
    }

    @Test func zipWriterIsReadable() throws {
        let z = ZipWriter.stored([("a.txt", Array("hello".utf8)), ("dir/b.bin", [0, 1, 2, 255])])
        let archive = try ZipArchive(Data(z))
        #expect(archive.entries.map(\.path) == ["a.txt", "dir/b.bin"])
        #expect(try archive.data(for: archive.entries[0]) == Data("hello".utf8))
    }
}
