import SwiftUI
import TroveCore
#if os(macOS)
import AppKit
#endif

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
    @Environment(AppModel.self) private var model

    var body: some View {
        // One of your tags shows in its colour; others in the item's tint.
        if let color = model.clipboard.color(ofTag: tag.lowercased())?.color {
            label.background(color.opacity(0.16), in: Capsule()).foregroundStyle(color)
        } else {
            label.background(.tint.opacity(0.12), in: Capsule()).foregroundStyle(.tint)
        }
    }

    private var label: some View {
        Text("#\(tag)")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
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

// MARK: - Sheet sizes (Mac)

extension View {
    /// The size a sheet would like on the Mac, shrunk to fit its window and screen. A Mac sheet hangs
    /// from its window and can't be moved, so one bigger than the window runs off the screen and
    /// hides its buttons. iPhone and iPad size sheets themselves, so this does nothing there.
    func sheetSize(width: CGFloat, height: CGFloat) -> some View {
        modifier(SheetSize(wanted: CGSize(width: width, height: height)))
    }
}

private struct SheetSize: ViewModifier {
    #if os(macOS)
    @State private var size: CGSize

    init(wanted: CGSize) {
        // Worked out once, when the sheet opens (later the sheet itself may be the key window).
        _size = State(initialValue: Self.fit(wanted))
    }

    func body(content: Content) -> some View {
        content.frame(width: size.width, height: size.height)
    }

    @MainActor static func fit(_ wanted: CGSize) -> CGSize {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        var limit = CGSize(width: screen.width - 60, height: screen.height - 90)
        if let frame = window?.frame.size {
            limit.width = min(limit.width, max(frame.width - 40, 520))
            limit.height = min(limit.height, max(frame.height - 70, 420))
        }
        return CGSize(width: min(wanted.width, limit.width), height: min(wanted.height, limit.height))
    }
    #else
    init(wanted: CGSize) {}
    func body(content: Content) -> some View { content }
    #endif
}

// MARK: - Tag colours

extension TagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}
