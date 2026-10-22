import Foundation

/// Turns a rough drawing into a clean shape (shape mode, or holding the pen still at the end of a
/// stroke): a line, a few joined lines, a triangle, a rectangle, another polygon, a circle or an
/// ellipse (PROTOCOL.md §10). Corners come first: a loop whose corners are all sharp becomes a
/// polygon, not an ellipse. Then the standard shape wins whenever the drawing is near one: a square,
/// an equilateral, isosceles or right-angled triangle, a regular polygon, a circle, edges exactly
/// level or upright. Deterministic, so the website's `recognizeShape` (ink.js) gives the same; both
/// check Fixtures/ink-geometry.json.
public enum InkShapes {
    public enum Shape: String, Sendable, CaseIterable {
        case line, polyline, triangle, rectangle, polygon, circle, ellipse
    }

    public struct Result: Sendable {
        public var shape: Shape
        public var points: [InkPoint]
        public init(shape: Shape, points: [InkPoint]) { self.shape = shape; self.points = points }
    }

    /// Smaller than this (page points across) is a dot or a tick, not a shape.
    static let minimumSize = 12.0
    static let degree = Double.pi / 180
    /// A corner is sharp when the pen turns at least this many times as much round it as along the sides beside it.
    static let sharp = 2.0
    /// How far either side of a point its turn is measured, as a share of the loop's length.
    static let sharpWindow = 0.035

    public static func recognize(_ raw: [InkPoint]) -> Result? {
        guard raw.count >= 2, let box = InkGeometry.bounds(raw) else { return nil }
        let diag = hypot(box.width, box.height)
        guard diag >= minimumSize else { return nil }
        let first = raw[0], last = raw[raw.count - 1]
        let pressure = raw.map(\.pressure).reduce(0, +) / Double(raw.count)
        let duration = last.t - first.t
        let ends = hypot(last.x - first.x, last.y - first.y)

        if ends > 0.2 * diag {
            // Open: a straight line, or up to three straight pieces.
            let deviation = raw.map { InkGeometry.segmentDistance($0, first, last) }.max() ?? 0
            if deviation <= 0.08 * ends { return finish(.line, levelPath([first, last]), pressure, duration) }
            let corners = simplify(raw, epsilon: 0.08 * diag)
            if corners.count <= 4 { return finish(.polyline, levelPath(corners), pressure, duration) }
            return nil
        }

        // Closed: the loop up to where it comes back nearest its start (an overshoot past it would add a corner).
        let loop = closedLoop(raw)
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        let rx = max(box.width / 2, 0.5), ry = max(box.height / 2, 0.5)
        let error = loop.map { abs(hypot(($0.x - cx) / rx, ($0.y - cy) / ry) - 1) }.reduce(0, +) / Double(loop.count)
        let corners = simplifyClosed(loop, epsilon: 0.1 * diag)
        let polygonFit = (3...8).contains(corners.count)
            ? loop.map { polygonDistance($0, corners) }.reduce(0, +) / Double(loop.count) / diag : Double.infinity
        let ellipseFit = error * (rx + ry) / 2 / diag
        // Every corner sharp: a polygon, even where an ellipse would fit as well (rounded corners, bowed
        // or uneven sides). Sharp: the pen turns much more round the corner than along the sides beside it.
        let contrast = polygonFit < 0.1 ? cornerContrast(loop, corners) : []
        let isSharp = contrast.count >= 3 && (contrast.min() ?? 0) >= sharp
        if !isSharp, error < 0.18, ellipseFit <= polygonFit {
            let round = abs(rx - ry) <= 0.18 * max(rx, ry)
            let r = (rx + ry) / 2
            let points = (0...64).map { i -> InkPoint in
                let a = Double(i) / 64 * 2 * Double.pi
                return InkPoint(x: cx + (round ? r : rx) * cos(a), y: cy + (round ? r : ry) * sin(a))
            }
            return finish(round ? .circle : .ellipse, points, pressure, duration)
        }
        if !isSharp, polygonFit >= 0.05 { return nil }
        switch corners.count {
        case 3:
            let c = cleanTriangle(corners)
            return finish(.triangle, c + [c[0]], pressure, duration)
        case 4:
            let c = cleanQuad(corners)
            return finish(.rectangle, c + [c[0]], pressure, duration)
        case 5...8:
            let c = regular(corners) ?? corners
            return finish(.polygon, c + [c[0]], pressure, duration)
        default:
            return nil
        }
    }

    /// A closed drawing up to the point in its last fifth nearest its start.
    static func closedLoop(_ raw: [InkPoint]) -> [InkPoint] {
        var end = raw.count - 1, near = Double.infinity
        for i in Int((0.8 * Double(raw.count)).rounded(.down))..<raw.count {
            let d = hypot(raw[i].x - raw[0].x, raw[i].y - raw[0].y)
            if d < near { near = d; end = i }
        }
        return Array(raw[...end])
    }

    /// How sharp each of a loop's corners is: the most the pen turns near it (over a short stretch
    /// either side), over how much it turns half way along the sides before and after it. About 1 round
    /// a circle or an ellipse's sides; several times that at a real corner, even a rounded one or
    /// between bowed sides.
    static func cornerContrast(_ raw: [InkPoint], _ corners: [InkPoint]) -> [Double] {
        let loop = raw + [raw[0]]
        var at = [0.0]
        for i in 1..<loop.count { at.append(at[i - 1] + hypot(loop[i].x - loop[i - 1].x, loop[i].y - loop[i - 1].y)) }
        let total = at[at.count - 1]
        let n = corners.count
        guard total > 0, n >= 3 else { return [] }
        func pointAt(_ s: Double) -> InkPoint {
            let d = (s.truncatingRemainder(dividingBy: total) + total).truncatingRemainder(dividingBy: total)
            var j = 0
            while j < loop.count - 2 && at[j + 1] < d { j += 1 }
            let span = at[j + 1] - at[j], f = span > 0 ? (d - at[j]) / span : 0
            return InkPoint(x: loop[j].x + (loop[j + 1].x - loop[j].x) * f, y: loop[j].y + (loop[j + 1].y - loop[j].y) * f)
        }
        let window = sharpWindow * total
        func turnAt(_ s: Double) -> Double { turn(pointAt(s - window), pointAt(s), pointAt(s + window)) }
        // Where along the loop each corner is (its nearest point).
        let place = corners.map { c -> Double in
            var index = 0, best = Double.infinity
            for i in 0..<raw.count {
                let d = hypot(raw[i].x - c.x, raw[i].y - c.y)
                if d < best { best = d; index = i }
            }
            return at[index]
        }
        func middle(_ from: Double, _ to: Double) -> Double {
            from + ((to - from).truncatingRemainder(dividingBy: total) + total).truncatingRemainder(dividingBy: total) / 2
        }
        func along(_ s: Double) -> Double { [-1, -0.5, 0, 0.5, 1].reduce(0.0) { $0 + turnAt(s + $1 * window) } / 5 }
        return (0..<n).map { k in
            // The sharpest turn near the corner (it's seldom exactly where the corner was found).
            var most = 0.0
            for i in 0..<raw.count {
                var gap = abs(at[i] - place[k])
                gap = min(gap, total - gap)
                if gap <= window { most = max(most, turnAt(at[i])) }
            }
            // A real corner turns at least 35° (round a circle with many soft corners each turns less).
            if most < 35 * degree { return 0 }
            // Along each side beside it: the average turn over the same stretch round its middle.
            let sides = (along(middle(place[(k + n - 1) % n], place[k])) + along(middle(place[k], place[(k + 1) % n]))) / 2
            return most / max(sides, 2 * degree)
        }
    }

    /// How far the direction turns going a → b → c, 0 to π.
    static func turn(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint) -> Double {
        var d = abs(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x))
        if d > Double.pi { d = 2 * Double.pi - d }
        return d
    }

    /// The angle inside a corner, 0 to π.
    static func inner(_ prev: InkPoint, _ c: InkPoint, _ next: InkPoint) -> Double { Double.pi - turn(prev, c, next) }

    /// A level or upright edge stays so: the turn that makes it exactly so when within `limit`, else nil.
    static func levelTurn(_ a: InkPoint, _ b: InkPoint, limit: Double) -> Double? {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let snapped = (angle / (Double.pi / 2) + 0.5).rounded(.down) * (Double.pi / 2)
        return abs(angle - snapped) <= limit ? snapped - angle : nil
    }

    /// An open line's pieces: each one within 8° of level or upright made exactly so (what follows moves with it).
    static func levelPath(_ pts: [InkPoint]) -> [InkPoint] {
        var out = [InkPoint(x: pts[0].x, y: pts[0].y)]
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i], from = out[i - 1]
            var dx = b.x - a.x, dy = b.y - a.y
            if let t = levelTurn(a, b, limit: 8 * degree) {
                let c = cos(t), s = sin(t)
                (dx, dy) = (dx * c - dy * s, dx * s + dy * c)
            }
            out.append(InkPoint(x: from.x + dx, y: from.y + dy))
        }
        return out
    }

    static func centre(_ corners: [InkPoint]) -> (x: Double, y: Double) {
        (corners.map(\.x).reduce(0, +) / Double(corners.count), corners.map(\.y).reduce(0, +) / Double(corners.count))
    }

    /// Turns corners about their middle by `t` radians.
    static func turned(_ corners: [InkPoint], _ t: Double) -> [InkPoint] {
        let (cx, cy) = centre(corners)
        let c = cos(t), s = sin(t)
        return corners.map { InkPoint(x: cx + ($0.x - cx) * c - ($0.y - cy) * s, y: cy + ($0.x - cx) * s + ($0.y - cy) * c) }
    }

    /// The polygon turned so its edge nearest level or upright is exactly so (within 7°).
    static func levelled(_ corners: [InkPoint]) -> [InkPoint] {
        var best: Double?
        for (i, a) in corners.enumerated() {
            if let t = levelTurn(a, corners[(i + 1) % corners.count], limit: 7 * degree), best == nil || abs(t) < abs(best!) { best = t }
        }
        return best.map { turned(corners, $0) } ?? corners
    }

    /// A regular polygon near the corners (sides and angles all close to equal), standing level; else nil.
    static func regular(_ corners: [InkPoint]) -> [InkPoint]? {
        let n = corners.count
        let sides = (0..<n).map { i in hypot(corners[(i + 1) % n].x - corners[i].x, corners[(i + 1) % n].y - corners[i].y) }
        let target = Double(n - 2) * Double.pi / Double(n)
        let worst = (0..<n).map { i in abs(inner(corners[(i + n - 1) % n], corners[i], corners[(i + 1) % n]) - target) }.max() ?? 0
        let (ratio, limit) = n == 3 ? (1.25, 15.0) : (1.4, 20.0)
        guard let longest = sides.max(), let shortest = sides.min(), longest <= ratio * shortest, worst <= limit * degree else { return nil }
        let (cx, cy) = centre(corners)
        let r = corners.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / Double(n)
        var area = 0.0
        for i in 0..<n { let a = corners[i], b = corners[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
        let step = (area >= 0 ? 1.0 : -1.0) * 2 * Double.pi / Double(n)
        var sx = 0.0, sy = 0.0
        for (i, p) in corners.enumerated() {
            let a = atan2(p.y - cy, p.x - cx) - Double(i) * step
            sx += cos(a); sy += sin(a)
        }
        var phase = atan2(sy, sx)
        // Standing level: a corner straight up or an edge along the top, when within 10°.
        let snapped = -Double.pi / 2 + ((phase + Double.pi / 2) / (Double.pi / Double(n)) + 0.5).rounded(.down) * (Double.pi / Double(n))
        if abs(phase - snapped) <= 10 * degree { phase = snapped }
        return (0..<n).map { i in InkPoint(x: cx + r * cos(phase + Double(i) * step), y: cy + r * sin(phase + Double(i) * step)) }
    }

    /// A triangle: equilateral if near one; else a right angle made exact, or two near-equal sides made
    /// equal; standing level.
    static func cleanTriangle(_ corners: [InkPoint]) -> [InkPoint] {
        if let even = regular(corners) { return even }
        var c = corners.map { InkPoint(x: $0.x, y: $0.y) }
        if let right = (0..<3).first(where: { i in abs(inner(c[(i + 2) % 3], c[i], c[(i + 1) % 3]) - Double.pi / 2) <= 12 * degree }) {
            let b = c[right], a = c[(right + 2) % 3], k = (right + 1) % 3, o = c[k]
            let la = hypot(a.x - b.x, a.y - b.y), lo = hypot(o.x - b.x, o.y - b.y)
            let ux = (a.x - b.x) / la, uy = (a.y - b.y) / la
            let side = (o.x - b.x) * -uy + (o.y - b.y) * ux >= 0 ? 1.0 : -1.0
            c[k] = InkPoint(x: b.x - uy * side * lo, y: b.y + ux * side * lo)
        } else {
            for i in 0..<3 {
                let v = c[i], p = c[(i + 2) % 3], q = c[(i + 1) % 3]
                let lp = hypot(p.x - v.x, p.y - v.y), lq = hypot(q.x - v.x, q.y - v.y)
                if abs(lp - lq) > 0.1 * max(lp, lq) { continue }
                // The apex over the middle of the base.
                let mx = (p.x + q.x) / 2, my = (p.y + q.y) / 2, bl = hypot(q.x - p.x, q.y - p.y)
                let nx = -(q.y - p.y) / bl, ny = (q.x - p.x) / bl, h = (v.x - mx) * nx + (v.y - my) * ny
                c[i] = InkPoint(x: mx + nx * h, y: my + ny * h)
                break
            }
        }
        return levelled(c)
    }

    /// Four corners: a rectangle (a square when its sides are near equal) when the angles are near
    /// right, level or upright when near; else a regular one if near, or as drawn.
    static func cleanQuad(_ corners: [InkPoint]) -> [InkPoint] {
        let right = (0..<4).allSatisfy { i in abs(inner(corners[(i + 3) % 4], corners[i], corners[(i + 1) % 4]) - Double.pi / 2) <= 15 * degree }
        guard right else { return regular(corners) ?? corners }
        // The rectangle's direction: the edges' average, a quarter turn counting as the same.
        var sx = 0.0, sy = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], t = 4 * atan2(b.y - a.y, b.x - a.x)
            sx += cos(t); sy += sin(t)
        }
        var phase = atan2(sy, sx) / 4
        if abs(phase) <= 12 * degree { phase = 0 }
        let ux = cos(phase), uy = sin(phase)
        let (cx, cy) = centre(corners)
        let across = corners.map { p in (u: (p.x - cx) * ux + (p.y - cy) * uy, v: -(p.x - cx) * uy + (p.y - cy) * ux) }
        var w = across.map { abs($0.u) }.reduce(0, +) / 2, h = across.map { abs($0.v) }.reduce(0, +) / 2
        if abs(w - h) <= 0.15 * max(w, h) { w = (w + h) / 2; h = w }
        // Each corner keeps its side of the middle (so the order it was drawn in); two on one side: as drawn.
        let signs = across.map { ($0.u >= 0 ? 1 : -1, $0.v >= 0 ? 1 : -1) }
        guard Set(signs.map { "\($0.0),\($0.1)" }).count == 4 else { return corners }
        return zip(across, signs).map { q, s in
            let u = Double(s.0) * w / 2, v = Double(s.1) * h / 2
            return InkPoint(x: cx + u * ux - v * uy, y: cy + u * uy + v * ux)
        }
    }

    /// Distance from p to the closed polygon's edges.
    static func polygonDistance(_ p: InkPoint, _ corners: [InkPoint]) -> Double {
        var best = Double.infinity
        for i in 0..<corners.count { best = min(best, InkGeometry.segmentDistance(p, corners[i], corners[(i + 1) % corners.count])) }
        return best
    }

    /// Even pressure (the stroke's average) and times spread evenly over the drawing's duration.
    static func finish(_ shape: Shape, _ points: [InkPoint], _ pressure: Double, _ duration: Double) -> Result {
        let n = points.count
        let out = points.enumerated().map { i, p in
            InkPoint(x: p.x, y: p.y, pressure: pressure, t: n > 1 ? duration * Double(i) / Double(n - 1) : 0)
        }
        return Result(shape: shape, points: out)
    }

    /// Ramer–Douglas–Peucker: the corners of an open line.
    static func simplify(_ points: [InkPoint], epsilon: Double) -> [InkPoint] {
        guard points.count >= 3 else { return points }
        let a = points[0], b = points[points.count - 1]
        var index = 0, far = 0.0
        for i in 1..<(points.count - 1) {
            let d = InkGeometry.segmentDistance(points[i], a, b)
            if d > far { far = d; index = i }
        }
        guard far > epsilon else { return [a, b] }
        let left = simplify(Array(points[...index]), epsilon: epsilon)
        let right = simplify(Array(points[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// The corners of a closed loop: split at the point furthest from the start, simplify both halves
    /// and drop corners that land on top of each other (where the loop closes).
    static func simplifyClosed(_ points: [InkPoint], epsilon: Double) -> [InkPoint] {
        let start = points[0]
        var index = 0, far = 0.0
        for (i, p) in points.enumerated() where hypot(p.x - start.x, p.y - start.y) > far {
            far = hypot(p.x - start.x, p.y - start.y); index = i
        }
        guard index > 0 else { return [start] }
        let one = simplify(Array(points[...index]), epsilon: epsilon)
        let two = simplify(Array(points[index...]) + [start], epsilon: epsilon)
        var corners = Array(one.dropLast()) + Array(two.dropLast())
        // Merge corners closer than epsilon (the end of the loop meeting its start, a wobble).
        var merged: [InkPoint] = []
        for c in corners where !merged.contains(where: { hypot($0.x - c.x, $0.y - c.y) < epsilon }) { merged.append(c) }
        corners = merged
        // Drop corners on a straight run between their neighbours.
        var changed = true
        while changed, corners.count > 3 {
            changed = false
            for i in 0..<corners.count {
                let prev = corners[(i + corners.count - 1) % corners.count], next = corners[(i + 1) % corners.count]
                if InkGeometry.segmentDistance(corners[i], prev, next) < epsilon {
                    corners.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return corners
    }
}
