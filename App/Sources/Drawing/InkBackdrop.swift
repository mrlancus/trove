import CoreGraphics
import Foundation
import TroveCore

/// File pages (PDF, picture, GoodNotes) under the ink, sharp at any zoom without drawing their
/// vectors on every frame: a picture of the whole page for overviews and while pinching, plus the
/// part on screen drawn from the vectors at the screen's own resolution once zooming or scrolling
/// stops (kept until the view moves past it or needs more detail). Paper is drawn live instead.
@MainActor
final class InkBackdrop {
    /// Part of a page, in page points, and how many pixels it has per point.
    struct Piece {
        let rect: CGRect
        let density: CGFloat
        let image: CGImage
    }

    /// Called when a picture arrives (redraw the paper).
    var changed: (() -> Void)?
    private var whole: [String: CGImage] = [:]
    private var detail: [String: Piece] = [:]
    private var rendering: Set<String> = []
    private var pending: Task<Void, Never>?
    private var pendingFor = ""
    /// Bumped on every new request, so a slower, older render never replaces a newer one.
    private var generation = 0
    /// Bumped by `reset`, so whole-page pictures still being made for the old pages are thrown away.
    private var wholeGeneration = 0

    /// The most a sharp part may hold (the screen and a margin round it fit easily).
    static let maxPixels = 24_000_000
    /// The whole-page picture is at most this wide.
    static let wholeWidth = 2400.0

    func hasWhole(_ key: String) -> Bool { whole[key] != nil }

    /// Draws what's ready of a page into a context set up in page points (top-left origin).
    func draw(_ key: String, size: CGSize, in ctx: CGContext) {
        if let image = whole[key] { InkRenderer.drawImage(image, in: CGRect(origin: .zero, size: size), ctx: ctx) }
        if let piece = detail[key] { InkRenderer.drawImage(piece.image, in: piece.rect, ctx: ctx) }
    }

    /// Makes the whole-page picture once, in the background.
    func prepare(_ spec: InkPageSpec) {
        let key = spec.key
        guard whole[key] == nil, !rendering.contains(key) else { return }
        rendering.insert(key)
        let pixels = Int(min(Self.wholeWidth, spec.width * 2.5))
        let made = wholeGeneration
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(spec, content: InkContent(), pixelWidth: pixels).map(InkImage.init) }.value
            guard let self, self.wholeGeneration == made else { return }
            self.rendering.remove(key)
            if let rendered { self.whole[key] = rendered.image; self.changed?() }
        }
    }

    /// Lets a page's pictures go (far off screen, or the pages changed).
    func drop(_ key: String) {
        whole[key] = nil
        detail[key] = nil
    }

    /// Forgets everything (another page shown, or the dark page turned on or off).
    func reset() {
        whole = [:]
        detail = [:]
        rendering = []
        wholeGeneration += 1
        pending?.cancel()
        pendingFor = ""
        generation += 1
    }

    func keep(only keys: Set<String>) {
        whole = whole.filter { keys.contains($0.key) }
        detail = detail.filter { keys.contains($0.key) }
    }

    /// What's on screen of each page (page points) at `density` screen pixels per page point: the
    /// parts that need more detail are drawn a moment after the view stops moving.
    func refine(_ visible: [(spec: InkPageSpec, rect: CGRect)], density: CGFloat) {
        var wanted: [(spec: InkPageSpec, rect: CGRect, density: CGFloat)] = []
        for v in visible {
            let page = CGRect(x: 0, y: 0, width: v.spec.width, height: v.spec.height)
            let seen = v.rect.intersection(page)
            guard !seen.isNull, seen.width > 0, seen.height > 0 else { continue }
            let base = whole[v.spec.key].map { CGFloat($0.width) / CGFloat(v.spec.width) } ?? 0
            // The whole-page picture is sharp enough at this zoom.
            if base >= density * 0.95 { detail[v.spec.key] = nil; continue }
            if let piece = detail[v.spec.key], piece.rect.contains(seen), piece.density >= density * 0.95, piece.density <= density * 2.5 { continue }
            // A margin round the screen, so a small scroll still finds it drawn.
            let margin = seen.insetBy(dx: -seen.width * 0.15, dy: -seen.height * 0.15).intersection(page)
            var d = density
            let pixels = margin.width * margin.height * d * d
            if pixels > CGFloat(Self.maxPixels) { d *= sqrt(CGFloat(Self.maxPixels) / pixels) }
            wanted.append((v.spec, margin, d))
        }
        let request = wanted.map { "\($0.spec.key)@\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height))x\(Int($0.density * 100))" }.joined(separator: ";")
        guard request != pendingFor else { return }
        pending?.cancel()
        pendingFor = request
        generation += 1
        guard !wanted.isEmpty else { return }
        let ticket = generation
        pending = Task { [weak self] in
            // Wait for the pinch or scroll to settle.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            for w in wanted {
                let spec = w.spec, area = w.rect, density = w.density
                let pixelWidth = max(1, Int((area.width * density).rounded()))
                let box = InkGeometry.Rect(x: area.minX, y: area.minY, width: area.width, height: area.height)
                let rendered = await Task.detached(priority: .userInitiated) {
                    InkRenderer.render(spec, content: InkContent(), pixelWidth: pixelWidth, area: box).map(InkImage.init)
                }.value
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                if let rendered {
                    self.detail[spec.key] = Piece(rect: area, density: CGFloat(rendered.image.width) / area.width, image: rendered.image)
                    self.changed?()
                }
            }
            if let self, self.generation == ticket { self.pendingFor = "" }
        }
    }
}
