import Foundation

/// AI output written into a box you chose on the page (docs/plans/sketch-2-plan.md A3): a diagram
/// fitted to the box with hand-drawn boxes and arrows and handwritten labels, or text written in
/// handwriting at the size of the writing around it. Everything here is made on the device.
public enum InkPlacement {
    /// A stroke to write and what it is (boxes and arrows may take a second colour later).
    public struct Stroke: Sendable, Equatable {
        public enum Role: String, Sendable { case text, line }
        public var points: [InkPoint]
        public var role: Role
    }

    /// The diagram in `box`: laid out, scaled to fit (never above 1.4×), centred.
    public static func diagram(_ spec: DiagramSpec, in box: InkGeometry.Rect, style: InkHandwriting.Style = .neat, seed: UInt64 = 1) -> [Stroke] {
        let base = spec.layout(origin: InkPoint(x: 0, y: 0), fontSize: 16)
        let titleH = (spec.title ?? "").isEmpty ? 0.0 : 34.0
        let w = max(1, base.size.width), h = max(1, base.size.height + titleH)
        let k = min(1.4, min(box.width / w, box.height / h))
        let ox = box.x + (box.width - w * k) / 2, oy = box.y + (box.height - h * k) / 2
        func map(_ p: InkPoint) -> InkPoint { InkPoint(x: ox + p.x * k, y: oy + (p.y + titleH) * k) }
        var r = InkStress.Random(seed: seed)
        var out: [Stroke] = []
        let xh = max(3, 16 * k * 0.42)
        if let title = spec.title, !title.isEmpty {
            var o = InkHandwriting.Options()
            o.style = style; o.xHeight = xh * 1.15; o.seed = seed &+ 1; o.maxWidth = w * k
            let tw = InkHandwriting.width(title, options: o)
            let res = InkHandwriting.write(title, at: InkPoint(x: ox + max(0, (w * k - tw) / 2), y: oy + titleH * k * 0.7), options: o)
            out += res.strokes.map { Stroke(points: $0, role: .text) }
        }
        for (i, b) in base.boxes.enumerated() {
            let a = map(InkPoint(x: b.frame.x, y: b.frame.y)), c = map(InkPoint(x: b.frame.maxX, y: b.frame.maxY))
            let f = InkGeometry.Rect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
            out += handBox(f, random: &r).map { Stroke(points: $0, role: .line) }
            var o = InkHandwriting.Options()
            o.style = style; o.xHeight = xh; o.seed = seed &+ UInt64(i + 2)
            let label = InkGeometry.Rect(x: f.x + 6 * k, y: f.y + 2, width: max(10, f.width - 12 * k), height: f.height - 4)
            // Centred in its box, shrunk to fit.
            let fitted = InkHandwriting.fit(b.label, in: label, options: o, minScale: 0.6) ?? InkHandwriting.write(b.label, at: InkPoint(x: label.x, y: label.y + label.height * 0.65), options: o)
            if let bb = fitted.bounds {
                let dx = (f.x + f.width / 2) - (bb.x + bb.width / 2), dy = (f.y + f.height / 2) - (bb.y + bb.height / 2)
                out += fitted.strokes.map { s in Stroke(points: s.map { InkPoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure, t: $0.t) }, role: .text) }
            }
        }
        for arrow in base.arrows {
            out += handArrow(map(arrow.from), map(arrow.to), head: 9 * max(0.6, k), random: &r).map { Stroke(points: $0, role: .line) }
        }
        return out
    }

    /// Text in `box`, at `xHeight` (shrunk to 70 % if needed, then wrapped beyond), first line at the top.
    public static func text(_ text: String, in box: InkGeometry.Rect, xHeight: Double, style: InkHandwriting.Style = .neat, seed: UInt64 = 1) -> [Stroke] {
        var o = InkHandwriting.Options()
        o.style = style; o.xHeight = xHeight; o.seed = seed; o.maxWidth = box.width
        let res = InkHandwriting.fit(text, in: box, options: o)
            ?? InkHandwriting.write(text, at: InkPoint(x: box.x, y: box.y + xHeight * 1.8), options: o)
        return res.strokes.map { Stroke(points: $0, role: .text) }
    }

    // MARK: Hand-drawn lines

    /// A line as a hand draws it: a slight bow and a little overshoot.
    static func handLine(_ a: InkPoint, _ b: InkPoint, random r: inout InkStress.Random) -> [InkPoint] {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 0.5 else { return [a, b] }
        let nx = -dy / len, ny = dx / len
        let bow = r.range(-0.006, 0.006) * len
        let over = r.range(0.5, 2)
        let n = max(4, Int(len / 3))
        var out: [InkPoint] = []
        for i in 0...n {
            let f = Double(i) / Double(n)
            let e = -over / len + f * (1 + 2 * over / len)
            let curve = sin(f * .pi) * bow
            let p = 0.4 + 0.25 * sin(f * .pi)
            out.append(InkPoint(x: a.x + dx * e + nx * curve, y: a.y + dy * e + ny * curve, pressure: p, t: f * len / 0.2))
        }
        return out
    }

    static func handBox(_ f: InkGeometry.Rect, random r: inout InkStress.Random) -> [[InkPoint]] {
        let tl = InkPoint(x: f.x, y: f.y), tr = InkPoint(x: f.maxX, y: f.y), br = InkPoint(x: f.maxX, y: f.maxY), bl = InkPoint(x: f.x, y: f.maxY)
        return [handLine(tl, tr, random: &r), handLine(tr, br, random: &r), handLine(br, bl, random: &r), handLine(bl, tl, random: &r)]
    }

    static func handArrow(_ a: InkPoint, _ b: InkPoint, head: Double, random r: inout InkStress.Random) -> [[InkPoint]] {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 1 else { return [] }
        let ux = dx / len, uy = dy / len
        let left = InkPoint(x: b.x - ux * head - uy * head * 0.55, y: b.y - uy * head + ux * head * 0.55)
        let right = InkPoint(x: b.x - ux * head + uy * head * 0.55, y: b.y - uy * head - ux * head * 0.55)
        return [handLine(a, b, random: &r), handLine(left, b, random: &r), handLine(right, b, random: &r)]
    }
}
