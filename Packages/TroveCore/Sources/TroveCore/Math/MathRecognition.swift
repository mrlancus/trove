import Foundation

// The geometry and guessing half of Math Assist (docs/MASTER_PLAN.md G7). The platform reads
// pictures or strokes (Vision, PKStrokeRecognizer); everything that decides *when* to read and
// *which* reading is right lives here, so it's tested on Linux and costs no model time.

/// A stroke as Math Assist sees it: its id, version and points (page coordinates, y down).
public struct MathStroke: Sendable, Equatable {
    public var id: String
    public var version: String
    public var points: [InkPoint]
    public var bounds: InkGeometry.Rect

    public init(id: String, version: String = "", points: [InkPoint]) {
        self.id = id
        self.version = version
        self.points = points
        self.bounds = InkGeometry.bounds(points) ?? InkGeometry.Rect(x: 0, y: 0, width: 0, height: 0)
    }
}

// MARK: - Spotting "="

public enum EqualsDetector {
    /// A short, nearly straight, nearly horizontal stroke.
    public static func isDash(_ s: MathStroke) -> Bool {
        let b = s.bounds
        guard b.width > 2, s.points.count >= 2 else { return false }
        guard b.height <= max(b.width * 0.35, 1.5) else { return false }
        // Not a scribble: its path is not much longer than its width.
        var length = 0.0
        for i in 1..<s.points.count {
            length += hypot(s.points[i].x - s.points[i - 1].x, s.points[i].y - s.points[i - 1].y)
        }
        return length <= b.width * 1.5
    }

    /// Whether the newest stroke and the one before it make an `=`; returns its box if so.
    /// Two dashes of similar length, one above the other, overlapping horizontally, with a gap
    /// between them of roughly a fifth to one and a quarter of their length.
    public static func equals(_ a: MathStroke, _ b: MathStroke) -> InkGeometry.Rect? {
        guard isDash(a), isDash(b) else { return nil }
        let ra = a.bounds, rb = b.bounds
        let short = min(ra.width, rb.width), long = max(ra.width, rb.width)
        guard long <= short * 2.2 else { return nil }
        let overlap = min(ra.maxX, rb.maxX) - max(ra.x, rb.x)
        guard overlap >= short * 0.5 else { return nil }
        let gap = Swift.abs((ra.y + ra.height / 2) - (rb.y + rb.height / 2))
        let avg = (ra.width + rb.width) / 2
        guard gap >= avg * 0.12, gap <= avg * 1.25 else { return nil }
        let x = min(ra.x, rb.x), y = min(ra.y, rb.y)
        return InkGeometry.Rect(x: x, y: y, width: max(ra.maxX, rb.maxX) - x, height: max(ra.maxY, rb.maxY) - y)
    }
}

// MARK: - The line to read

public enum MathLine {
    /// The strokes of the expression left of an `=`: those in its band (and anything that overlaps
    /// what's already gathered vertically, for fractions and exponents), walking leftwards until a
    /// gap wider than a few characters. Nothing else on the page is looked at by the recogniser.
    public static func gather(equals eq: InkGeometry.Rect, excluding: Set<String>, from strokes: [MathStroke]) -> [MathStroke] {
        let eqMidY = eq.y + eq.height / 2
        let lineHeight = max(eq.width * 1.6, eq.height * 3)
        let bandTop = eqMidY - lineHeight * 0.75, bandBottom = eqMidY + lineHeight * 0.75
        let candidates = strokes.filter { s in
            !excluding.contains(s.id) && s.bounds.maxX <= eq.x + eq.width * 0.3 && s.bounds.maxY >= bandTop && s.bounds.y <= bandBottom
        }.sorted { $0.bounds.maxX > $1.bounds.maxX }
        var gathered: [MathStroke] = []
        var left = eq.x
        var top = bandTop, bottom = bandBottom
        let maxGap = max(eq.width * 2.5, lineHeight * 1.2)
        for s in candidates {
            if s.bounds.maxX < left - maxGap { break }
            guard s.bounds.maxY >= top, s.bounds.y <= bottom else { continue }
            gathered.append(s)
            left = min(left, s.bounds.x)
            // A tall fraction or root widens the band for what's left of it.
            top = min(top, s.bounds.y)
            bottom = max(bottom, s.bounds.maxY)
        }
        return gathered.sorted { $0.bounds.x < $1.bounds.x }
    }

    /// The box around strokes (what the picture recogniser is given, cropped).
    public static func bounds(_ strokes: [MathStroke]) -> InkGeometry.Rect? {
        guard let first = strokes.first else { return nil }
        var minX = first.bounds.x, minY = first.bounds.y, maxX = first.bounds.maxX, maxY = first.bounds.maxY
        for s in strokes.dropFirst() {
            minX = min(minX, s.bounds.x); minY = min(minY, s.bounds.y)
            maxX = max(maxX, s.bounds.maxX); maxY = max(maxY, s.bounds.maxY)
        }
        return InkGeometry.Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A key for the line's strokes as they are: the cache is asked first, so an untouched line is
    /// never read twice.
    public static func key(_ strokes: [MathStroke]) -> String {
        strokes.map { "\($0.id)@\($0.version)" }.sorted().joined(separator: ",").sha256Hex
    }

    /// Picture size for the recogniser: the line drawn about 48 px tall (a few hundred px wide),
    /// enough for Vision's accurate mode, a fraction of a page picture's cost.
    public static func renderScale(for box: InkGeometry.Rect, targetHeight: Double = 48, maxWidth: Double = 1200) -> Double {
        guard box.height > 0, box.width > 0 else { return 1 }
        return min(targetHeight / box.height, maxWidth / box.width, 8)
    }
}

// MARK: - Choosing the right reading

public enum MathCandidates {
    /// What handwriting recognisers confuse in maths, with how likely each swap is (1 = free).
    public static let lookAlikes: [Character: [(Character, Double)]] = [
        "l": [("1", 0.9)], "I": [("1", 0.9)], "|": [("1", 0.9)], "i": [("1", 0.5)], "!": [("1", 0.5)],
        "O": [("0", 0.95)], "o": [("0", 0.9)], "D": [("0", 0.5)], "Q": [("0", 0.4)],
        "S": [("5", 0.85)], "s": [("5", 0.7)],
        "Z": [("2", 0.85)], "z": [("2", 0.8)],
        "X": [("*", 0.8), ("x", 0.9)], "x": [("*", 0.75)], "×": [("x", 0.6)], "t": [("+", 0.85)], "T": [("+", 0.6)],
        "g": [("9", 0.85)], "q": [("9", 0.75)], "b": [("6", 0.85)], "G": [("6", 0.6)], "B": [("8", 0.8)],
        "A": [("4", 0.5)], "y": [("4", 0.4)], "J": [("3", 0.4)], "u": [("4", 0.3)],
        "C": [("(", 0.7)], "c": [("(", 0.5)], ">": [(")", 0.5)], "<": [("(", 0.4)],
        "_": [("-", 0.9)], "~": [("-", 0.8)], "÷": [("+", 0.4)], "\u{2192}": [("-", 0.4)],
        "'": [("^", 0.3)], "`": [(" ", 0.9)], ",": [(".", 0.8)],
    ]

    public struct Reading: Equatable, Sendable {
        public var text: String
        public var outcome: MathAssist.Outcome
        public var score: Double
    }

    /// One recogniser guess: its text and confidence (0…1).
    public struct Guess: Sendable, Equatable {
        public var text: String
        public var confidence: Double
        public init(_ text: String, _ confidence: Double) { self.text = text; self.confidence = confidence }
    }

    /// The most likely reading that is valid maths. Each guess is expanded with look-alike swaps
    /// (fewest swaps first, at most `maxVariants` each); a variant scores its guess's confidence ×
    /// how likely its swaps are × how well it fits (a sure answer beats "unsure", and variables
    /// already defined on the page beat new ones). Returns nil when nothing parses: the line shows
    /// "?" instead of a wrong answer.
    public static func best(_ guesses: [Guess], env: [String: Double] = [:], maxVariants: Int = 48) -> Reading? {
        var bestReading: Reading?
        var seen: Set<String> = []
        for guess in guesses {
            for (variant, swapScore) in variants(of: guess.text, limit: maxVariants) where seen.insert(variant).inserted {
                let outcome = MathAssist.solve(variant, env: env)
                let fit = fitScore(variant, outcome: outcome, env: env)
                guard fit > 0 else { continue }
                let score = max(guess.confidence, 0.01) * swapScore * fit
                if score > (bestReading?.score ?? 0) { bestReading = Reading(text: variant, outcome: outcome, score: score) }
            }
        }
        return bestReading
    }

    /// Below this a reading is too doubtful to show: the line gets a "?".
    public static let minimumScore = 0.05

    static func fitScore(_ text: String, outcome: MathAssist.Outcome, env: [String: Double]) -> Double {
        var fit: Double
        switch outcome {
        case .unsure: return 0
        case .value, .solved, .assignment: fit = 1
        // A check that comes out wrong is less likely a correct reading than one that comes out right.
        case .check(let ok, _, _): fit = ok ? 1 : 0.55
        }
        let letters = text.filter(\.isLetter)
        let known = letters.filter { env[String($0).lowercased()] != nil }.count
        let unknown = letters.count - known
        // Each unexplained letter costs a little: "2x" is plausible, "2xyzq" isn't.
        fit *= pow(0.85, Double(max(0, unknown - 1)))
        fit *= pow(1.05, Double(known))
        return fit
    }

    /// Variants of a guess with look-alike swaps, fewest swaps first, best swaps first within that.
    static func variants(of text: String, limit: Int) -> [(String, Double)] {
        let chars = Array(text.filter { !$0.isWhitespace })
        let spots = chars.indices.filter { lookAlikes[chars[$0]] != nil }
        var out: [(String, Double)] = [(String(chars), 1)]
        // Breadth-first over the number of swaps (at most 4), keeping the best `limit`.
        var frontier: [([Character], Double, Int)] = [(chars, 1, -1)]
        for _ in 0..<min(4, spots.count) {
            var next: [([Character], Double, Int)] = []
            for (current, score, lastSpot) in frontier {
                for spot in spots where spot > lastSpot {
                    for (replacement, p) in lookAlikes[chars[spot]] ?? [] {
                        var c = current
                        c[spot] = replacement
                        next.append((c, score * p, spot))
                    }
                }
            }
            next.sort { $0.1 > $1.1 }
            frontier = Array(next.prefix(limit))
            out.append(contentsOf: frontier.map { (String($0.0).filter { !$0.isWhitespace }, $0.1) })
            if out.count >= limit * 2 { break }
        }
        return out
    }
}

// MARK: - Never twice

/// Answers by line key, with the order they were used, capped (an untouched line costs nothing).
public struct MathCache: Sendable {
    private var entries: [String: MathCandidates.Reading?] = [:]
    private var order: [String] = []
    public let capacity: Int
    /// How many times the recogniser actually ran (for Settings → Battery and the hour-of-maths test).
    public private(set) var recognitions = 0
    public private(set) var hits = 0

    public init(capacity: Int = 256) { self.capacity = capacity }

    public mutating func reading(for key: String) -> MathCandidates.Reading?? {
        guard let r = entries[key] else { return nil }
        hits += 1
        return r
    }

    public mutating func store(_ reading: MathCandidates.Reading?, for key: String) {
        recognitions += 1
        if entries.index(forKey: key) == nil { order.append(key) }
        entries.updateValue(reading, forKey: key)
        if order.count > capacity {
            let old = order.removeFirst()
            entries.removeValue(forKey: old)
        }
    }
}
