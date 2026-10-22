import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Trove's colours, from the app icon: a warm orange running from amber at the top to coral below.
enum Brand {
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.25)
    static let coral = Color(red: 1.0, green: 0.38, blue: 0.24)
    static let orange = Color(red: 1.0, green: 0.53, blue: 0.24)
    static var gradient: LinearGradient { LinearGradient(colors: [amber, coral], startPoint: .top, endPoint: .bottom) }
}

/// The logo, drawn: a box with its lid and the latch in the middle. `open` (0…1, animatable) lifts
/// the lid and tips it back, latch and all, so things can go in (Import) or be looked for (Ask).
struct TroveMark: View, Animatable {
    var open: Double = 0
    /// The colour of the box; the latch is cut out of it.
    var fill: AnyShapeStyle = AnyShapeStyle(Brand.gradient)

    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    // In the icon's units (a 1024 canvas, cropped to the box): lid, body and latch.
    static let size = CGSize(width: 615, height: 575)
    static let lid = CGRect(x: 0, y: 0, width: 615, height: 133)
    static let body = CGRect(x: 20, y: 163, width: 575, height: 412)
    static let latch = CGRect(x: 245, y: 113, width: 123, height: 163)

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / Self.size.width, g.size.height / Self.size.height)
            let lift = -150 * open * s, tilt = Angle.degrees(-14 * open)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 70 * s, style: .continuous)
                    .frame(width: Self.body.width * s, height: Self.body.height * s)
                    .offset(x: Self.body.minX * s, y: Self.body.minY * s)
                // The lid and the latch hanging from it move together.
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 60 * s, style: .continuous)
                        .frame(width: Self.lid.width * s, height: Self.lid.height * s)
                    RoundedRectangle(cornerRadius: 30 * s, style: .continuous)
                        .frame(width: Self.latch.width * s, height: Self.latch.height * s)
                        .offset(x: Self.latch.minX * s, y: Self.latch.minY * s)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .rotationEffect(tilt, anchor: .bottomLeading)
                .offset(y: lift)
                // The latch is cut through the body too while the lid is down; the hole closes as it lifts.
                RoundedRectangle(cornerRadius: 30 * s, style: .continuous)
                    .frame(width: Self.latch.width * s, height: Self.latch.height * s)
                    .offset(x: Self.latch.minX * s, y: Self.latch.minY * s)
                    .opacity(max(0, 1 - open * 3))
                    .blendMode(.destinationOut)
            }
            .frame(width: Self.size.width * s, height: Self.size.height * s, alignment: .topLeading)
            .foregroundStyle(fill)
            .compositingGroup()
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
extension TroveMark {
    /// The menu bar icon: the same box as a template image (macOS tints it), 18 points high.
    @MainActor static let menuBarImage: NSImage = {
        let side = 18.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let s = 16 / size.width, dx = (side - size.width * s) / 2, dy = (side - size.height * s) / 2
            func rect(_ r: CGRect) -> NSRect { NSRect(x: dx + r.minX * s, y: dy + r.minY * s, width: r.width * s, height: r.height * s) }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect(lid), xRadius: 60 * s, yRadius: 60 * s).fill()
            NSBezierPath(roundedRect: rect(body), xRadius: 70 * s, yRadius: 70 * s).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: rect(latch), xRadius: 30 * s, yRadius: 30 * s).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
#endif

/// Things dropping into the box: Import shows each arrival falling in while the lid is open, then
/// the lid closes when it's done.
struct BoxFilling: View {
    /// Open while things are arriving.
    let open: Bool
    /// Changes each time something arrives (its symbol falls in).
    let arrival: Arrival?
    var size: CGFloat = 150

    struct Arrival: Equatable {
        let id: String
        let symbol: String
    }

    @State private var falling: [Drop] = []

    private struct Drop: Identifiable {
        let id: String
        let symbol: String
        let x: CGFloat
        let spin: Double
    }

    var body: some View {
        ZStack {
            // Behind the box's front, so they vanish into it.
            ForEach(falling) { drop in
                FallingChip(symbol: drop.symbol, x: drop.x * size, spin: drop.spin, size: size)
            }
            TroveMark(open: open ? 1 : 0)
                .shadow(color: Brand.coral.opacity(0.25), radius: 16, y: 8)
        }
        .frame(width: size, height: size * 1.25, alignment: .bottom)
        .animation(.spring(duration: 0.55, bounce: open ? 0.25 : 0.45), value: open)
        .onChange(of: arrival) { _, new in
            guard let new, open else { return }
            let drop = Drop(id: new.id, symbol: new.symbol, x: .random(in: -0.18...0.18), spin: .random(in: -25...25))
            falling.append(drop)
            if falling.count > 6 { falling.removeFirst(falling.count - 6) }
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                falling.removeAll { $0.id == drop.id }
            }
        }
    }
}

/// One thing falling from above into the open box.
private struct FallingChip: View {
    let symbol: String
    let x: CGFloat
    let spin: Double
    let size: CGFloat
    @State private var down = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.16, weight: .semibold))
            .foregroundStyle(Brand.coral)
            .frame(width: size * 0.3, height: size * 0.3)
            .background(.background, in: RoundedRectangle(cornerRadius: size * 0.07, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .rotationEffect(.degrees(down ? spin : -spin))
            .scaleEffect(down ? 0.75 : 1)
            // From the top of the frame to inside the box, where its front hides it.
            .offset(x: x, y: down ? size * 0.14 : -size * 0.6)
            .onAppear { withAnimation(.easeIn(duration: 0.7)) { down = true } }
    }
}

/// Ask looking through your Trove: the lid lifts and what it searches or opens rises out of the
/// box, one thing per step. Calm while waiting (the lid barely open), nothing looping on its own.
struct BoxLooking: View {
    /// How open the lid is (0 shut … 1 wide).
    let open: Double
    /// Changes with each step (its symbol rises out).
    let step: BoxFilling.Arrival?
    var size: CGFloat = 44

    @State private var rising: [BoxFilling.Arrival] = []

    var body: some View {
        ZStack {
            ForEach(rising, id: \.id) { r in RisingChip(symbol: r.symbol, size: size) }
            TroveMark(open: open)
        }
        .frame(width: size, height: size * 1.3, alignment: .bottom)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: open)
        .onChange(of: step) { _, new in
            guard let new else { return }
            rising.append(new)
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                rising.removeAll { $0.id == new.id }
            }
        }
    }
}

private struct RisingChip: View {
    let symbol: String
    let size: CGFloat
    @State private var up = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.3, weight: .semibold))
            .foregroundStyle(Brand.coral)
            .offset(y: up ? -size * 0.75 : size * 0.1)
            .scaleEffect(up ? 1 : 0.6)
            .opacity(up ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.0)) { up = true } }
    }
}
