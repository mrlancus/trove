import Foundation

// The sketch editor's controls, as pure logic (docs/plans/sketch-2-plan.md T1, T4, T5): what the
// zoom shows as 100 %, which toolbar groups fold away when it's narrow, and where floating
// controls go so none covers another. Tested on Linux; the views only draw what these decide.

/// Your own 100 % (T5): the absolute zoom that shows as 100 %. The original is 1 (a page point is a
/// screen point).
public struct ZoomBase: Equatable, Sendable {
    public var base: Double

    public init(base: Double = 1) { self.base = Self.clamp(base) }

    static func clamp(_ z: Double) -> Double { z.isFinite ? min(10, max(0.1, z)) : 1 }

    public var isOriginal: Bool { abs(base - 1) < 0.0005 }

    /// The zoom as shown: relative to your 100 %.
    public func percent(_ zoom: Double) -> Int { Int((zoom / base * 100).rounded()) }
    public func label(_ zoom: Double) -> String { "\(percent(zoom))%" }

    /// The absolute zoom for a shown percentage.
    public func zoom(forPercent p: Double) -> Double { p / 100 * base }

    /// The menu's choices, in shown percentages.
    public static let presets: [Double] = [50, 100, 150, 200, 400]

    /// Two-finger double-tap: to your 100 %, or back to where you were if you're already there.
    public func toggle(from zoom: Double, previous: Double?) -> Double {
        abs(zoom - base) / base < 0.02 ? (previous ?? base) : base
    }
}

/// The toolbar's groups and the order they fold in when the bar is too narrow (T1).
public enum ToolbarFold {
    public enum Group: String, CaseIterable, Sendable {
        /// Never fold: Done, pens, highlighter, eraser, lasso, undo/redo, Ask, More.
        case core
        case sizes, colours, insert, title, shapesAndText
    }

    /// Folding order: first to go first.
    public static let order: [Group] = [.sizes, .colours, .insert, .title, .shapesAndText]

    /// Which groups fold for `width`, given each group's width (`core` must fit; spacing included).
    public static func folded(width: Double, widths: [Group: Double]) -> Set<Group> {
        var used = widths.values.reduce(0, +)
        var out: Set<Group> = []
        for g in order where used > width {
            guard let w = widths[g] else { continue }
            used -= w
            out.insert(g)
        }
        return out
    }
}

/// Places floating controls so none covers another or leaves the safe area (T4).
public enum HUDPlacement {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var size: Size
        public var anchor: Anchor
        /// Higher keeps its place; lower moves.
        public var priority: Int
        public init(id: String, size: Size, anchor: Anchor, priority: Int) {
            self.id = id; self.size = size; self.anchor = anchor; self.priority = priority
        }
    }

    public struct Size: Sendable, Equatable {
        public var width: Double
        public var height: Double
        public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    }

    public enum Anchor: Sendable, Equatable {
        case bottomLeading, bottomCentre, bottomTrailing, topCentre, topTrailing
        /// A fixed place (the floating Ask box, wherever the user put it).
        case fixed(InkGeometry.Rect)
    }

    /// Frames inside `area` (the safe area, already without the keyboard), with `gap` between
    /// controls and from the edges. Items that can't fit anywhere are left out (the caller folds
    /// them to an icon).
    public static func place(_ items: [Item], in area: InkGeometry.Rect, gap: Double = 8) -> [String: InkGeometry.Rect] {
        var placed: [String: InkGeometry.Rect] = [:]
        var taken: [InkGeometry.Rect] = []
        let inner = InkGeometry.Rect(x: area.x + gap, y: area.y + gap, width: max(0, area.width - gap * 2), height: max(0, area.height - gap * 2))
        func overlaps(_ r: InkGeometry.Rect) -> Bool {
            taken.contains { r.x < $0.maxX + gap && $0.x < r.maxX + gap && r.y < $0.maxY + gap && $0.y < r.maxY + gap }
        }
        func inside(_ r: InkGeometry.Rect) -> Bool {
            r.x >= inner.x - 1e-9 && r.y >= inner.y - 1e-9 && r.maxX <= inner.maxX + 1e-9 && r.maxY <= inner.maxY + 1e-9
        }
        for item in items.sorted(by: { $0.priority > $1.priority }) {
            let w = item.size.width, h = item.size.height
            var r: InkGeometry.Rect
            switch item.anchor {
            case .fixed(let f): r = f
            case .bottomLeading: r = InkGeometry.Rect(x: inner.x, y: inner.maxY - h, width: w, height: h)
            case .bottomCentre: r = InkGeometry.Rect(x: inner.x + (inner.width - w) / 2, y: inner.maxY - h, width: w, height: h)
            case .bottomTrailing: r = InkGeometry.Rect(x: inner.maxX - w, y: inner.maxY - h, width: w, height: h)
            case .topCentre: r = InkGeometry.Rect(x: inner.x + (inner.width - w) / 2, y: inner.y, width: w, height: h)
            case .topTrailing: r = InkGeometry.Rect(x: inner.maxX - w, y: inner.y, width: w, height: h)
            }
            if case .fixed = item.anchor {
                placed[item.id] = r
                taken.append(r)
                continue
            }
            // Move up (bottom anchors) or down (top anchors) past what's in the way.
            let up: Bool
            switch item.anchor {
            case .topCentre, .topTrailing: up = false
            default: up = true
            }
            var tries = 0
            while overlaps(r), tries < 40 {
                tries += 1
                let blocker = taken.first { r.x < $0.maxX + gap && $0.x < r.maxX + gap && r.y < $0.maxY + gap && $0.y < r.maxY + gap }!
                r.y = up ? blocker.y - gap - h : blocker.maxY + gap
            }
            guard !overlaps(r), inside(r) else { continue }
            placed[item.id] = r
            taken.append(r)
        }
        return placed
    }
}
