import SwiftUI
import TroveCore
#if os(iOS)
import UIKit
#endif

/// The Ask box floats over the page (docs/plans/sketch-2-plan.md A4): drag it by its bar anywhere,
/// resize it from any edge or corner into any shape, double-tap the bar to fold it to just the bar,
/// or tuck it away as a small bubble. It remembers where it was (per device, for wide and tall
/// windows, as fractions of the space, so rotating keeps it in the same place). With an Apple
/// Pencil that hovers, it fades and lets the Pencil write underneath while the Pencil is over it.
struct FloatingAskBox: View {
    let editor: InkEditorModel
    /// The space it floats in.
    let container: CGSize
    let close: () -> Void

    @State private var frame: CGRect = .zero
    @State private var start: CGRect?
    @State private var folded = false
    @State private var bubble = false

    static let minSize = CGSize(width: 260, height: 200)
    static let snap: CGFloat = 12
    static let inset: CGFloat = 8

    private var key: String { "ask.frame.\(container.width >= container.height ? "wide" : "tall")" }

    var body: some View {
        ZStack(alignment: .topLeading) {
            panel
                .opacity(bubble ? 0 : (editor.pencilOverAsk ? 0.3 : 1))
                .allowsHitTesting(!bubble && !editor.pencilOverAsk)
            if bubble {
                Button { withAnimation(.snappy) { bubble = false } } label: {
                    Image(systemName: "sparkles").font(.title2.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.gray.opacity(0.25)))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .position(x: min(frame.maxX - 24, container.width - 32), y: max(frame.minY + 24, 32))
                .accessibilityLabel("Show Ask")
            }
        }
        .onAppear(perform: load)
        .onChange(of: container) { _, _ in load() }
    }

    private var shown: CGRect {
        var f = frame
        if folded { f.size.height = 44 }
        return f
    }

    private var panel: some View {
        VStack(spacing: 0) {
            bar
            // Kept alive while folded (the conversation lives in it), just not shown.
            StudyPanel(editor: editor)
                .frame(height: folded ? 0 : nil)
                .opacity(folded ? 0 : 1)
                .clipped()
        }
        .frame(width: shown.width, height: shown.height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.gray.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .overlay { if !folded { resizeHandles } }
        #if os(iOS)
        .background(PencilHoverDetector { over in if over { editor.pencilOverAsk = true } })
        #endif
        .background(GeometryReader { g in
            Color.clear
                .onAppear { editor.askFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in editor.askFrame = f }
        })
        .position(x: shown.midX, y: shown.midY)
        .onDisappear { editor.askFrame = nil; editor.pencilOverAsk = false }
    }

    /// The bar: drag to move, double-tap to fold, and the bubble and close buttons.
    private var bar: some View {
        HStack(spacing: 10) {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5)
            Text("Ask").font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Button("Move to the top right") { place(.topTrailing) }
                Button("Move to the bottom right") { place(.bottomTrailing) }
                Button("Move to the bottom left") { place(.bottomLeading) }
                Button("Move to the top left") { place(.topLeading) }
                Divider()
                Button("Make bigger") { grow(1.25) }
                Button("Make smaller") { grow(0.8) }
            } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Move or resize")
            Button { withAnimation(.snappy) { folded.toggle() } } label: { Image(systemName: folded ? "chevron.down" : "chevron.up") }
                .accessibilityLabel(folded ? "Unfold" : "Fold to the bar")
            Button { withAnimation(.snappy) { bubble = true } } label: { Image(systemName: "minus") }
                .accessibilityLabel("Tuck away")
            Button(action: close) { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Ask")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { withAnimation(.snappy) { folded.toggle() } }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if start == nil { start = frame }
                guard let s = start else { return }
                frame = clamp(s.offsetBy(dx: v.translation.width, dy: v.translation.height))
            }
            .onEnded { _ in
                start = nil
                withAnimation(.snappy) { frame = snapped(frame) }
                save()
            })
    }

    // MARK: Resizing from any edge or corner

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    private var resizeHandles: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, t: CGFloat = 10, c: CGFloat = 26
            ZStack(alignment: .topLeading) {
                handle([.left]).frame(width: t, height: h - c * 2).offset(x: -t / 2, y: c)
                handle([.right]).frame(width: t, height: h - c * 2).offset(x: w - t / 2, y: c)
                handle([.bottom]).frame(width: w - c * 2, height: t).offset(x: c, y: h - t / 2)
                handle([.top]).frame(width: w - c * 2, height: t).offset(x: c, y: -t / 2)
                handle([.top, .left]).frame(width: c, height: c).offset(x: -c / 3, y: -c / 3)
                handle([.top, .right]).frame(width: c, height: c).offset(x: w - c * 2 / 3, y: -c / 3)
                handle([.bottom, .left]).frame(width: c, height: c).offset(x: -c / 3, y: h - c * 2 / 3)
                handle([.bottom, .right]).frame(width: c, height: c).offset(x: w - c * 2 / 3, y: h - c * 2 / 3)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
            }
        }
    }

    private func handle(_ edges: Edges) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = frame }
                    guard let s = start else { return }
                    var f = s
                    let dx = v.translation.width, dy = v.translation.height
                    if edges.contains(.left) { f.origin.x = min(s.maxX - Self.minSize.width, s.minX + dx); f.size.width = s.maxX - f.minX }
                    if edges.contains(.right) { f.size.width = max(Self.minSize.width, s.width + dx) }
                    if edges.contains(.top) { f.origin.y = min(s.maxY - Self.minSize.height, s.minY + dy); f.size.height = s.maxY - f.minY }
                    if edges.contains(.bottom) { f.size.height = max(Self.minSize.height, s.height + dy) }
                    frame = clamp(f)
                }
                .onEnded { _ in start = nil; save() })
            .accessibilityHidden(true)
    }

    // MARK: Placing

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func place(_ corner: Corner) {
        var f = frame
        let i = Self.inset
        switch corner {
        case .topLeading: f.origin = CGPoint(x: i, y: i)
        case .topTrailing: f.origin = CGPoint(x: container.width - f.width - i, y: i)
        case .bottomLeading: f.origin = CGPoint(x: i, y: container.height - f.height - i)
        case .bottomTrailing: f.origin = CGPoint(x: container.width - f.width - i, y: container.height - f.height - i)
        }
        withAnimation(.snappy) { frame = clamp(f) }
        save()
    }

    private func grow(_ k: CGFloat) {
        var f = frame
        f.size = CGSize(width: f.width * k, height: f.height * k)
        withAnimation(.snappy) { frame = clamp(f) }
        save()
    }

    /// Kept inside the space, at least the smallest size and at most the space less a margin.
    private func clamp(_ r: CGRect) -> CGRect {
        let i = Self.inset
        let maxW = max(Self.minSize.width, container.width - i * 2), maxH = max(Self.minSize.height, container.height - i * 2)
        var f = r
        f.size.width = min(maxW, max(Self.minSize.width, f.width))
        f.size.height = min(maxH, max(Self.minSize.height, f.height))
        f.origin.x = min(max(i, f.minX), container.width - f.width - i)
        f.origin.y = min(max(i, f.minY), container.height - f.height - i)
        return f
    }

    /// Near an edge (within 12 pt): flush with it.
    private func snapped(_ r: CGRect) -> CGRect {
        var f = r
        let i = Self.inset
        if f.minX - i < Self.snap { f.origin.x = i }
        if container.width - i - f.maxX < Self.snap { f.origin.x = container.width - i - f.width }
        if f.minY - i < Self.snap { f.origin.y = i }
        if container.height - i - f.maxY < Self.snap { f.origin.y = container.height - i - f.height }
        return clamp(f)
    }

    // MARK: Remembering

    private func load() {
        guard container.width > 0, container.height > 0 else { return }
        if let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 4 {
            frame = clamp(CGRect(x: a[0] * container.width, y: a[1] * container.height, width: a[2] * container.width, height: a[3] * container.height))
        } else {
            // First time: the right side, a third of the width, most of the height.
            let w = min(400, max(Self.minSize.width, container.width * 0.34)), h = min(620, container.height * 0.78)
            frame = clamp(CGRect(x: container.width - w - Self.inset, y: Self.inset + 8, width: w, height: h))
        }
    }

    private func save() {
        guard container.width > 0, container.height > 0 else { return }
        UserDefaults.standard.set([frame.minX / container.width, frame.minY / container.height, frame.width / container.width, frame.height / container.height], forKey: key)
    }
}

#if os(iOS)
/// Tells when an Apple Pencil (not a trackpad pointer) hovers over the view it's behind.
struct PencilHoverDetector: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.changed = changed }
    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    @MainActor
    final class Coordinator: NSObject {
        var changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed }

        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            // Only the Pencil reports a height above the screen; a pointer's is 0.
            var pencil = false
            if #available(iOS 16.1, *) { pencil = g.zOffset > 0 }
            switch g.state {
            case .began, .changed: if pencil { changed(true) }
            default: break
            }
        }
    }
}
#endif
