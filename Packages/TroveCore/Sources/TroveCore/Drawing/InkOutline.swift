import Foundation

/// How strokes look and are captured (PROTOCOL.md §10), the same as web/public/core/ink.js; both
/// check Fixtures/ink-outline.json (made by web/test/make-outline-fixture.mjs).
/// - A pen stroke is one filled outline (`outline`), not many short segments.
/// - Line shapes can carry arrowheads; dashed lines have a fixed pattern.
public enum InkOutline {
    /// How far each point moves towards the pen (1 = raw), the closest two kept points get, and a half circle's steps.
    public static let streamline = 0.75, minGap = 0.2, capSteps = 8, minRadius = 0.15

    /// The width an even line is drawn at: markers and highlighters their width, the rest at their average pressure.
    public static func lineWidth(tool: InkTool, width: Double, points: [InkPoint]) -> Double {
        guard tool.usesPressure else { return width }
        let average = points.isEmpty ? 0.5 : points.map(\.pressure).reduce(0, +) / Double(points.count)
        return InkStroke.width(width, tool: tool, pressure: average)
    }

    /// A pen's width at its i-th point (ink.js `pointWidth`): fountain pens follow their direction
    /// and nib (the point's own angle, else the stroke's `nib`, else 45°), brushes taper at the ends.
    public static func pointWidth(tool: InkTool, width: Double, nib: Double?, points pts: [InkPoint], index i: Int) -> Double {
        let p = pts[i]
        switch tool {
        case .fountain:
            let q = pts[min(pts.count - 1, i + 1)], o = pts[max(0, i - 1)]
            let angle = p.angle ?? nib ?? InkGeometry.nibAngle
            return InkGeometry.fountainWidth(width, pressure: p.pressure, dx: q.x - o.x, dy: q.y - o.y, nib: angle)
        case .brush:
            return InkStroke.width(width, tool: tool, pressure: p.pressure) * InkGeometry.brushTaper(index: i, count: pts.count)
        default:
            return InkStroke.width(width, tool: tool, pressure: p.pressure)
        }
    }

    /// Dashes three widths long with two-width gaps; dots two widths apart (round caps make them round).
    public static func dashPattern(_ dash: String, width w: Double) -> [Double] {
        dash == "dot" ? [0.001, max(2 * w, 2)] : [max(3 * w, 3), max(2 * w, 2)]
    }

    /// One stroke as a filled outline (the perfect-freehand method; ink.js `strokeOutline`): the
    /// points streamlined a little (the last stays where the pen lifted), each with its width, the
    /// outline down the left side, round the end, back along the right side and round the start,
    /// with sharp turns rounded. Nil for strokes drawn as an even line (markers, highlighters,
    /// clean shapes, dashed lines). Draw it with quadratic curves through the corners' midpoints.
    public static func outline(tool: InkTool, width: Double, points raw: [InkPoint], shape: String? = nil, style: InkStrokeStyle = InkStrokeStyle()) -> [InkPoint]? {
        if shape != nil || style.dash != nil || !tool.usesPressure { return nil }
        // Points that aren't real numbers can't be drawn (and would stop the arcs below).
        let raw = raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) ? raw : raw.filter { $0.x.isFinite && $0.y.isFinite }
        guard let firstRaw = raw.first else { return [] }
        var pts: [InkPoint] = [firstRaw]
        for p in raw.dropFirst() {
            let last = pts[pts.count - 1]
            let x = last.x + (p.x - last.x) * streamline, y = last.y + (p.y - last.y) * streamline
            if hypot(x - last.x, y - last.y) < minGap { continue }
            pts.append(InkPoint(x: x, y: y, pressure: p.pressure, t: p.t, angle: p.angle))
        }
        // The line ends where the pen lifted.
        if raw.count > 1 {
            let end = raw[raw.count - 1], tail = pts[pts.count - 1]
            if hypot(end.x - tail.x, end.y - tail.y) >= minGap {
                pts.append(end)
            } else if pts.count > 1 {
                pts[pts.count - 1].x = end.x
                pts[pts.count - 1].y = end.y
            }
        }
        let n = pts.count
        var r: [Double] = []
        for i in 0..<n { r.append(max(minRadius, pointWidth(tool: tool, width: width, nib: style.nib, points: pts, index: i) / 2)) }
        if n == 1 {
            return (0..<(capSteps * 2)).map { k in
                let a = Double.pi * Double(k) / Double(capSteps)
                return InkPoint(x: pts[0].x + r[0] * cos(a), y: pts[0].y + r[0] * sin(a))
            }
        }
        var dirs: [(x: Double, y: Double)] = []
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y, len = hypot(dx, dy)
            if len > 0 { dirs.append((dx / len, dy / len)) } else { dirs.append(i > 0 ? dirs[i - 1] : (1, 0)) }
        }
        var left: [InkPoint] = [], right: [InkPoint] = []
        func arc(_ side: inout [InkPoint], _ c: InkPoint, _ radius: Double, _ from: Double, _ to: Double) {
            var delta = to - from
            if !delta.isFinite || !radius.isFinite { return }
            while delta > Double.pi { delta -= 2 * Double.pi }
            while delta <= -Double.pi { delta += 2 * Double.pi }
            let steps = max(1, Int((abs(delta) / (Double.pi / Double(capSteps))).rounded(.up)))
            for k in 0...steps {
                let a = from + delta * Double(k) / Double(steps)
                side.append(InkPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)))
            }
        }
        for i in 0..<n {
            let din = dirs[max(0, i - 1)], dout = dirs[min(n - 2, i)], p = pts[i]
            if i > 0, i < n - 1, din.x * dout.x + din.y * dout.y < 0 {
                // A sharp turn: round the corner on both sides.
                let a0 = atan2(din.y, din.x) + Double.pi / 2, a1 = atan2(dout.y, dout.x) + Double.pi / 2
                arc(&left, p, r[i], a0, a1)
                arc(&right, p, r[i], a0 + Double.pi, a1 + Double.pi)
                continue
            }
            var tx = din.x + dout.x, ty = din.y + dout.y, len = hypot(tx, ty)
            if len < 1e-9 { tx = dout.x; ty = dout.y; len = 1 }
            let nx = -ty / len, ny = tx / len
            left.append(InkPoint(x: p.x + nx * r[i], y: p.y + ny * r[i]))
            right.append(InkPoint(x: p.x - nx * r[i], y: p.y - ny * r[i]))
        }
        var out = left
        let e = dirs[n - 2], ae = atan2(e.y, e.x), last = pts[n - 1]
        for k in 1..<capSteps {
            let a = ae + Double.pi / 2 - Double.pi * Double(k) / Double(capSteps)
            out.append(InkPoint(x: last.x + r[n - 1] * cos(a), y: last.y + r[n - 1] * sin(a)))
        }
        out.append(contentsOf: right.reversed())
        let b = dirs[0], ab = atan2(b.y, b.x), first = pts[0]
        for k in 1..<capSteps {
            let a = ab - Double.pi / 2 - Double.pi * Double(k) / Double(capSteps)
            out.append(InkPoint(x: first.x + r[0] * cos(a), y: first.y + r[0] * sin(a)))
        }
        return out
    }

    /// Arrowheads on a `line` or `polyline` shape with `arrow`: triangles [tip, left, right].
    public static func arrowHeads(tool: InkTool, width: Double, points pts: [InkPoint], shape: String?, arrow: String?) -> [[InkPoint]] {
        guard let arrow, shape == "line" || shape == "polyline" || shape == "curve", pts.count >= 2 else { return [] }
        let w = lineWidth(tool: tool, width: width, points: pts), length = 4 * w + 6, half = length * 0.45
        func head(_ tip: InkPoint, _ from: InkPoint) -> [InkPoint]? {
            let dx = tip.x - from.x, dy = tip.y - from.y, d = hypot(dx, dy)
            guard d >= 1e-6 else { return nil }
            let ux = dx / d, uy = dy / d, bx = tip.x - ux * length, by = tip.y - uy * length
            return [InkPoint(x: tip.x, y: tip.y), InkPoint(x: bx - uy * half, y: by + ux * half), InkPoint(x: bx + uy * half, y: by - ux * half)]
        }
        var out: [[InkPoint]] = []
        if arrow == "end" || arrow == "both", let t = head(pts[pts.count - 1], pts[pts.count - 2]) { out.append(t) }
        if arrow == "start" || arrow == "both", let t = head(pts[0], pts[1]) { out.append(t) }
        return out
    }

    /// The line under arrowheads stops short of their tips, so its round end doesn't poke out.
    public static func trimmedForArrows(_ points: [InkPoint], width w: Double, arrow: String) -> [InkPoint] {
        var pts = points
        guard pts.count >= 2 else { return pts }
        let back = 2 * w + 3
        func pull(_ tip: Int, _ from: Int) {
            let dx = pts[tip].x - pts[from].x, dy = pts[tip].y - pts[from].y, d = hypot(dx, dy)
            guard d >= 1e-6 else { return }
            let k = min(back, d * 0.9) / d
            pts[tip].x -= dx * k
            pts[tip].y -= dy * k
        }
        if arrow == "end" || arrow == "both" { pull(pts.count - 1, pts.count - 2) }
        if arrow == "start" || arrow == "both" { pull(0, 1) }
        return pts
    }

    /// The box a stroke covers as drawn: its points, half its width out (more with arrowheads).
    public static func bounds(_ points: [InkPoint], width: Double, arrow: String? = nil) -> InkGeometry.Rect? {
        InkGeometry.bounds(points, pad: width / 2 + (arrow != nil ? 2 * width + 6 : 0) + 1)
    }

    /// The average nib angle of points that have one (a nib turned by π looks the same), in [0, π) (ink.js `meanNib`).
    public static func meanNib(_ points: [InkPoint]) -> Double? {
        var sx = 0.0, sy = 0.0, n = 0
        for p in points { if let a = p.angle, a.isFinite { sx += cos(2 * a); sy += sin(2 * a); n += 1 } }
        guard n > 0 else { return nil }
        let a = atan2(sy, sx) / 2
        return a < 0 ? a + Double.pi : a
    }

    // MARK: Pencil grain

    public static let grainSize = 64, grainTexel = 0.5

    private static func grainHash(_ x: Int, _ y: Int, _ seed: UInt32) -> Int {
        var h = (UInt32(truncatingIfNeeded: x) &* 0x27d4eb2d) ^ (UInt32(truncatingIfNeeded: y) &* 0x165667b1) ^ seed
        h = (h ^ (h >> 15)) &* 0x85ebca6b
        h = (h ^ (h >> 13)) &* 0xc2b2ae35
        h ^= h >> 16
        return Int(h & 255)
    }

    /// The pencil's grain (ink.js `grainTile`): 64 × 64 alpha values (150–255) that repeat
    /// seamlessly, fine noise mixed with 2 × 2 specks, a texel every half page point.
    public static let grainTile: [UInt8] = {
        var out = [UInt8](repeating: 0, count: grainSize * grainSize)
        for y in 0..<grainSize {
            for x in 0..<grainSize {
                let n1: Int = grainHash(x, y, 1), n2: Int = grainHash(x >> 1, y >> 1, 2)
                // Split up: as one expression it's too slow for the compiler to type-check.
                let mix: Int = 6 * n1 + 4 * n2
                let level: Int = 150 + mix * 105 / 2550
                out[y * grainSize + x] = UInt8(level)
            }
        }
        return out
    }()
}

// MARK: - Pen settings (settings.ink)

/// A pen's capture settings: the stabiliser (0 = raw, 100 = steadiest), the pressure curve and a
/// minimum pressure, so the lightest touch is never thinner than that.
public struct PenSettings: Sendable, Equatable {
    public enum Curve: String, CaseIterable, Sendable { case soft, normal, firm }
    public var smoothing: Int
    public var curve: Curve
    public var minWidth: Int

    public init(smoothing: Int = 0, curve: Curve = .normal, minWidth: Int = 0) {
        self.smoothing = min(100, max(0, smoothing)); self.curve = curve; self.minWidth = min(100, max(0, minWidth))
    }

    init(json: JSONValue?) {
        let o = json?.object ?? [:]
        func clamp(_ v: JSONValue?) -> Int {
            guard let n = v?.number, n.isFinite else { return 0 }
            return Int(min(100, max(0, (n + 0.5).rounded(.down))))
        }
        self.init(smoothing: clamp(o["smoothing"]), curve: o["curve"]?.string.flatMap(Curve.init(rawValue:)) ?? .normal, minWidth: clamp(o["minWidth"]))
    }

    public var json: JSONValue {
        .object(["smoothing": .number(Double(smoothing)), "curve": .string(curve.rawValue), "minWidth": .number(Double(minWidth))])
    }

    /// Pressure after the curve and minimum: m + (1 − m) · curve(p), soft p^0.6, firm p^1.6.
    public func pressure(_ pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        let c: Double
        switch curve {
        case .soft: c = pow(p, 0.6)
        case .normal: c = p
        case .firm: c = pow(p, 1.6)
        }
        let m = Double(minWidth) / 100
        return m + (1 - m) * c
    }
}

/// A pen's settings applied while points are captured (ink.js `PenFilter`), so the stored stroke
/// is what was shown: each point moves k = 1 − 0.9 · smoothing/100 of the way from the last one to
/// the pen, and when the pen lifts the line ends where it is.
public struct PenFilter: Sendable {
    public let settings: PenSettings
    private let k: Double
    private var last: InkPoint?

    public init(_ settings: PenSettings) {
        self.settings = settings
        k = 1 - 0.9 * Double(settings.smoothing) / 100
    }

    public mutating func add(_ p: InkPoint) -> InkPoint {
        var q = InkPoint(x: p.x, y: p.y, pressure: settings.pressure(p.pressure), t: p.t, angle: p.angle)
        if let last {
            q.x = last.x + (p.x - last.x) * k
            q.y = last.y + (p.y - last.y) * k
        }
        last = q
        return q
    }

    /// Where the pen lifted, when smoothing left the line short of it.
    public func end(_ p: InkPoint) -> InkPoint? {
        guard let last, settings.smoothing > 0, hypot(p.x - last.x, p.y - last.y) >= 0.5 else { return nil }
        return InkPoint(x: p.x, y: p.y, pressure: settings.pressure(p.pressure), t: p.t, angle: p.angle)
    }

    public static func apply(_ raw: [InkPoint], _ settings: PenSettings) -> [InkPoint] {
        var f = PenFilter(settings)
        var out = raw.map { f.add($0) }
        if raw.count > 1, let e = f.end(raw[raw.count - 1]) { out.append(e) }
        return out
    }
}

/// A favourite pen: one tap brings back its tool, colour and size.
public struct InkFavourite: Sendable, Equatable, Hashable {
    public var tool: InkTool
    public var color: String
    public var width: Double
    public init(tool: InkTool, color: String, width: Double) { self.tool = tool; self.color = color.lowercased(); self.width = width }
    public var json: JSONValue { .object(["tool": .string(tool.rawValue), "color": .string(color), "width": .number(width)]) }
}

/// The drawing settings every device follows: the `settings.ink` record (PROTOCOL.md §10).
public struct InkSettings: Sendable, Equatable {
    public static let id = "settings.ink"
    public static let maxFavourites = 10, maxPalette = 24

    public var pens: [InkTool: PenSettings] = [:]
    public var favourites: [InkFavourite] = []
    public var palette: [String] = []
    /// Write `points2` instead of `points` (only once every device reads them).
    public var compactPoints = false

    public init() {}

    public init(fields: [String: JSONValue]) {
        for t in InkTool.allCases { pens[t] = PenSettings(json: fields["pen.\(t.rawValue)"]) }
        favourites = (fields["favourites"]?.array ?? []).compactMap { v -> InkFavourite? in
            guard let o = v.object, let tool = o["tool"]?.string.flatMap(InkTool.init(rawValue:)), let color = o["color"]?.string, Self.isHex(color),
                  let width = o["width"]?.number, width > 0, width <= 200 else { return nil }
            return InkFavourite(tool: tool, color: color, width: width)
        }.prefix(Self.maxFavourites).map { $0 }
        palette = (fields["palette"]?.array ?? []).compactMap(\.string).filter(Self.isHex).map { $0.lowercased() }.prefix(Self.maxPalette).map { $0 }
        compactPoints = fields["compactPoints"]?.bool == true
    }

    public func pen(_ tool: InkTool) -> PenSettings { pens[tool] ?? PenSettings() }

    public static func isHex(_ s: String) -> Bool {
        s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy { $0.isHexDigit }
    }
}

extension Library {
    /// The drawing settings every device follows.
    public func inkSettings() async -> InkSettings {
        guard let r = await engine.record(InkSettings.id), !r.isDeleted else { return InkSettings() }
        return InkSettings(fields: r.fields)
    }

    public func setPenSettings(_ tool: InkTool, _ settings: PenSettings) async {
        await engine.set(["pen.\(tool.rawValue)": settings.json], record: InkSettings.id, kind: "setting")
    }

    public func setInkFavourites(_ list: [InkFavourite]) async {
        await engine.set(["favourites": .array(list.prefix(InkSettings.maxFavourites).map(\.json))], record: InkSettings.id, kind: "setting")
    }

    public func setInkPalette(_ colors: [String]) async {
        let clean = colors.filter(InkSettings.isHex).map { $0.lowercased() }.prefix(InkSettings.maxPalette)
        await engine.set(["palette": .array(clean.map(JSONValue.string))], record: InkSettings.id, kind: "setting")
    }

    /// Write `points2` (4× smaller): turn on once every device has a Trove that reads them.
    public func setCompactPoints(_ on: Bool) async {
        await engine.set(["compactPoints": .bool(on)], record: InkSettings.id, kind: "setting")
    }
}

// MARK: - The page grid

/// Boxes in a grid of 256-point cells (ink.js `InkGrid`), so the eraser, lasso and scribble-to-erase
/// test only nearby strokes instead of every stroke on the page.
public struct InkGrid: Sendable {
    private struct Cell: Hashable { var i: Int; var j: Int }
    public let cell: Double
    private var cells: [Cell: Set<String>] = [:]
    private var boxes: [String: InkGeometry.Rect] = [:]
    private var big: Set<String> = []

    public init(cell: Double = 256) { self.cell = cell }

    private func span(_ r: InkGeometry.Rect) -> (Int, Int, Int, Int) {
        func f(_ v: Double) -> Int { Int(max(-1e9, min(1e9, (v / cell).rounded(.down)))) }
        return (f(r.x), f(r.y), f(r.x + r.width), f(r.y + r.height))
    }

    public mutating func add(_ id: String, _ r: InkGeometry.Rect?) {
        remove(id)
        guard let r, r.x.isFinite, r.y.isFinite, r.width.isFinite, r.height.isFinite, r.width >= 0, r.height >= 0 else { return }
        boxes[id] = r
        let (i0, j0, i1, j1) = span(r)
        // Huge strokes (a whiteboard's frame) go in one list every query looks at.
        if (i1 - i0 + 1) * (j1 - j0 + 1) > 64 { big.insert(id); return }
        for i in i0...i1 { for j in j0...j1 { cells[Cell(i: i, j: j), default: []].insert(id) } }
    }

    public mutating func remove(_ id: String) {
        guard let r = boxes.removeValue(forKey: id) else { return }
        if big.remove(id) != nil { return }
        let (i0, j0, i1, j1) = span(r)
        for i in i0...i1 { for j in j0...j1 { cells[Cell(i: i, j: j)]?.remove(id) } }
    }

    public var count: Int { boxes.count }

    /// Ids whose box touches `r`, sorted.
    public func query(_ r: InkGeometry.Rect) -> [String] {
        var out: Set<String> = []
        func hit(_ id: String) {
            guard let b = boxes[id] else { return }
            if b.x <= r.maxX, r.x <= b.maxX, b.y <= r.maxY, r.y <= b.maxY { out.insert(id) }
        }
        for id in big { hit(id) }
        let (i0, j0, i1, j1) = span(r)
        if (i1 - i0 + 1) * (j1 - j0 + 1) > 4096 {
            for id in boxes.keys { hit(id) }
        } else {
            for i in i0...i1 { for j in j0...j1 { for id in cells[Cell(i: i, j: j)] ?? [] { hit(id) } } }
        }
        return out.sorted()
    }
}
