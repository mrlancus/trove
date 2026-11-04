import Foundation

/// Strokes as triangles for the GPU ink renderer (docs/plans/sketch-2-plan.md S3). Drawn every
/// frame at the exact zoom, so ink is never soft while pinching; made once per stroke and cached.
///
/// The shapes are the ones `InkRenderer` (exports, thumbnails) and the website draw:
/// - pens, pencils, fountain pens and brushes: the filled outline (`InkOutline.outlineParts`), as a
///   strip between its two sides plus fans for the round ends;
/// - markers, highlighters, clean shapes and dashed lines: an even line with round ends and joins,
///   made the same way with a constant radius (each dash its own piece);
/// - a closed shape's fill underneath, and arrowheads on lines.
///
/// Triangles of one stroke may overlap (sharp turns, round joins). The renderer draws each stroke
/// at its own depth so a see-through stroke (a highlighter, a pencil) is still blended once.
public enum InkTessellator {
    public struct Part: Sendable, Equatable {
        /// Hex colour; the tool's opacity is applied by the renderer.
        public var color: String
        /// The pencil's grain (sampled in page space by the renderer).
        public var grain: Bool
        /// x, y pairs in page points.
        public var positions: [Float]
        public var indices: [UInt32]

        public var vertexCount: Int { positions.count / 2 }
        public var triangleCount: Int { indices.count / 3 }
    }

    /// One stroke's triangles: its fill (if any) first, then the ink.
    public static func parts(tool: InkTool, color: String, width: Double, points raw: [InkPoint], shape: String? = nil,
                             style: InkStrokeStyle = InkStrokeStyle()) -> [Part] {
        let pts = raw.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = pts.first else { return [] }
        var out: [Part] = []
        if let fill = style.fill, let shape, InkStrokeStyle.closedShapes.contains(shape), pts.count > 2 {
            var m = Mesh()
            m.polygon(pts)
            if !m.indices.isEmpty { out.append(Part(color: fill, grain: false, positions: m.positions, indices: m.indices)) }
        }
        var m = Mesh()
        if let o = InkOutline.outlineParts(tool: tool, width: width, points: pts, shape: shape, style: style) {
            if let dot = o.dot {
                m.fan(centre: centroid(dot), dot, closed: true)
            } else if let lastLeft = o.left.last, let lastRight = o.right.last, let firstLeft = o.left.first, let firstRight = o.right.first {
                m.strip(o.left, o.right)
                m.fan(centre: o.endCentre, [lastLeft] + o.endCap + [lastRight], closed: false)
                m.fan(centre: o.startCentre, [firstRight] + o.startCap + [firstLeft], closed: false)
            }
            out.append(Part(color: color, grain: tool == .pencil, positions: m.positions, indices: m.indices))
            return out
        }
        let w = InkOutline.lineWidth(tool: tool, width: width, points: pts)
        let r = max(0.15, w / 2)
        if pts.count == 1 {
            m.circle(first, r)
            out.append(Part(color: color, grain: false, positions: m.positions, indices: m.indices))
            return out
        }
        let arrow = tool == .highlighter ? nil : style.arrow
        let heads = InkOutline.arrowHeads(tool: tool, width: width, points: pts, shape: shape, arrow: arrow)
        var line = pts
        if let arrow, !heads.isEmpty { line = InkOutline.trimmedForArrows(pts, width: w, arrow: arrow) }
        // Freehand lines go through their points' midpoints with quadratic curves (like CG and canvas).
        let path = shape != nil ? line : smooth(line)
        if let dash = style.dash {
            for piece in dashes(path, pattern: InkOutline.dashPattern(dash, width: w)) {
                if piece.count == 1 { m.circle(piece[0], r) } else { m.thickLine(piece, radius: r) }
            }
        } else {
            m.thickLine(path, radius: r)
        }
        for tri in heads where tri.count == 3 { m.triangle(tri[0], tri[1], tri[2]) }
        out.append(Part(color: color, grain: false, positions: m.positions, indices: m.indices))
        return out
    }

    // MARK: Geometry helpers

    static func centroid(_ p: [InkPoint]) -> InkPoint {
        guard !p.isEmpty else { return InkPoint(x: 0, y: 0) }
        return InkPoint(x: p.map(\.x).reduce(0, +) / Double(p.count), y: p.map(\.y).reduce(0, +) / Double(p.count))
    }

    /// A freehand line through its points' midpoints as quadratic curves, flattened (steps by length).
    static func smooth(_ line: [InkPoint]) -> [InkPoint] {
        guard line.count > 2 else { return line }
        var out: [InkPoint] = [line[0]]
        var from = line[0]
        for i in 1..<(line.count - 1) {
            let c = line[i]
            let to = InkPoint(x: (line[i].x + line[i + 1].x) / 2, y: (line[i].y + line[i + 1].y) / 2)
            let len = hypot(c.x - from.x, c.y - from.y) + hypot(to.x - c.x, to.y - c.y)
            let steps = max(1, min(8, Int((len / 2).rounded(.up))))
            for k in 1...steps {
                let t = Double(k) / Double(steps), u = 1 - t
                out.append(InkPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x, y: u * u * from.y + 2 * u * t * c.y + t * t * to.y))
            }
            from = to
        }
        out.append(line[line.count - 1])
        return out
    }

    /// The "on" pieces of a dashed line (a piece of one point is a dot).
    static func dashes(_ path: [InkPoint], pattern: [Double]) -> [[InkPoint]] {
        guard pattern.count == 2, pattern[0] + pattern[1] > 0, path.count > 1 else { return [path] }
        var out: [[InkPoint]] = []
        var on = true
        var left = pattern[0]
        var current: [InkPoint] = [path[0]]
        for i in 1..<path.count {
            var a = path[i - 1]
            let b = path[i]
            var seg = hypot(b.x - a.x, b.y - a.y)
            while seg > 0 {
                if seg < left {
                    left -= seg
                    if on { current.append(b) }
                    seg = 0
                } else {
                    let k = left / seg
                    let cut = InkPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                    if on {
                        current.append(cut)
                        out.append(dedupe(current))
                    } else {
                        current = [cut]
                    }
                    seg -= left
                    a = cut
                    on.toggle()
                    left = on ? pattern[0] : pattern[1]
                    if on { current = [cut] }
                }
            }
        }
        if on, !current.isEmpty { out.append(dedupe(current)) }
        return out.filter { !$0.isEmpty }
    }

    static func dedupe(_ p: [InkPoint]) -> [InkPoint] {
        var out: [InkPoint] = []
        for q in p where out.last.map({ hypot($0.x - q.x, $0.y - q.y) > 1e-6 }) ?? true { out.append(q) }
        return out
    }

    struct Mesh {
        var positions: [Float] = []
        var indices: [UInt32] = []

        mutating func add(_ p: InkPoint) -> UInt32 {
            let i = UInt32(positions.count / 2)
            positions.append(Float(p.x))
            positions.append(Float(p.y))
            return i
        }

        mutating func triangle(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint) {
            let i = add(a), j = add(b), k = add(c)
            indices += [i, j, k]
        }

        /// Quads between two sides of equal length.
        mutating func strip(_ left: [InkPoint], _ right: [InkPoint]) {
            let n = min(left.count, right.count)
            guard n >= 2 else { return }
            let base = UInt32(positions.count / 2)
            for i in 0..<n { _ = add(left[i]); _ = add(right[i]) }
            for i in 0..<UInt32(n - 1) {
                let l0 = base + i * 2, r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
                indices += [l0, r0, l1, r0, r1, l1]
            }
        }

        /// Triangles from a centre to consecutive rim points.
        mutating func fan(centre: InkPoint, _ rim: [InkPoint], closed: Bool) {
            guard rim.count >= 2 else { return }
            let c = add(centre)
            let base = UInt32(positions.count / 2)
            for p in rim { _ = add(p) }
            let n = UInt32(rim.count)
            for i in 0..<(n - 1) { indices += [c, base + i, base + i + 1] }
            if closed { indices += [c, base + n - 1, base] }
        }

        mutating func circle(_ c: InkPoint, _ r: Double) {
            let steps = max(12, min(48, Int((r * 4).rounded(.up))))
            let rim = (0..<steps).map { k -> InkPoint in
                let a = 2 * Double.pi * Double(k) / Double(steps)
                return InkPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
            fan(centre: c, rim, closed: true)
        }

        /// An even line with round ends and joins: the outline method with a constant radius.
        mutating func thickLine(_ raw: [InkPoint], radius r: Double) {
            let pts = InkTessellator.dedupe(raw)
            guard pts.count >= 2 else { if let p = pts.first { circle(p, r) }; return }
            let n = pts.count
            var dirs: [(x: Double, y: Double)] = []
            for i in 0..<(n - 1) {
                let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y, len = hypot(dx, dy)
                dirs.append(len > 0 ? (dx / len, dy / len) : (i > 0 ? dirs[i - 1] : (1, 0)))
            }
            var left: [InkPoint] = [], right: [InkPoint] = []
            let capSteps = max(8, min(24, Int((r * 2).rounded(.up))))
            func arc(_ side: inout [InkPoint], _ c: InkPoint, _ from: Double, _ to: Double) {
                var delta = to - from
                while delta > Double.pi { delta -= 2 * Double.pi }
                while delta <= -Double.pi { delta += 2 * Double.pi }
                let steps = max(1, Int((abs(delta) / (Double.pi / Double(capSteps))).rounded(.up)))
                for k in 0...steps {
                    let a = from + delta * Double(k) / Double(steps)
                    side.append(InkPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                }
            }
            for i in 0..<n {
                let din = dirs[max(0, i - 1)], dout = dirs[min(n - 2, i)], p = pts[i]
                let turn = din.x * dout.x + din.y * dout.y
                if i > 0, i < n - 1, turn < 0.98 {
                    // Round every real join (a miter would poke out), as CG's round join does.
                    let a0 = atan2(din.y, din.x) + Double.pi / 2, a1 = atan2(dout.y, dout.x) + Double.pi / 2
                    arc(&left, p, a0, a1)
                    arc(&right, p, a0 + Double.pi, a1 + Double.pi)
                    continue
                }
                var tx = din.x + dout.x, ty = din.y + dout.y, len = hypot(tx, ty)
                if len < 1e-9 { tx = dout.x; ty = dout.y; len = 1 }
                let nx = -ty / len, ny = tx / len
                left.append(InkPoint(x: p.x + nx * r, y: p.y + ny * r))
                right.append(InkPoint(x: p.x - nx * r, y: p.y - ny * r))
            }
            strip(left, right)
            let e = dirs[n - 2], ae = atan2(e.y, e.x)
            var endCap: [InkPoint] = []
            for k in 1..<capSteps {
                let a = ae + Double.pi / 2 - Double.pi * Double(k) / Double(capSteps)
                endCap.append(InkPoint(x: pts[n - 1].x + r * cos(a), y: pts[n - 1].y + r * sin(a)))
            }
            fan(centre: pts[n - 1], [left[left.count - 1]] + endCap + [right[right.count - 1]], closed: false)
            let b = dirs[0], ab = atan2(b.y, b.x)
            var startCap: [InkPoint] = []
            for k in 1..<capSteps {
                let a = ab - Double.pi / 2 - Double.pi * Double(k) / Double(capSteps)
                startCap.append(InkPoint(x: pts[0].x + r * cos(a), y: pts[0].y + r * sin(a)))
            }
            fan(centre: pts[0], [right[0]] + startCap + [left[0]], closed: false)
        }

        /// A simple polygon's inside, by ear clipping (a fan if that fails, e.g. self-crossing).
        mutating func polygon(_ raw: [InkPoint]) {
            var pts = InkTessellator.dedupe(raw)
            if pts.count > 3, let f = pts.first, let l = pts.last, hypot(f.x - l.x, f.y - l.y) < 1e-6 { pts.removeLast() }
            guard pts.count >= 3 else { return }
            let base = UInt32(positions.count / 2)
            for p in pts { _ = add(p) }
            var area = 0.0
            for i in 0..<pts.count { let a = pts[i], b = pts[(i + 1) % pts.count]; area += a.x * b.y - b.x * a.y }
            let ccw = area > 0
            var idx = Array(0..<pts.count)
            var out: [UInt32] = []
            func cross(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
            func inside(_ p: InkPoint, _ a: InkPoint, _ b: InkPoint, _ c: InkPoint) -> Bool {
                let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
                return ccw ? (d1 >= 0 && d2 >= 0 && d3 >= 0) : (d1 <= 0 && d2 <= 0 && d3 <= 0)
            }
            var guardCount = 0
            while idx.count > 3, guardCount < pts.count * pts.count {
                guardCount += 1
                var clipped = false
                for k in 0..<idx.count {
                    let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                    let a = pts[i0], b = pts[i1], c = pts[i2]
                    let turn = cross(a, b, c)
                    guard ccw ? turn > 1e-12 : turn < -1e-12 else { continue }
                    if idx.contains(where: { $0 != i0 && $0 != i1 && $0 != i2 && inside(pts[$0], a, b, c) }) { continue }
                    out += [base + UInt32(i0), base + UInt32(i1), base + UInt32(i2)]
                    idx.remove(at: k)
                    clipped = true
                    break
                }
                if !clipped { break }
            }
            if idx.count == 3 {
                out += idx.map { base + UInt32($0) }
                indices += out
            } else {
                // Not a simple polygon: a fan from its first point (what CG's fill shows for convex ones).
                for i in 1..<(pts.count - 1) { indices += [base, base + UInt32(i), base + UInt32(i + 1)] }
            }
        }
    }
}
