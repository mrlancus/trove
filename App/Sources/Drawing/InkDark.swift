import Foundation
import TroveCore

/// The sketch editor's dark page (a toggle on each device, `InkEditorModel.darkPage`): sketch pages
/// show black, and only black and white ink swap (near black ↔ near white); every other colour is
/// drawn as stored. Display only: what's stored, synced and exported keeps its real colours.
///
/// The swap turns each channel c into 1 − c, but only for greys near black or white, so doing it
/// twice gives the colour back (a stroke drawn in dark mode is stored as the colour the pen has).
enum InkDark {
    static let page = "#000000"
    /// Only how far a colour is from grey and how light it is decide; both survive the swap.
    private static let greyness = 0.12, edge = 0.2

    static func swaps(_ hex: String) -> Bool {
        // Only "#rrggbb" (anything else, such as "none", is left alone).
        guard hex.count == 7, hex.hasPrefix("#"), UInt32(hex.dropFirst(), radix: 16) != nil else { return false }
        let (r, g, b) = InkStroke.rgb(hex)
        let hi = max(r, g, b), lo = min(r, g, b)
        let light = (r + g + b) / 3
        return hi - lo <= greyness && (light <= edge || light >= 1 - edge)
    }

    /// The colour as the dark page shows it.
    static func swap(_ hex: String) -> String {
        guard swaps(hex) else { return hex }
        let (r, g, b) = InkStroke.rgb(hex)
        func byte(_ v: Double) -> Int { Int((min(1, max(0, 1 - v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// Whether a page turns dark: sketch paper only (a PDF or picture keeps its own look).
    static func applies(to spec: InkPageSpec) -> Bool {
        if case .paper = spec.background { return true }
        return false
    }

    /// The page as shown dark: black paper (its lines drawn light, as on any dark page).
    static func spec(_ spec: InkPageSpec) -> InkPageSpec {
        guard case .paper(let paper, _) = spec.background else { return spec }
        var out = spec
        out.background = .paper(paper, color: page)
        return out
    }

    static func line(_ line: InkLine) -> InkLine {
        var out = line
        out.color = swap(line.color)
        if let fill = line.style.fill { out.style.fill = swap(fill) }
        return out
    }

    static func box(_ box: InkBox) -> InkBox {
        var out = box
        out.color = swap(box.color)
        return out
    }

    static func content(_ content: InkContent) -> InkContent {
        var out = content
        out.strokes = content.strokes.map(line)
        out.elements = content.elements.map(box)
        return out
    }
}
