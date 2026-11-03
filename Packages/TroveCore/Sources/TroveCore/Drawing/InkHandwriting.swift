import Foundation

/// Text as real handwritten strokes (docs/plans/sketch-2-plan.md A1): what Math Assist and the AI
/// write on a page. On the device, no AI tokens: the AI sends words, this makes the ink.
///
/// - Glyphs: single-line fonts (`InkGlyphData`, from the EMS fonts under the SIL Open Font
///   License): `neat` is EMS Tech (from Architects Daughter, a handwritten print), `script` is EMS
///   Allure (from Allura).
/// - Humaniser, seeded (every device makes the same strokes): each letter's size, slant and spacing
///   vary a little, the baseline wanders, the pen wobbles slowly, pressure swells and tapers, and
///   timing follows a writing speed (so replay looks written).
/// - Size: `sizeNear` matches the writing around where it goes.
public enum InkHandwriting {
    public enum Style: String, CaseIterable, Sendable {
        case neat, script
        var key: String { self == .neat ? "tech" : "script" }
    }

    struct Glyph {
        var advance: Double
        var strokes: [[(Double, Double)]]
    }

    struct Font {
        var xHeight: Double
        var glyphs: [Character: Glyph]
        /// The median height of a stroke in ordinary text, per unit of x-height (for `sizeNear`).
        var strokeHeightPerX: Double = 1.6
    }

    private static let fonts: [String: Font] = {
        guard let data = InkGlyphData.json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Font] = [:]
        for (key, value) in root {
            guard let f = value as? [String: Any], let glyphs = f["glyphs"] as? [String: Any] else { continue }
            var font = Font(xHeight: (f["xHeight"] as? Double) ?? 300, glyphs: [:])
            for (ch, g) in glyphs {
                guard let c = ch.first, let o = g as? [String: Any] else { continue }
                let adv = (o["a"] as? Double) ?? Double((o["a"] as? Int) ?? 300)
                let strokes = ((o["s"] as? [[Any]]) ?? []).map { flat -> [(Double, Double)] in
                    let nums = flat.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
                    return stride(from: 0, to: nums.count - 1, by: 2).map { (nums[$0], nums[$0 + 1]) }
                }
                font.glyphs[c] = Glyph(advance: adv, strokes: strokes)
            }
            // The declared x-height isn't what the letters are: measure a real x.
            if let x = font.glyphs["x"] {
                let ys = x.strokes.flatMap { $0.map(\.1) }
                if let lo = ys.min(), let hi = ys.max(), hi - lo > 1 { font.xHeight = hi - lo }
            }
            out[key] = font
        }
        for key in Array(out.keys) {
            if let k = calibrate(key, out[key]!) { out[key]!.strokeHeightPerX = k }
        }
        return out
    }()

    /// Lays out a sample at x-height 1 and takes its strokes' median height.
    private static func calibrate(_ key: String, _ font: Font) -> Double? {
        var heights: [Double] = []
        for ch in "the quick brown fox jumps over the lazy dog 2468" {
            guard let g = font.glyphs[ch] else { continue }
            for s in g.strokes where s.count > 1 {
                let ys = s.map(\.1)
                heights.append(((ys.max() ?? 0) - (ys.min() ?? 0)) / font.xHeight)
            }
        }
        heights.sort()
        return heights.isEmpty ? nil : max(0.3, heights[heights.count / 2])
    }

    public struct Options: Sendable {
        public var style: Style = .neat
        /// The height of a lowercase x, in page points.
        public var xHeight: Double = 7
        /// Lines this far apart (page points); nil: 2.6 × x-height (or the ruling, when set).
        public var lineSpacing: Double?
        /// Wrap at this width (page points); nil: one line per paragraph.
        public var maxWidth: Double?
        /// Extra slant, radians (positive leans right), on top of the style's own.
        public var slant: Double = 0
        public var seed: UInt64 = 1
        /// How much the humaniser varies things (0 = the plain font, 1 = normal).
        public var variation: Double = 1
        public init() {}
    }

    public struct Result: Sendable {
        /// Each stroke's points (page points, with pressure and time).
        public var strokes: [[InkPoint]]
        /// The box round everything written.
        public var bounds: InkGeometry.Rect?
        /// How many lines it took.
        public var lines: Int
    }

    /// The width `text` takes on one line (no wrapping, no variation), for fitting.
    public static func width(_ text: String, options: Options) -> Double {
        guard let font = fonts[options.style.key] else { return 0 }
        let s = options.xHeight / font.xHeight
        return text.reduce(0) { $0 + (font.glyphs[$1]?.advance ?? font.xHeight) * s }
    }

    /// Writes `text` with its first baseline starting at `origin`.
    public static func write(_ text: String, at origin: InkPoint, options o: Options) -> Result {
        guard let font = fonts[o.style.key] else { return Result(strokes: [], bounds: nil, lines: 0) }
        var r = InkStress.Random(seed: o.seed ^ UInt64(truncatingIfNeeded: text.stableHash))
        let v = max(0, o.variation)
        let s = o.xHeight / font.xHeight
        let spacing = o.lineSpacing ?? o.xHeight * 2.6
        let space = (font.glyphs[" "]?.advance ?? font.xHeight) * s
        // Words, wrapped by width.
        var lines: [[String]] = []
        for para in text.components(separatedBy: "\n") {
            var line: [String] = []
            var used = 0.0
            for word in para.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let w = width(word, options: o)
                if let max = o.maxWidth, !line.isEmpty, used + space + w > max {
                    lines.append(line)
                    line = []
                    used = 0
                }
                used += (line.isEmpty ? 0 : space) + w
                line.append(word)
            }
            lines.append(line)
        }
        var strokes: [[InkPoint]] = []
        var t = 0.0
        let baseSlant = o.slant + (o.style == .neat ? 0.03 : 0)
        for (li, words) in lines.enumerated() {
            var x = origin.x
            let baseline = origin.y + Double(li) * spacing
            var drift = 0.0
            for (wi, word) in words.enumerated() {
                if wi > 0 { x += space * (1 + r.range(-0.15, 0.15) * v) }
                for ch in word {
                    guard let g = font.glyphs[ch] ?? font.glyphs[Character(ch.lowercased())] else { x += font.xHeight * s; continue }
                    // Per letter: size, slant, spacing and a wandering baseline.
                    let k = s * (1 + r.range(-0.06, 0.06) * v)
                    let slant = baseSlant + r.range(-0.05, 0.05) * v
                    drift = max(-0.04, min(0.04, drift + r.range(-0.012, 0.012) * v))
                    let base = baseline + drift * spacing
                    // A slow wobble across the letter (two gentle waves), not per-point noise.
                    let wobA = r.range(-0.012, 0.012) * o.xHeight * v, wobB = r.range(0, 2 * .pi)
                    for stroke in g.strokes where !stroke.isEmpty {
                        var pts: [InkPoint] = []
                        for (gx, gy) in stroke {
                            let px = x + gx * k + gy * k * tan(slant)
                            let py = base - gy * k
                            pts.append(InkPoint(x: px, y: py))
                        }
                        pts = resample(pts, step: max(0.4, o.xHeight * 0.12))
                        let n = pts.count
                        var length = 0.0
                        for i in 0..<n {
                            if i > 0 { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
                            let f = n > 1 ? Double(i) / Double(n - 1) : 0.5
                            let wob = wobA * sin(f * .pi * 2 + wobB)
                            pts[i].x += wob
                            pts[i].y += wob * 0.6
                            // Pressure: lands light, presses through the middle, lifts.
                            pts[i].pressure = min(1, max(0.15, 0.32 + 0.38 * sin(min(1, f * 1.15) * .pi) + r.range(-0.03, 0.03) * v))
                            // About 140 points a second, a touch slower on short (curvy) strokes.
                            pts[i].t = t + length / 0.14
                        }
                        t += length / 0.14 + 90
                        strokes.append(pts)
                    }
                    x += g.advance * k * (1 + r.range(-0.08, 0.08) * v * 0.5)
                }
            }
        }
        var bounds: InkGeometry.Rect?
        if let all = Optional(strokes.flatMap { $0 }), !all.isEmpty { bounds = InkGeometry.bounds(all) }
        return Result(strokes: strokes, bounds: bounds, lines: lines.count)
    }

    /// Writes `text` to fit a box: the given x-height, shrunk (down to `minScale`) to fit, wrapped
    /// to the box's width, first baseline near the top. Nil when even the smallest doesn't fit.
    public static func fit(_ text: String, in box: InkGeometry.Rect, options: Options, minScale: Double = 0.7) -> Result? {
        var o = options
        o.maxWidth = box.width
        let start = o.xHeight
        var scale = 1.0
        while scale >= minScale - 1e-9 {
            o.xHeight = start * scale
            let spacing = o.lineSpacing ?? o.xHeight * 2.6
            let res = write(text, at: InkPoint(x: box.x, y: box.y + o.xHeight * 1.8), options: o)
            let longest = text.split(separator: " ").map { width(String($0), options: o) }.max() ?? 0
            if Double(res.lines) * spacing <= box.height + o.xHeight, longest <= box.width { return res }
            scale -= 0.1
        }
        return nil
    }

    /// Points no further apart than `step` (a font's long straight lines get points to wobble).
    static func resample(_ p: [InkPoint], step: Double) -> [InkPoint] {
        guard p.count > 1 else { return p }
        var out: [InkPoint] = [p[0]]
        for i in 1..<p.count {
            let a = p[i - 1], b = p[i]
            let d = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int((d / step).rounded(.up)))
            for k in 1...n {
                let f = Double(k) / Double(n)
                out.append(InkPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    // MARK: Matching the writing around

    /// The x-height to write at near `target`, from the user's own ink: the boxes of nearby strokes
    /// (`strokes`) and Vision's line boxes (`lines`). Writing on the same line counts most, nearer
    /// writing more than further; long lines and drawings are ignored. Falls back to the ruling,
    /// then the target box, then all of the page's writing, then 7 pt.
    public static func sizeNear(_ target: InkGeometry.Rect, strokes: [InkGeometry.Rect], lines: [InkGeometry.Rect] = [], ruling: Double? = nil,
                                style: Style = .neat) -> Double {
        let k = fonts[style.key]?.strokeHeightPerX ?? 1.6
        // Letter-sized strokes only: not a long line, an underline, a box or a dot.
        let letters = strokes.filter { $0.height >= 2.5 && $0.height <= 80 && $0.width <= max(60, $0.height * 6) }
        let midY = target.y + target.height / 2
        func median(_ pairs: [(Double, Double)]) -> Double? {
            let sorted = pairs.sorted { $0.0 < $1.0 }
            let total = sorted.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return nil }
            var acc = 0.0
            for (v, w) in sorted { acc += w; if acc >= total / 2 { return v } }
            return sorted.last?.0
        }
        // Vision's lines: a line box is about 2.4 x-heights tall (ascenders and descenders).
        let sameLineBoxes = lines.filter { abs(($0.y + $0.height / 2) - midY) < max($0.height, target.height) * 0.6 }
        if let h = median(sameLineBoxes.map { ($0.height / 2.4, 1) }) { return h }
        let sameLine = letters.filter { abs(($0.y + $0.height / 2) - midY) < max(target.height, $0.height) * 0.75 }
        if sameLine.count >= 3, let h = median(sameLine.map { ($0.height, 1) }) { return h / k }
        let near = letters.compactMap { b -> (Double, Double)? in
            let dx = max(0, max(target.x - b.maxX, b.x - target.maxX)), dy = max(0, max(target.y - b.maxY, b.y - target.maxY))
            let d = hypot(dx, dy)
            guard d < 200 else { return nil }
            return (b.height, 1 / (1 + d / 40))
        }
        if near.count >= 3, let h = median(near) { return h / k }
        if let ruling, ruling > 0 { return ruling * 0.42 }
        if target.height > 4 { return min(14, target.height * 0.42) }
        if letters.count >= 3, let h = median(letters.map { ($0.height, 1) }) { return h / k }
        return 7
    }
}

extension String {
    /// A hash that's the same on every device and launch (Swift's `hashValue` isn't).
    public var stableHash: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}
