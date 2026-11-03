import Foundation

/// A big test notebook, made the same way every time (docs/plans/sketch-2-plan.md S1): pages of
/// handwriting-like strokes on different papers, so pan and pinch can be measured on something that
/// would hurt (30 pages × 600 strokes by default).
public enum InkStress {
    /// A small, fast, seeded random source (SplitMix64): the same seed gives the same notebook.
    public struct Random: Sendable {
        private var state: UInt64
        public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0 ..< 1.
        public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
        public mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
    }

    public struct Stroke: Sendable, Equatable {
        public var tool: InkTool
        public var color: String
        public var width: Double
        public var points: [InkPoint]
    }

    public static let papers: [InkPaper] = [.lined, .grid, .dotted, .blank, .narrow, .cornell]
    static let inks = ["#1f2937", "#1f2937", "#1f2937", "#2563eb", "#dc2626", "#16a34a"]

    /// One page's strokes: lines of "words", each word a few joined loops along a baseline, like
    /// handwriting; now and then a highlight across a line or a long underline.
    public static func strokes(page: Int, count: Int, width: Double = 612, height: Double = 792, seed: UInt64 = 1) -> [Stroke] {
        var r = Random(seed: seed &* 1_000_003 &+ UInt64(page))
        var out: [Stroke] = []
        out.reserveCapacity(count)
        let margin = 48.0, lineGap = InkPaper.spacing
        var x = margin, y = margin + lineGap
        while out.count < count {
            if r.unit() < 0.04 {
                // A highlighter stroke across part of the line.
                let len = r.range(80, width - margin * 2 - 40)
                let pts = (0...12).map { i in InkPoint(x: margin + len * Double(i) / 12, y: y - 6 + r.range(-0.8, 0.8), pressure: 0.5, t: Double(i) * 12) }
                out.append(Stroke(tool: .highlighter, color: "#fde047", width: 14, points: pts))
                continue
            }
            let wordWidth = r.range(18, 70)
            if x + wordWidth > width - margin {
                x = margin
                y += lineGap
                if y > height - margin { y = margin + lineGap }
            }
            let ink = r.pick(inks)
            let tool: InkTool = r.unit() < 0.85 ? .pen : r.pick([.pencil, .fountain, .ballpoint])
            let n = Int(r.range(18, 64))
            let size = r.range(7, 12)
            let loops = r.range(2, 6)
            var pts: [InkPoint] = []
            pts.reserveCapacity(n)
            for i in 0..<n {
                let f = Double(i) / Double(n - 1)
                let a = f * loops * 2 * .pi
                let px = x + f * wordWidth + sin(a) * size * 0.25
                let py = y - size * 0.5 - cos(a) * size * 0.5 + r.range(-0.3, 0.3)
                pts.append(InkPoint(x: px, y: py, pressure: 0.35 + 0.3 * sin(f * .pi) + r.range(-0.05, 0.05), t: Double(i) * 8))
            }
            out.append(Stroke(tool: tool, color: ink, width: r.range(1.6, 3), points: pts))
            x += wordWidth + r.range(6, 14)
        }
        return out
    }
}

extension Library {
    /// Makes the test notebook ("Stress test, 30 pages") and returns its id.
    @discardableResult
    public func addStressNotebook(pages: Int = 30, strokesPerPage: Int = 600, seed: UInt64 = 1) async -> String {
        let id = await addSketch(title: "Stress test, \(pages) pages", paper: .lined)
        let list = (0..<pages).map { i in InkPage(id: "stress\(i)", paper: InkStress.papers[i % InkStress.papers.count]) }
        await setPages(id, list)
        for (i, page) in list.enumerated() {
            for s in InkStress.strokes(page: i, count: strokesPerPage, seed: seed) {
                await addStroke(on: id, pageKey: page.id, tool: s.tool, color: s.color, width: s.width, points: s.points)
            }
            if i % 3 == 0 {
                await addElement(on: id, pageKey: page.id, kind: .text, frame: InkGeometry.Rect(x: 340, y: 60, width: 220, height: 30),
                                 text: "Page \(i + 1): test text box", size: 16, color: "#1f2937")
            }
        }
        return id
    }
}
