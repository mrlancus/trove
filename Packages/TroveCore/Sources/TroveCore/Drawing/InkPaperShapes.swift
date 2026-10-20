import Foundation

/// The lines and dots of a paper (PROTOCOL.md §10), like core/ink.js `paperShapes`; both check
/// Fixtures/ink-papers.json. Renderers draw these in the roles' colours.
public enum InkPaperShapes {
    public enum Role: String, Sendable { case line, bold, accent }

    public enum Shape: Equatable, Sendable {
        case hline(y: Double, x0: Double, x1: Double, role: Role)
        case vline(x: Double, y0: Double, y1: Double, role: Role)
        case dot(x: Double, y: Double, radius: Double)
        case box(x: Double, y: Double, w: Double, h: Double, role: Role)
    }

    /// `area` limits the shapes to what's on screen (the endless canvas), where the papers that lay
    /// out a page (Cornell, planner, storyboard) are plain lined.
    public static func shapes(_ paper: InkPaper, width w: Double, height h: Double, area: InkGeometry.Rect? = nil) -> [Shape] {
        var out: [Shape] = []
        let endless = area != nil
        let x0 = area?.x ?? 0, y0 = area?.y ?? 0, x1 = area.map { $0.x + $0.width } ?? w, y1 = area.map { $0.y + $0.height } ?? h
        var paper = paper
        if endless && (paper == .cornell || paper == .planner || paper == .storyboard) { paper = .lined }
        let s = paper.spacing
        func first(_ start: Double, _ step: Double, _ offset: Double = 0) -> Double { ((start - offset) / step).rounded(.up) * step + offset }
        func hline(_ y: Double, _ r: Role = .line, _ a: Double? = nil, _ b: Double? = nil) { out.append(.hline(y: y, x0: a ?? x0, x1: b ?? x1, role: r)) }
        func vline(_ x: Double, _ r: Role = .line, _ a: Double? = nil, _ b: Double? = nil) { out.append(.vline(x: x, y0: a ?? y0, y1: b ?? y1, role: r)) }
        func ruled(_ step: Double, top: Double? = nil, bottom: Double? = nil) {
            var y = endless ? first(y0, step) : (top ?? step * 3)
            while y < (bottom ?? y1) { hline(y); y += step }
        }
        switch paper {
        case .blank:
            break
        case .lined, .narrow, .wide:
            ruled(s)
        case .margin:
            ruled(s)
            if !endless { hline(s * 2, .accent) }
            if 72 >= x0 && 72 <= x1 { vline(72, .accent) }
        case .grid, .smallgrid, .graph:
            var y = first(y0, s)
            while y < y1 { if y != 0 || endless { hline(y, paper == .graph && Int((y / s).rounded()) % 5 == 0 ? .bold : .line) }; y += s }
            var x = first(x0, s)
            while x < x1 { if x != 0 || endless { vline(x, paper == .graph && Int((x / s).rounded()) % 5 == 0 ? .bold : .line) }; x += s }
        case .dotted, .smalldots:
            var y = first(y0, s)
            while y < y1 {
                var x = first(x0, s)
                while x < x1 {
                    if endless || (x != 0 && y != 0) { out.append(.dot(x: x, y: y, radius: paper == .smalldots ? 1.1 : 1.3)) }
                    x += s
                }
                y += s
            }
        case .isometric:
            let row = s * 3.0.squareRoot() / 2
            var i = Int((y0 / row).rounded(.up))
            while Double(i) * row < y1 {
                let y = Double(i) * row, shift = abs(i) % 2 == 1 ? s / 2 : 0
                if endless || y != 0 {
                    var x = first(x0, s, shift)
                    while x < x1 { if endless || x > 0 { out.append(.dot(x: x, y: y, radius: 1.2)) }; x += s }
                }
                i += 1
            }
        case .cornell:
            let bottom = h * 0.8, cue = w * 0.28, g = InkPaper.spacing
            var y = g * 3
            while y < bottom { hline(y); y += g }
            vline(cue, .accent, g * 2, bottom)
            hline(bottom, .accent)
            hline(g * 2, .accent)
        case .todo:
            var y = endless ? first(y0, s) : s * 2
            while y < y1 {
                hline(y)
                if 40 + 16 >= x0 && 40 <= x1 { out.append(.box(x: 40, y: y - 24, w: 16, h: 16, role: .bold)) }
                y += s
            }
        case .planner:
            let top = 96.0, band = (h - top - 24) / 7
            hline(top - 16, .bold)
            for d in 0..<7 {
                let y = top + Double(d) * band
                hline(y, .accent)
                var l = y + 40
                while l < y + band - 8 { hline(l, .line, 120, x1); l += InkPaper.spacing }
                vline(108, .line, y, y + band)
            }
            hline(top + 7 * band, .accent)
        case .storyboard:
            let pad = 40.0, gap = 32.0, fw = (w - pad * 2 - gap) / 2, fh = fw * 3 / 4, block = (h - pad * 2) / 3
            for r in 0..<3 {
                for c in 0..<2 {
                    let x = pad + Double(c) * (fw + gap), y = pad + Double(r) * block
                    out.append(.box(x: x, y: y, w: fw, h: fh, role: .bold))
                    for dy in [fh + 28, fh + 56] where y + dy < pad + Double(r + 1) * block { hline(y + dy, .line, x, x + fw) }
                }
            }
        case .music:
            var top = first(y0, 80, 40)
            while top < y1 { for k in 0..<5 { hline(top + Double(k) * s) }; top += 80 }
        case .calligraphy:
            var top = endless ? first(y0, 96) : 64
            while top < y1 {
                hline(top); hline(top + 24); hline(top + 48, .bold); hline(top + 68)
                top += 96
            }
        }
        return out
    }
}
