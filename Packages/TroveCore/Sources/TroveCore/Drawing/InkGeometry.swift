import Foundation

/// The maths behind the sketching tools (PROTOCOL.md §10): lasso selection, moving and resizing,
/// the partial eraser and turning rough drawings into clean shapes. Plain functions on page points,
/// so the website (web/public/core/ink.js) does exactly the same; both check
/// Fixtures/ink-geometry.json, made by web/test/make-ink-fixture.mjs.
public enum InkGeometry {
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// The box around some points, grown by `pad` on every side (half a stroke's width, say).
    public static func bounds(_ points: [InkPoint], pad: Double = 0) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Rect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    public static func union(_ a: Rect?, _ b: Rect?) -> Rect? {
        guard let a else { return b }
        guard let b else { return a }
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return Rect(x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y)
    }

    // MARK: Lasso

    /// Even-odd rule; the polygon closes itself.
    public static func inside(_ x: Double, _ y: Double, polygon: [InkPoint]) -> Bool {
        var result = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }

    /// A stroke is picked up by the lasso when at least half its points are inside.
    public static func lassoSelects(_ points: [InkPoint], lasso: [InkPoint]) -> Bool {
        guard !points.isEmpty, lasso.count >= 3 else { return false }
        let n = points.filter { inside($0.x, $0.y, polygon: lasso) }.count
        return n * 2 >= points.count
    }

    /// A box (text, picture) is picked up when its centre is inside.
    public static func lassoSelects(_ box: Rect, lasso: [InkPoint]) -> Bool {
        lasso.count >= 3 && inside(box.x + box.width / 2, box.y + box.height / 2, polygon: lasso)
    }

    // MARK: Moving and resizing

    /// Scale about an origin (ox, oy), turn by `r` radians (clockwise on the page) about it, then
    /// move: x' = ox + cos r·(x − ox)·sx − sin r·(y − oy)·sy + dx, and y' likewise (PROTOCOL.md §10;
    /// core/ink.js `transformPoint`). With r = 0 that's x' = ox + (x − ox)·sx + dx.
    public struct Transform: Equatable, Sendable {
        public var sx, sy, ox, oy, dx, dy: Double
        /// Radians, clockwise on the page.
        public var r: Double
        public init(sx: Double = 1, sy: Double = 1, ox: Double = 0, oy: Double = 0, dx: Double = 0, dy: Double = 0, r: Double = 0) {
            self.sx = sx; self.sy = sy; self.ox = ox; self.oy = oy; self.dx = dx; self.dy = dy; self.r = r
        }
        public static func move(_ dx: Double, _ dy: Double) -> Transform { Transform(dx: dx, dy: dy) }
        /// What a stroke's width is multiplied by.
        public var widthScale: Double { (abs(sx) * abs(sy)).squareRoot() }

        /// Real numbers, a scale that neither flattens (under 1/1000) nor blows up (over 10,000) and
        /// a move under a million points: anything else is a glitch, not something to store or draw.
        public var isUsable: Bool {
            [sx, sy, ox, oy, dx, dy, r].allSatisfy(\.isFinite) && abs(sx) >= 1e-3 && abs(sy) >= 1e-3 && abs(sx) <= 1e4 && abs(sy) <= 1e4
                && abs(dx) < 1e6 && abs(dy) < 1e6
        }

        /// Turns, mirrors or squashes the nib angle along with the ink: it's needed whenever the
        /// transform does more than scale evenly and move.
        public var changesAngles: Bool { r != 0 || sx != sy || sx < 0 }

        public func apply(_ p: InkPoint) -> InkPoint {
            let x = (p.x - ox) * sx, y = (p.y - oy) * sy
            var out: InkPoint
            if r == 0 {
                out = InkPoint(x: ox + x + dx, y: oy + y + dy, pressure: p.pressure, t: p.t, angle: p.angle)
            } else {
                let c = cos(r), s = sin(r)
                out = InkPoint(x: ox + c * x - s * y + dx, y: oy + s * x + c * y + dy, pressure: p.pressure, t: p.t, angle: p.angle)
            }
            if let a = p.angle, changesAngles { out.angle = angle(a) }
            return out
        }

        /// A nib angle (radians, in [0, π)) after the transform: its direction scaled and turned (core/ink.js `transformAngle`).
        public func angle(_ a: Double) -> Double {
            let x = cos(a) * sx, y = sin(a) * sy
            let turned = atan2(sin(r) * x + cos(r) * y, cos(r) * x - sin(r) * y)
            let out = (turned.truncatingRemainder(dividingBy: Double.pi) + Double.pi).truncatingRemainder(dividingBy: Double.pi)
            return out >= Double.pi - 1e-12 ? 0 : out
        }

        /// The box around a transformed box (its four corners when turned).
        public func apply(_ rect: Rect) -> Rect {
            if r != 0 {
                let corners = [InkPoint(x: rect.x, y: rect.y), InkPoint(x: rect.maxX, y: rect.y), InkPoint(x: rect.maxX, y: rect.maxY), InkPoint(x: rect.x, y: rect.maxY)]
                return InkGeometry.bounds(corners.map(apply)) ?? rect
            }
            let a = apply(InkPoint(x: rect.x, y: rect.y)), b = apply(InkPoint(x: rect.maxX, y: rect.maxY))
            return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
    }

    // MARK: Partial eraser

    /// What's left of a stroke after the eraser (a circle of `radius`) has moved along `path`: the
    /// pieces outside it, or nil when it didn't touch the stroke. Long segments are cut into short
    /// ones first, so an eraser crossing a straight line still splits it.
    public static func erase(_ points: [InkPoint], along path: [InkPoint], radius: Double) -> [[InkPoint]]? {
        guard !points.isEmpty, !path.isEmpty, radius > 0 else { return nil }
        let dense = resample(points, spacing: radius / 2)
        let hit = dense.map { touches(path, $0, radius) }
        guard hit.contains(true) else { return nil }
        var pieces: [[InkPoint]] = []
        var run: [InkPoint] = []
        for (p, gone) in zip(dense, hit) {
            if gone {
                if run.count >= 2 { pieces.append(run) }
                run = []
            } else {
                run.append(p)
            }
        }
        if run.count >= 2 { pieces.append(run) }
        return pieces
    }

    /// True when the eraser's path (a dot, or a line through its samples) comes within `radius` of p.
    static func touches(_ path: [InkPoint], _ p: InkPoint, _ radius: Double) -> Bool {
        if path.count == 1 { return hypot(path[0].x - p.x, path[0].y - p.y) <= radius }
        for i in 0..<(path.count - 1) where segmentDistance(p, path[i], path[i + 1]) <= radius { return true }
        return false
    }

    /// Extra points so no two neighbours are further apart than `spacing` (pressure and time carry over linearly).
    public static func resample(_ points: [InkPoint], spacing: Double) -> [InkPoint] {
        guard points.count >= 2, spacing > 0 else { return points }
        var out = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            // A point that isn't a real number adds nothing (Int(_:) would stop the app); a huge gap at most 100,000.
            let steps = (hypot(b.x - a.x, b.y - a.y) / spacing).rounded(.up)
            let n = steps.isFinite ? Int(min(100_000, steps)) : 1
            if n > 1 {
                for k in 1..<n {
                    let f = Double(k) / Double(n)
                    out.append(InkPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f,
                                        pressure: a.pressure + (b.pressure - a.pressure) * f, t: a.t + (b.t - a.t) * f, angle: a.angle))
                }
            }
            out.append(b)
        }
        return out
    }

    /// Distance from p to the segment a–b.
    public static func segmentDistance(_ p: InkPoint, _ a: InkPoint, _ b: InkPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
        let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0
        return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
    }

    /// True if (x, y) is within `radius` of the stroke's line, counting its width (the stroke eraser).
    public static func hits(_ points: [InkPoint], width: Double, x: Double, y: Double, radius: Double) -> Bool {
        let r = radius + width / 2, p = InkPoint(x: x, y: y)
        if points.count == 1 { return hypot(points[0].x - x, points[0].y - y) <= r }
        for i in 0..<max(0, points.count - 1) where segmentDistance(p, points[i], points[i + 1]) <= r { return true }
        return false
    }

    // MARK: Pens

    /// Fountain pens write like a nib held at 45° (or `nib`, radians): thin along it, broad across it.
    public static let nibAngle = Double.pi / 4

    /// The width of a fountain pen moving by (dx, dy) at a pressure.
    public static func fountainWidth(_ width: Double, pressure: Double, dx: Double, dy: Double, nib: Double = nibAngle) -> Double {
        let p = min(1, max(0, pressure))
        let across = dx == 0 && dy == 0 ? 0.5 : abs(sin(atan2(dy, dx) - nib))
        return width * (0.25 + 0.75 * across) * (0.6 + 0.4 * p)
    }

    /// A brush's ends taper over the first and last 15 % of its points.
    public static func brushTaper(index: Int, count: Int) -> Double {
        guard count > 2 else { return 1 }
        let edge = max(1.0, Double(count) * 0.15)
        return min(1, max(0.15, min(Double(index) + 1, Double(count - index)) / edge))
    }
}
