import Foundation
import Testing
@testable import TroveCore

/// Fixtures/ink.goodnotes is a made-up notebook with every ink layout GoodNotesInk reads;
/// Fixtures/ink-expected.json is what web/public/core/goodnotes.js makes of it
/// (web/test/make-goodnotes-fixture.mjs). The two decoders must agree.
@Suite struct GoodNotesInkTests {
    struct Expected: Decodable {
        struct LZ4: Decodable { var frame: String; var text: String }
        struct Run: Decodable { var text: String; var size: Double; var rgb: [Double]; var bold: Bool; var italic: Bool }
        struct Layer: Decodable {
            var kind: String
            var rgb: [Double]?, alpha: Double?, width: Double?, shape: Bool?, pencil: Bool?, fill: Bool?
            var runs: [[[Double]]]?
            var x: Double?, y: Double?, w: Double?, h: Double?, attachment: String?
            var textRuns: [Run]?

            enum CodingKeys: String, CodingKey { case kind, rgb, alpha, width, shape, pencil, fill, runs, x, y, w, h, attachment }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = try c.decode(String.self, forKey: .kind)
                rgb = try c.decodeIfPresent([Double].self, forKey: .rgb)
                alpha = try c.decodeIfPresent(Double.self, forKey: .alpha)
                width = try c.decodeIfPresent(Double.self, forKey: .width)
                shape = try c.decodeIfPresent(Bool.self, forKey: .shape)
                pencil = try c.decodeIfPresent(Bool.self, forKey: .pencil)
                fill = try c.decodeIfPresent(Bool.self, forKey: .fill)
                x = try c.decodeIfPresent(Double.self, forKey: .x); y = try c.decodeIfPresent(Double.self, forKey: .y)
                w = try c.decodeIfPresent(Double.self, forKey: .w); h = try c.decodeIfPresent(Double.self, forKey: .h)
                attachment = try c.decodeIfPresent(String.self, forKey: .attachment)
                if kind == "text" { textRuns = try c.decode([Run].self, forKey: .runs) } else { runs = try c.decodeIfPresent([[[Double]]].self, forKey: .runs) }
            }
        }
        struct Page: Decodable { var id: String; var width: Double; var height: Double; var background: GoodNotesInk.Background?; var unread: Int; var layers: [Layer] }
        var lz4: LZ4
        var pages: [Page]
    }

    func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }

    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.011 }

    @Test func decodesTheSameAsTheWebsite() throws {
        let expected = try JSONDecoder().decode(Expected.self, from: try fixture("ink-expected", "json"))
        let frame = [UInt8](try #require(Data(base64Encoded: expected.lz4.frame)))
        #expect(String(decoding: try GoodNotesInk.appleLZ4(frame[...]).0, as: UTF8.self) == expected.lz4.text)

        let notebook = try GoodNotesInk.read(try fixture("ink", "goodnotes"))
        #expect(notebook.pages.map(\.id) == expected.pages.map(\.id))
        for (page, want) in zip(notebook.pages, expected.pages) {
            #expect(close(page.width, want.width) && close(page.height, want.height))
            #expect(page.background == want.background)
            #expect(page.layers.count == want.layers.count)
            #expect(page.unread == want.unread)
            for (layer, w) in zip(page.layers, want.layers) {
                switch layer {
                case .ink(let s):
                    #expect(w.kind == "ink")
                    #expect(zip(s.rgb, w.rgb ?? []).allSatisfy { close($0, $1) } && close(s.alpha, w.alpha ?? -1) && close(s.width, w.width ?? -1))
                    #expect(s.isShape == w.shape && s.isPencil == w.pencil && s.isFill == (w.fill ?? false))
                    let runs = w.runs ?? []
                    #expect(s.runs.count == runs.count)
                    for (run, wantRun) in zip(s.runs, runs) {
                        #expect(run.count == wantRun.count)
                        for (p, q) in zip(run, wantRun) { #expect(close(p.x, q[0]) && close(p.y, q[1]) && close(p.r, q[2]), "\(p) vs \(q)") }
                    }
                case .text(let t):
                    #expect(w.kind == "text")
                    #expect(close(t.x, w.x ?? -1) && close(t.y, w.y ?? -1) && close(t.w, w.w ?? -1) && close(t.h, w.h ?? -1))
                    #expect(t.runs.map(\.text) == (w.textRuns ?? []).map(\.text))
                    #expect(t.runs.map(\.bold) == (w.textRuns ?? []).map(\.bold))
                    #expect(zip(t.runs, w.textRuns ?? []).allSatisfy { close($0.size, $1.size) })
                case .image(let i):
                    #expect(w.kind == "image" && i.attachment == w.attachment)
                    #expect(close(i.x, w.x ?? -1) && close(i.y, w.y ?? -1) && close(i.w, w.w ?? -1) && close(i.h, w.h ?? -1))
                }
            }
        }
        let first = try #require(notebook.pages.last)
        #expect(first.text == "Hello world\nagain")
        #expect(first.strokes.contains { $0.isHighlighter && $0.runs.count == 2 })
    }

    /// Whiteboards: drawing far from 0, 0 or on a huge page is cropped to what's there (same numbers
    /// as the fitToContent test in web/test/core.test.mjs).
    @Test func whiteboardFitsContent() {
        typealias G = GoodNotesInk
        let stroke = G.Stroke(id: nil, rgb: [0, 0, 0], alpha: 1, width: 2, runs: [[G.Point(x: -1320, y: 5280, r: 2), G.Point(x: 1100, y: 7700, r: 2)]])
        let page = G.Page(id: "p", width: 612, height: 792, background: nil, layers: [.ink(stroke)])
        let fit = G.fitToContent(page)
        #expect(abs(fit.width - (2424 * G.scale + 72)) < 0.001 && abs(fit.height - (2424 * G.scale + 72)) < 0.001)
        guard case .ink(let s) = fit.layers[0] else { Issue.record("no ink"); return }
        #expect(abs((s.runs[0][0].x - 2) * G.scale - 36) < 0.001)
        #expect(abs((s.runs[0][0].y - 2) * G.scale - 36) < 0.001)

        let inside = G.Page(id: "q", width: 612, height: 792, background: nil, layers: [.ink(G.Stroke(id: nil, rgb: [0, 0, 0], alpha: 1, width: 2, runs: [[G.Point(x: 100, y: 100, r: 2)]]))])
        #expect(G.fitToContent(inside).width == 612)

        let huge = G.Page(id: "h", width: 20000, height: 20000, background: G.Background(attachment: "a", page: 1), layers: [])
        let blank = G.fitToContent(huge)
        #expect(blank.width == 612 && blank.background == nil)
    }

    @Test func notANotebook() {
        #expect(throws: GoodNotesInk.Failure.self) { try GoodNotesInk.read(Data("hello".utf8)) }
    }
}
