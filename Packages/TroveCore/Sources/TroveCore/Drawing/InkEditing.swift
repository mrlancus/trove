import Foundation

/// Editing ink faster (ROADMAP S3, PROTOCOL.md §10): turning and flipping elements, shapes from the
/// shape picker with handles you can drag, connectors that follow the shapes they join, the ruler
/// and protractor, straightening and groups. Plain functions on page points, the same as
/// web/public/core/inkedit.js; both check Fixtures/ink-editing.json (made by
/// web/test/make-editing-fixture.mjs).
public enum InkEditing {
    /// Rounds half up, like JavaScript's Math.round (−2.5 → −2), so both sides snap the same way.
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// An angle in (−π, π], with tiny values made 0.
    public static func normalAngle(_ a: Double) -> Double {
        let tau = 2 * Double.pi
        var out = a.truncatingRemainder(dividingBy: tau)
        if out > Double.pi { out -= tau }
        if out <= -Double.pi { out += tau }
        return abs(out) < 1e-9 ? 0 : out
    }

    // MARK: Elements: turning and flipping

    /// An element's box as stored, its turn (radians, clockwise about its centre) and, for a picture, whether it's mirrored.
    public struct Frame: Equatable, Sendable {
        public var x, y, w, h: Double
        public var rotate: Double
        public var flip: Bool
        public init(x: Double, y: Double, w: Double, h: Double, rotate: Double = 0, flip: Bool = false) {
            self.x = x; self.y = y; self.w = w; self.h = h; self.rotate = rotate; self.flip = flip
        }
        public init(_ rect: InkGeometry.Rect, rotate: Double = 0, flip: Bool = false) {
            self.init(x: rect.x, y: rect.y, w: rect.width, h: rect.height, rotate: rotate, flip: flip)
        }
        public var rect: InkGeometry.Rect { InkGeometry.Rect(x: x, y: y, width: w, height: h) }
        public var centre: InkPoint { InkPoint(x: x + w / 2, y: y + h / 2) }
    }

    /// The four corners of an element as drawn (turned about its centre).
    public static func corners(_ e: Frame) -> [InkPoint] {
        let cx = e.x + e.w / 2, cy = e.y + e.h / 2, c = cos(e.rotate), s = sin(e.rotate)
        let units: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return units.map { (u: Double, v: Double) -> InkPoint in
            let x = u * e.w / 2, y = v * e.h / 2
            return InkPoint(x: cx + c * x - s * y, y: cy + s * x + c * y)
        }
    }

    /// The box around an element as drawn.
    public static func bounds(_ e: Frame) -> InkGeometry.Rect {
        guard e.rotate != 0, e.rotate.isFinite else { return e.rect }
        return InkGeometry.bounds(corners(e)) ?? e.rect
    }

    /// A page point in the element's own (unturned) box, so hit tests can use x, y, w, h.
    public static func toElementSpace(_ e: Frame, _ p: InkPoint) -> InkPoint {
        guard e.rotate != 0 else { return InkPoint(x: p.x, y: p.y) }
        let cx = e.x + e.w / 2, cy = e.y + e.h / 2, c = cos(-e.rotate), s = sin(-e.rotate)
        let x = p.x - cx, y = p.y - cy
        return InkPoint(x: cx + c * x - s * y, y: cy + s * x + c * y)
    }

    /// True if a page point is on the element (its turned box). `height` overrides its height (a text box's wrapped lines).
    public static func contains(_ e: Frame, _ p: InkPoint, height: Double? = nil) -> Bool {
        var f = e
        if let height { f.h = height }
        let q = toElementSpace(f, p)
        return q.x >= f.x && q.x <= f.x + f.w && q.y >= f.y && q.y <= f.y + f.h
    }

    /// An element after a lasso transform: its centre moves like a point, its size scales by |sx|,
    /// |sy|, and it turns with `r`. A mirror turns it the other way; a picture (`image`) is mirrored
    /// too (`flip`), and flipped upside down it turns half round as well. Text and tape stay readable.
    public static func transform(_ t: InkGeometry.Transform, _ e: Frame, image: Bool) -> Frame {
        let c = t.apply(InkPoint(x: e.x + e.w / 2, y: e.y + e.h / 2))
        let w = e.w * abs(t.sx), h = e.h * abs(t.sy)
        let mirror = (t.sx < 0) != (t.sy < 0), both = t.sx < 0 && t.sy < 0
        var rotate = mirror ? -e.rotate : e.rotate
        if both { rotate += Double.pi }
        if mirror && image && t.sy < 0 { rotate += Double.pi }
        rotate = normalAngle(rotate + t.r)
        return Frame(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rotate: rotate, flip: image && mirror ? !e.flip : e.flip)
    }

    /// Turning by `r` about (ox, oy).
    public static func rotate(_ r: Double, about o: InkPoint) -> InkGeometry.Transform { InkGeometry.Transform(ox: o.x, oy: o.y, r: r) }
    /// Flipping left to right (`horizontal`) or upside down about a point.
    public static func flip(horizontal: Bool, about o: InkPoint) -> InkGeometry.Transform {
        InkGeometry.Transform(sx: horizontal ? -1 : 1, sy: horizontal ? 1 : -1, ox: o.x, oy: o.y)
    }

    /// A turn snapped to the nearest 15° when within 3° of it (the rotate handle).
    public static func snapRotation(_ r: Double) -> Double {
        let step = Double.pi / 12, near = jsRound(r / step) * step
        return abs(r - near) <= 3 * Double.pi / 180 ? normalAngle(near) : normalAngle(r)
    }

    // MARK: Shapes from the picker

    /// The shapes the picker draws (an arrow is a `line` with `arrow`).
    public static let pickerShapes = ["line", "rectangle", "ellipse", "circle", "triangle", "diamond", "star", "heart", "bubble"]
    public static let curveSteps = 32

    private static func pt(_ x: Double, _ y: Double) -> InkPoint { InkPoint(x: x, y: y, pressure: 0.5, t: 0) }

    /// Points scaled so their box is exactly `box`.
    private static func fit(_ points: [InkPoint], _ box: InkGeometry.Rect) -> [InkPoint] {
        guard let b = InkGeometry.bounds(points) else { return [] }
        let kx = b.width != 0 ? box.width / b.width : 0, ky = b.height != 0 ? box.height / b.height : 0
        return points.map { pt(box.x + ($0.x - b.x) * kx, box.y + ($0.y - b.y) * ky) }
    }

    private static func closeLoop(_ pts: [InkPoint]) -> [InkPoint] {
        guard let first = pts.first else { return pts }
        return pts + [first]
    }

    /// A clean shape filling the box dragged from `a` to `b` (page points), as stroke points
    /// (pressure 0.5, time 0). Closed shapes end where they start; `line` runs from a to b. Nil for
    /// a name it doesn't know.
    public static func shapePoints(_ shape: String, from a: InkPoint, to b: InkPoint) -> [InkPoint]? {
        let x = min(a.x, b.x), y = min(a.y, b.y), w = abs(b.x - a.x), h = abs(b.y - a.y)
        let box = InkGeometry.Rect(x: x, y: y, width: w, height: h)
        switch shape {
        case "line":
            return [pt(a.x, a.y), pt(b.x, b.y)]
        case "rectangle":
            return closeLoop([pt(x, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)])
        case "triangle":
            return closeLoop([pt(x + w / 2, y), pt(x + w, y + h), pt(x, y + h)])
        case "diamond":
            return closeLoop([pt(x + w / 2, y), pt(x + w, y + h / 2), pt(x + w / 2, y + h), pt(x, y + h / 2)])
        case "circle", "ellipse":
            let r = min(w, h) / 2, cx = x + w / 2, cy = y + h / 2
            let rx = shape == "circle" ? r : w / 2, ry = shape == "circle" ? r : h / 2
            return (0...64).map { (i: Int) -> InkPoint in
                let t = Double(i) / 64 * 2 * Double.pi
                return pt(cx + rx * cos(t), cy + ry * sin(t))
            }
        case "star":
            let raw = (0..<10).map { (i: Int) -> InkPoint in
                let r = i % 2 == 1 ? 0.382 : 1
                let t = -Double.pi / 2 + Double(i) * Double.pi / 5
                return pt(r * cos(t), r * sin(t))
            }
            return closeLoop(fit(raw, box))
        case "heart":
            let raw = (0..<48).map { (i: Int) -> InkPoint in
                let t = Double(i) / 48 * 2 * Double.pi
                let s = sin(t)
                let hx = 16 * pow(s, 3)
                let hy = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
                return pt(hx, hy)
            }
            return closeLoop(fit(raw, box))
        case "bubble":
            // A rounded box over the top 80 %, with a tail down to the left.
            let by = y + h * 0.8, r = min(w, h * 0.8) * 0.15
            func corner(_ cx: Double, _ cy: Double, _ from: Double) -> [InkPoint] {
                (0..<5).map { (i: Int) -> InkPoint in
                    let t = from + Double(i) / 4 * (Double.pi / 2)
                    return pt(cx + r * cos(t), cy + r * sin(t))
                }
            }
            var pts: [InkPoint] = []
            pts += corner(x + w - r, y + r, -Double.pi / 2)
            pts += corner(x + w - r, by - r, 0)
            pts += [pt(x + w * 0.4, by), pt(x + w * 0.15, y + h), pt(x + w * 0.25, by)]
            pts += corner(x + r, by - r, Double.pi / 2)
            pts += corner(x + r, y + r, Double.pi)
            return closeLoop(pts)
        default:
            return nil
        }
    }

    /// A quadratic curve from a to b bent towards c, as `curveSteps` + 1 points.
    public static func curvePoints(_ a: InkPoint, _ c: InkPoint, _ b: InkPoint, pressure: Double = 0.5) -> [InkPoint] {
        (0...curveSteps).map { (i: Int) -> InkPoint in
            let t = Double(i) / Double(curveSteps), u = 1 - t
            let x = u * u * a.x + 2 * u * t * c.x + t * t * b.x
            let y = u * u * a.y + 2 * u * t * c.y + t * t * b.y
            return InkPoint(x: x, y: y, pressure: pressure, t: 0)
        }
    }

    private static func isClosed(_ pts: [InkPoint]) -> Bool {
        guard pts.count > 2, let first = pts.first, let last = pts.last else { return false }
        return hypot(first.x - last.x, first.y - last.y) < 1e-6
    }

    /// Shapes whose corners can be dragged one by one.
    public static let cornered: Set<String> = ["polyline", "triangle", "rectangle", "polygon", "diamond"]

    /// The handles a clean shape shows when it's selected on its own: a line's ends and its middle
    /// (drag it to bend the line), a curve's ends and its middle point, a polyline's or polygon's
    /// corners. Others resize and turn with the box.
    public static func shapeHandles(shape: String?, points pts: [InkPoint]) -> [InkPoint] {
        guard let shape, let first = pts.first, let last = pts.last else { return [] }
        if shape == "line", pts.count >= 2 {
            return [pt(first.x, first.y), pt(last.x, last.y), pt((first.x + last.x) / 2, (first.y + last.y) / 2)]
        }
        if shape == "curve", pts.count >= 3 {
            let m = pts[pts.count / 2]
            return [pt(first.x, first.y), pt(last.x, last.y), pt(m.x, m.y)]
        }
        if cornered.contains(shape) {
            let corners = isClosed(pts) ? Array(pts.dropLast()) : pts
            return corners.map { pt($0.x, $0.y) }
        }
        return []
    }

    /// The shape with handle `index` dragged to `to`. A line's middle handle bends it into a
    /// `curve` through `to`; a moved rectangle corner makes it a `polygon`.
    public static func moveShapeHandle(shape: String?, points pts: [InkPoint], index: Int, to: InkPoint) -> (shape: String?, points: [InkPoint]) {
        let p = pts.first?.pressure ?? 0.5
        if shape == "line" || shape == "curve" {
            let hs = shapeHandles(shape: shape, points: pts)
            guard hs.count == 3, let first = pts.first, let last = pts.last else { return (shape, pts) }
            let a = hs[0], b = hs[1], m = hs[2]
            if index == 2 {
                let c = InkPoint(x: 2 * to.x - (a.x + b.x) / 2, y: 2 * to.y - (a.y + b.y) / 2)
                return ("curve", curvePoints(a, c, b, pressure: p))
            }
            let a2 = index == 0 ? to : a, b2 = index == 1 ? to : b
            if shape == "line" {
                var s = first, e = last
                s.x = a2.x; s.y = a2.y; e.x = b2.x; e.y = b2.y
                return ("line", [s, e])
            }
            let c = InkPoint(x: 2 * m.x - (a.x + b.x) / 2, y: 2 * m.y - (a.y + b.y) / 2)
            return ("curve", curvePoints(a2, c, b2, pressure: p))
        }
        guard let shape, cornered.contains(shape), index >= 0, index < pts.count else { return (shape, pts) }
        let closed = isClosed(pts)
        var out = pts
        out[index].x = to.x
        out[index].y = to.y
        if closed && index == 0 { out[out.count - 1] = out[0] }
        return (shape == "rectangle" ? "polygon" : shape, out)
    }

    // MARK: Connectors

    public static let connectorGap = 4.0

    /// Closed shapes (not connectors themselves) can be joined by a connector; so can any element.
    public static func connectable(shape: String?, from: String?, to: String?) -> Bool {
        guard let shape, InkStrokeStyle.closedShapes.contains(shape) else { return false }
        return (from ?? "").isEmpty && (to ?? "").isEmpty
    }

    /// Where a line from the box's centre towards `toward` leaves the box, `gap` further out; the centre if `toward` is inside.
    public static func boxExit(_ box: InkGeometry.Rect, toward: InkPoint, gap: Double = connectorGap) -> InkPoint {
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2, dx = toward.x - cx, dy = toward.y - cy
        if dx == 0 && dy == 0 { return InkPoint(x: cx, y: cy) }
        let kx = dx != 0 ? box.width / 2 / abs(dx) : Double.infinity
        let ky = dy != 0 ? box.height / 2 / abs(dy) : Double.infinity
        let k = min(kx, ky)
        if k >= 1 { return InkPoint(x: cx, y: cy) }
        let d = hypot(dx, dy), g = min(gap / d, 1 - k)
        return InkPoint(x: cx + dx * (k + g), y: cy + dy * (k + g))
    }

    /// A connector's ends: an end joined to a box sits where the line between the anchors (a joined
    /// end's box centre, or the free end) leaves that box; a free end stays at `a` or `b`.
    public static func connectorEnds(_ a: InkPoint, _ b: InkPoint, from fromBox: InkGeometry.Rect?, to toBox: InkGeometry.Rect?) -> (InkPoint, InkPoint) {
        let ca = fromBox.map { InkPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) } ?? a
        let cb = toBox.map { InkPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) } ?? b
        let start = fromBox.map { boxExit($0, toward: cb) } ?? InkPoint(x: a.x, y: a.y)
        let end = toBox.map { boxExit($0, toward: ca) } ?? InkPoint(x: b.x, y: b.y)
        return (start, end)
    }

    // MARK: Ruler and protractor (on this device only)

    public static let rulerLength = 720.0, rulerWidth = 64.0, protractorRadius = 160.0

    /// A ruler or protractor: its centre (the protractor's is the middle of its base line) and angle.
    public struct Guide: Equatable, Sendable {
        public var x, y, angle: Double
        public var length: Double, width: Double, radius: Double
        public init(x: Double, y: Double, angle: Double, length: Double = rulerLength, width: Double = rulerWidth, radius: Double = protractorRadius) {
            self.x = x; self.y = y; self.angle = angle; self.length = length; self.width = width; self.radius = radius
        }
        public var centre: InkPoint { InkPoint(x: x, y: y) }

        /// A point in the guide's frame: u along it from its centre, v across it (positive below when level).
        public func local(_ p: InkPoint) -> (u: Double, v: Double) {
            let c = cos(angle), s = sin(angle), dx = p.x - x, dy = p.y - y
            return (dx * c + dy * s, -dx * s + dy * c)
        }

        public func world(_ u: Double, _ v: Double) -> InkPoint {
            let c = cos(angle), s = sin(angle)
            return InkPoint(x: x + u * c - v * s, y: y + u * s + v * c)
        }
    }

    /// The ruler's edge a point is within `tolerance` of: −1 (top), 1 (bottom) or 0 (neither).
    public static func rulerEdge(_ ruler: Guide, _ p: InkPoint, tolerance: Double) -> Int {
        let (u, v) = ruler.local(p), half = ruler.length / 2, w = ruler.width / 2
        if abs(u) > half + tolerance { return 0 }
        let top = abs(v + w), bottom = abs(v - w)
        if min(top, bottom) > tolerance { return 0 }
        return top <= bottom ? -1 : 1
    }

    /// A point moved onto a ruler edge (−1 top, 1 bottom), pressure and time kept.
    public static func onRulerEdge(_ ruler: Guide, edge: Int, _ p: InkPoint) -> InkPoint {
        let u = ruler.local(p).u
        let q = ruler.world(u, Double(edge) * ruler.width / 2)
        var out = p
        out.x = q.x; out.y = q.y
        return out
    }

    /// True if a point is on the ruler's body (where dragging moves it).
    public static func onRuler(_ ruler: Guide, _ p: InkPoint) -> Bool {
        let (u, v) = ruler.local(p)
        return abs(u) <= ruler.length / 2 && abs(v) <= ruler.width / 2
    }

    /// The angle shown on a guide, in degrees from 0 to 180, counter-clockwise from level.
    public static func degrees(_ angle: Double) -> Double {
        let d = (-angle * 180 / Double.pi).truncatingRemainder(dividingBy: 180)
        let out = d < 0 ? d + 180 : d
        return out >= 180 - 1e-9 || out == 0 ? 0 : out
    }

    /// True if a point is within `tolerance` of the protractor's arc (the half above its base line).
    public static func onProtractorArc(_ pro: Guide, _ p: InkPoint, tolerance: Double) -> Bool {
        let (u, v) = pro.local(p)
        return v <= tolerance && abs(hypot(u, v) - pro.radius) <= tolerance
    }

    /// A point moved onto the protractor's arc (below the base line: the nearer end).
    public static func onArc(_ pro: Guide, _ p: InkPoint) -> InkPoint {
        let (u, v) = pro.local(p)
        let a = v <= 0 ? atan2(v, u) : (u >= 0 ? 0 : -Double.pi)
        let q = pro.world(pro.radius * cos(a), pro.radius * sin(a))
        var out = p
        out.x = q.x; out.y = q.y
        return out
    }

    /// The angle of a point seen from the protractor's centre, 0 to 180 degrees from its base line.
    public static func protractorDegrees(_ pro: Guide, _ p: InkPoint) -> Double {
        let (u, v) = pro.local(p)
        let d = atan2(-v, u) * 180 / Double.pi
        return max(0, min(180, d))
    }

    // MARK: Straighten

    /// The turn (radians) that levels ink written on a slant: the main direction of the points
    /// (their principal axis) brought to the nearest of level or upright.
    public static func straightenAngle(_ points: [InkPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var mx = 0.0, my = 0.0
        for p in points { mx += p.x; my += p.y }
        mx /= Double(points.count); my /= Double(points.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        if sxx + syy < 1e-9 { return 0 }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let quarter = Double.pi / 2
        var off = theta - jsRound(theta / quarter) * quarter
        if abs(off) < 1e-9 { off = 0 }
        return off == 0 ? 0 : -off
    }

    // MARK: Groups

    /// The ids picked plus every other member of their groups. `all` is every (id, group) on the page.
    public static func withGroups(_ ids: [String], all: [(id: String, group: String)]) -> [String] {
        var picked: [String] = []
        var seen: Set<String> = []
        for id in ids where !seen.contains(id) { picked.append(id); seen.insert(id) }
        var groups: Set<String> = []
        for x in all where seen.contains(x.id) && !x.group.isEmpty { groups.insert(x.group) }
        for x in all where !x.group.isEmpty && groups.contains(x.group) && !seen.contains(x.id) {
            picked.append(x.id)
            seen.insert(x.id)
        }
        return picked
    }
}
