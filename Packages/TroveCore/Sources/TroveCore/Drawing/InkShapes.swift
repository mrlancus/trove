import Foundation

/// Turns a rough drawing into a clean shape (shape mode, or holding the pen still at the end of a
/// stroke): a line, a few joined lines, a triangle, a rectangle, another polygon, a circle or an
/// ellipse (PROTOCOL.md §10). Deterministic, so the website's `recognizeShape` (ink.js) gives the
/// same; both check Fixtures/ink-geometry.json.
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
            if deviation <= 0.08 * ends { return finish(.line, [first, last], pressure, duration) }
            let corners = simplify(raw, epsilon: 0.08 * diag)
            if corners.count <= 4 { return finish(.polyline, corners, pressure, duration) }
            return nil
        }

        // Closed: an ellipse if the points sit near one, else a polygon by its corners.
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        let rx = max(box.width / 2, 0.5), ry = max(box.height / 2, 0.5)
        let error = raw.map { abs(hypot(($0.x - cx) / rx, ($0.y - cy) / ry) - 1) }.reduce(0, +) / Double(raw.count)
        var corners = simplifyClosed(raw, epsilon: 0.1 * diag)
        // Whichever fits closer: the ellipse, or the polygon through the corners.
        let polygonFit = (3...8).contains(corners.count)
            ? raw.map { polygonDistance($0, corners) }.reduce(0, +) / Double(raw.count) / diag : Double.infinity
        let ellipseFit = error * (rx + ry) / 2 / diag
        if error < 0.16, ellipseFit <= polygonFit {
            let round = abs(rx - ry) <= 0.12 * max(rx, ry)
            let r = (rx + ry) / 2
            let points = (0...64).map { i -> InkPoint in
                let a = Double(i) / 64 * 2 * Double.pi
                return InkPoint(x: cx + (round ? r : rx) * cos(a), y: cy + (round ? r : ry) * sin(a))
            }
            return finish(round ? .circle : .ellipse, points, pressure, duration)
        }
        guard polygonFit < 0.05 else { return nil }
        switch corners.count {
        case 3:
            return finish(.triangle, corners + [corners[0]], pressure, duration)
        case 4:
            // Close to upright: snap to the box around the corners.
            if (0..<4).allSatisfy({ i in axisAligned(corners[i], corners[(i + 1) % 4]) }), let b = InkGeometry.bounds(corners) {
                corners = [InkPoint(x: b.x, y: b.y), InkPoint(x: b.maxX, y: b.y), InkPoint(x: b.maxX, y: b.maxY), InkPoint(x: b.x, y: b.maxY)]
            }
            return finish(.rectangle, corners + [corners[0]], pressure, duration)
        case 5...8:
            return finish(.polygon, corners + [corners[0]], pressure, duration)
        default:
            return nil
        }
    }

    /// Distance from p to the closed polygon's edges.
    static func polygonDistance(_ p: InkPoint, _ corners: [InkPoint]) -> Double {
        var best = Double.infinity
        for i in 0..<corners.count { best = min(best, InkGeometry.segmentDistance(p, corners[i], corners[(i + 1) % corners.count])) }
        return best
    }

    /// Within 12° of horizontal or vertical.
    static func axisAligned(_ a: InkPoint, _ b: InkPoint) -> Bool {
        let angle = abs(atan2(b.y - a.y, b.x - a.x)).truncatingRemainder(dividingBy: Double.pi / 2)
        let limit = 12 * Double.pi / 180
        return angle <= limit || angle >= Double.pi / 2 - limit
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
