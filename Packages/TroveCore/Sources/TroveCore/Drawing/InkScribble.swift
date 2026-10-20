import Foundation

/// Scribble to erase (PROTOCOL.md §10), like core/ink.js `scribbleTargets`; both check
/// Fixtures/ink-scribble.json. Off unless the person turns it on in the eraser's options.
public enum InkScribble {
    /// How many times a line turns back along x or y (moves under 2 points are ignored), the larger.
    public static func reversals(_ pts: [InkPoint]) -> Int {
        var best = 0
        let axes: [KeyPath<InkPoint, Double>] = [\.x, \.y]
        for axis in axes {
            var dir = 0.0, count = 0
            var anchor: Double = pts.first.map { $0[keyPath: axis] } ?? 0
            for p in pts {
                let d = p[keyPath: axis] - anchor
                if abs(d) < 2 { continue }
                let s: Double = d > 0 ? 1 : -1
                if dir != 0 && s != dir { count += 1 }
                dir = s
                anchor = p[keyPath: axis]
            }
            best = max(best, count)
        }
        return best
    }

    private static func cross(_ o: InkPoint, _ p: InkPoint, _ q: InkPoint) -> Double { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }

    private static func segmentsCross(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint, _ d: InkPoint) -> Bool {
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// How many times two lines cross.
    public static func crossings(_ a: [InkPoint], _ b: [InkPoint]) -> Int {
        guard a.count > 1, b.count > 1 else { return 0 }
        var n = 0
        for i in 0..<(a.count - 1) {
            let lox = min(a[i].x, a[i + 1].x), hix = max(a[i].x, a[i + 1].x), loy = min(a[i].y, a[i + 1].y), hiy = max(a[i].y, a[i + 1].y)
            for j in 0..<(b.count - 1) {
                if max(b[j].x, b[j + 1].x) < lox || min(b[j].x, b[j + 1].x) > hix || max(b[j].y, b[j + 1].y) < loy || min(b[j].y, b[j + 1].y) > hiy { continue }
                if segmentsCross(a[i], a[i + 1], b[j], b[j + 1]) { n += 1 }
            }
        }
        return n
    }

    /// The ids a scratch-out crosses out, or nil when the line is an ordinary one.
    public static func targets(_ points: [InkPoint], strokes: [(id: String, points: [InkPoint])]) -> [String]? {
        guard points.count >= 12, let box = InkGeometry.bounds(points), max(box.width, box.height) >= 12 else { return nil }
        var length = 0.0
        for i in 1..<points.count { length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
        guard reversals(points) >= 6, length >= 3.5 * max(box.width, box.height) else { return nil }
        let pad = 4.0, x0 = box.x - pad, y0 = box.y - pad, x1 = box.x + box.width + pad, y1 = box.y + box.height + pad
        var out: [String] = []
        var total = 0
        for s in strokes {
            guard let b = InkGeometry.bounds(s.points) else { continue }
            if b.x > x1 || b.x + b.width < x0 || b.y > y1 || b.y + b.height < y0 { continue }
            let pts = InkGeometry.resample(s.points, spacing: 4)
            let within = pts.filter { $0.x >= x0 && $0.x <= x1 && $0.y >= y0 && $0.y <= y1 }.count
            if Double(within) < 0.7 * Double(pts.count) { continue }
            let n = max(b.width, b.height) < 6
                ? (InkGeometry.hits(points, width: 2, x: b.x + b.width / 2, y: b.y + b.height / 2, radius: 3) ? 2 : 0)
                : crossings(points, s.points)
            if n < (Double(within) >= 0.9 * Double(pts.count) ? 1 : 2) { continue }
            total += n
            out.append(s.id)
        }
        return !out.isEmpty && total >= 4 ? out : nil
    }
}
