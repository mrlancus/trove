import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Vector content drawn in tiles at the size it shows (Core Animation's tiled layer): only the tiles
/// on screen are drawn, off the main thread, and they're kept until the size changes. Sharp at any
/// zoom and no work while it sits still; a big GoodNotes whiteboard never becomes one huge picture.
struct InkTiledPage: View {
    /// Changes when what's drawn changes (the tiles are drawn again).
    let token: String
    /// Draws into a context in view points, top-left origin, for a view of the given size.
    let painter: @Sendable (CGContext, CGSize) -> Void

    var body: some View {
        Host(token: token, painter: painter)
    }

    #if canImport(UIKit)
    struct Host: UIViewRepresentable {
        let token: String
        let painter: @Sendable (CGContext, CGSize) -> Void

        func makeUIView(context: Context) -> InkTiledUIView {
            let view = InkTiledUIView()
            view.tiled.painter = painter
            view.token = token
            return view
        }

        func updateUIView(_ view: InkTiledUIView, context: Context) {
            guard view.token != token else { return }
            view.token = token
            view.tiled.painter = painter
            view.tiled.setNeedsDisplay()
        }
    }
    #else
    struct Host: NSViewRepresentable {
        let token: String
        let painter: @Sendable (CGContext, CGSize) -> Void

        func makeNSView(context: Context) -> InkTiledNSView {
            let view = InkTiledNSView()
            view.tiled.painter = painter
            view.token = token
            return view
        }

        func updateNSView(_ view: InkTiledNSView, context: Context) {
            guard view.token != token else { return }
            view.token = token
            view.tiled.painter = painter
            view.tiled.setNeedsDisplay()
        }
    }
    #endif
}

/// The tiled layer: each tile asks the painter for its part (Core Graphics clips to the tile).
final class InkTiledLayer: CATiledLayer, @unchecked Sendable {
    nonisolated(unsafe) var painter: (@Sendable (CGContext, CGSize) -> Void)?

    override class func fadeDuration() -> CFTimeInterval { 0.08 }

    override func draw(in ctx: CGContext) {
        let size = bounds.size
        #if os(macOS)
        // AppKit layers draw bottom-up unless their geometry is flipped.
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        #endif
        painter?(ctx, size)
    }
}

#if canImport(UIKit)
final class InkTiledUIView: UIView {
    let tiled = InkTiledLayer()
    var token = ""
    private var drawnSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isUserInteractionEnabled = false
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 1
        layer.addSublayer(tiled)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiled.frame = bounds
        tiled.contentsScale = max(1, traitCollection.displayScale)
        CATransaction.commit()
        if bounds.size != drawnSize {
            drawnSize = bounds.size
            tiled.setNeedsDisplay()
        }
    }
}
#else
final class InkTiledNSView: NSView {
    let tiled = InkTiledLayer()
    var token = ""
    private var drawnSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 1
        layer?.addSublayer(tiled)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiled.frame = bounds
        tiled.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        if bounds.size != drawnSize {
            drawnSize = bounds.size
            tiled.setNeedsDisplay()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tiled.contentsScale = window?.backingScaleFactor ?? 2
        tiled.setNeedsDisplay()
    }
}
#endif
