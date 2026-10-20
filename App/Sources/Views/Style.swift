import SwiftUI
import TroveCore

/// Visual language per item type (RESEARCH.md design direction: calm, premium, Apple-native).
enum ItemStyle {
    static func symbol(for item: Item) -> String {
        switch item.category {
        case .recipe: return "fork.knife"
        case .product: return "bag"
        case .place: return "mappin.and.ellipse"
        case .event: return "calendar"
        case .video: return "play.rectangle.fill"
        case .receipt: return "receipt"
        case .quote: return "quote.opening"
        case .idea: return "lightbulb"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .article: return "doc.richtext"
        case .note: return "note.text"
        case .other: break
        }
        switch item.kind {
        case .note: return "note.text"
        case .link: return "link"
        case .image: return item.source == .screenshot ? "camera.viewfinder" : "photo"
        case .pdf: return item.source == .goodnotes ? "pencil.and.scribble" : "doc.text"
        case .audio: return "waveform"
        case .video: return "film"
        case .file: return "doc"
        case .highlight: return "highlighter"
        case .email: return "envelope"
        case .sketch: return "scribble.variable"
        }
    }

    static func tint(for item: Item) -> Color {
        switch item.category {
        case .recipe: .orange
        case .product: .pink
        case .place: .green
        case .event: .red
        case .video: .purple
        case .receipt: .teal
        case .quote: .indigo
        case .idea: .yellow
        case .code: .gray
        case .article: .blue
        case .note: .mint
        case .other: item.kind == .email ? .cyan : .blue
        }
    }

    static func sourceLabel(_ source: ItemSource) -> String {
        switch source {
        case .app: "Trove"
        case .share: "Share sheet"
        case .web: "Browser"
        case .email: "Email"
        case .goodnotes: "GoodNotes"
        case .kindle: "Kindle"
        case .readwise: "Readwise"
        case .obsidian: "Obsidian"
        case .appleNotes: "Apple Notes"
        case .notion: "Notion"
        case .screenshot: "Screenshots"
        case .voice: "Voice"
        case .scan: "Scan"
        case .import: "Import"
        case .clipboard: "Clipboard"
        }
    }

    static func sourceSymbol(_ source: ItemSource) -> String {
        switch source {
        case .goodnotes: "pencil.and.scribble"
        case .kindle, .readwise: "books.vertical"
        case .email: "envelope"
        case .web: "safari"
        case .appleNotes: "note.text"
        case .obsidian: "point.3.connected.trianglepath.dotted"
        case .notion: "square.text.square"
        case .screenshot: "camera.viewfinder"
        case .voice: "mic"
        case .scan: "doc.viewfinder"
        case .clipboard: "doc.on.clipboard"
        default: "tray"
        }
    }
}

/// Liquid Glass on OS 26+, a material fallback before that.
struct Glass: ViewModifier {
    var cornerRadius: CGFloat = 18
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Subtle card used across the library grid.
    func card(cornerRadius: CGFloat = 18) -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct TagChip: View {
    var tag: String
    var body: some View {
        Text("#\(tag)")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

extension Date {
    var relative: String {
        let seconds = -timeIntervalSinceNow
        if seconds < 60 { return "Just now" }
        return formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
