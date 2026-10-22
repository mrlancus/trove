import SwiftUI
import TroveCore

// Preset colours and sizes, like GoodNotes: tap one to use it; tap the one in use again (or hold
// any) to change it for good; + adds a colour. They follow you on every device (`settings.ink`).

/// Points to millimetres (a page point is 1/72 inch).
enum InkSizeUnit {
    static let mmPerPoint = 25.4 / 72
    static let step = 0.05

    static func mm(_ points: Double) -> Double { ((points * mmPerPoint) / step).rounded() * step }
    static func points(_ mm: Double) -> Double { mm / mmPerPoint }
    static func label(_ points: Double, tool: InkEditorTool) -> String {
        if tool == .text { return "\(Int(points.rounded())) pt" }
        return String(format: "%.2f mm", mm(points))
    }
}

extension InkEditorModel {
    /// What a tool's size can be, in page points.
    func sizeRange(_ t: InkEditorTool) -> ClosedRange<Double> {
        if t == .eraser && eraserMode == .precise { return 0.5...12 }
        if t == .text { return 6...72 }
        return InkSizeUnit.points(InkSizeUnit.step)...60
    }
}

/// The chosen tool's three sizes.
struct InkSizePresets: View {
    let editor: InkEditorModel
    @State private var editing: Int?

    var body: some View {
        let sizes = editor.presetSizes
        HStack(spacing: 4) {
            ForEach(Array(sizes.enumerated()), id: \.offset) { i, w in
                let on = abs(editor.width - w) < 0.01
                Button { if on { editing = i } else { editor.width = w } } label: {
                    Circle()
                        .fill(editor.tool == .eraser ? Color.secondary : Color(inkHex: editor.color))
                        .frame(width: CGFloat(6 + i * 5), height: CGFloat(6 + i * 5))
                        .frame(width: 30, height: 30)
                        .background(on ? Color.accentColor.opacity(0.16) : .clear, in: Circle())
                        .inkTapArea()
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in editing = i })
                .accessibilityLabel("\(["Thin", "Medium", "Thick"][min(2, i)]), \(InkSizeUnit.label(w, tool: editor.tool))")
                .accessibilityHint("Tap again to change this size")
                .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 { editing = nil } })) {
                    InkSizeEditor(editor: editor, index: i, start: w) { editing = nil }
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }
}

/// Sets one of the three sizes for good: a bar in steps of 0.05 mm (points for text).
struct InkSizeEditor: View {
    let editor: InkEditorModel
    let index: Int
    let close: () -> Void
    @State private var value: Double

    init(editor: InkEditorModel, index: Int, start: Double, close: @escaping () -> Void) {
        self.editor = editor
        self.index = index
        self.close = close
        _value = State(initialValue: editor.tool == .text ? start.rounded() : InkSizeUnit.mm(start))
    }

    private var isText: Bool { editor.tool == .text }
    private var range: ClosedRange<Double> {
        let r = editor.sizeRange(editor.tool)
        if isText { return r }
        return max(InkSizeUnit.step, InkSizeUnit.mm(r.lowerBound))...InkSizeUnit.mm(r.upperBound)
    }
    private var step: Double { isText ? 1 : InkSizeUnit.step }
    private var points: Double { isText ? value : InkSizeUnit.points(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(["Thin", "Medium", "Thick"][min(2, index)]) \(editor.tool.label.lowercased())").font(.headline)
            // What the line looks like at this size (screen size at 100 %).
            Capsule()
                .fill(editor.tool == .eraser ? Color.secondary : Color(inkHex: editor.color))
                .frame(width: 180, height: max(1, min(40, points)))
                .frame(maxWidth: .infinity, minHeight: 44)
            HStack(spacing: 10) {
                Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: 30, height: 30).inkTapArea() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Thinner")
                Slider(value: $value, in: range, step: step)
                Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: 30, height: 30).inkTapArea() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Thicker")
            }
            HStack {
                Text(isText ? "\(Int(value)) pt" : String(format: "%.2f mm", value))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer()
                Button("Set") {
                    editor.setPresetSize(index, to: points)
                    close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// The chosen tool's preset colours, then + for a new one.
struct InkColorPresets: View {
    let editor: InkEditorModel
    @State private var editing: Int?
    @State private var adding = false

    var body: some View {
        let colours = editor.presetColors(for: editor.tool)
        HStack(spacing: 6) {
            ForEach(Array(colours.enumerated()), id: \.element) { i, c in
                let on = editor.color == c
                Button { if on { editing = i } else { editor.color = c } } label: {
                    Circle().fill(Color(inkHex: c)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .overlay(Circle().strokeBorder(on ? Color.accentColor : .gray.opacity(0.4), lineWidth: on ? 2 : 1).padding(-2))
                        .frame(width: 30, height: 32)
                        .inkTapArea()
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in editing = i })
                .accessibilityLabel("Colour \(c)")
                .accessibilityHint("Tap again to change this colour")
                .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 { editing = nil } })) {
                    InkColorEditor(title: "Change colour", start: c, canDelete: colours.count > 1, done: { picked in
                        editor.replacePresetColor(at: i, with: picked)
                        editing = nil
                    }, delete: {
                        editor.removePresetColor(at: i)
                        editing = nil
                    })
                    .presentationCompactAdaptation(.popover)
                }
            }
            Button { adding = true } label: {
                Image(systemName: "plus").font(.callout.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: 30, height: 32)
                    .inkTapArea()
            }
            .buttonStyle(.plain)
            .help("Add a colour (on every device)")
            .accessibilityLabel("Add a colour")
            .popover(isPresented: $adding) {
                InkColorEditor(title: "New colour", start: editor.color, canDelete: false, done: { picked in
                    editor.addPresetColor(picked)
                    adding = false
                }, delete: {})
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// Picking a colour: a grid of colours, any colour from the system's picker, or its hex code.
struct InkColorEditor: View {
    let title: String
    let canDelete: Bool
    let done: (String) -> Void
    let delete: () -> Void
    @State private var hex: String
    @State private var code: String

    init(title: String, start: String, canDelete: Bool, done: @escaping (String) -> Void, delete: @escaping () -> Void) {
        self.title = title
        self.canDelete = canDelete
        self.done = done
        self.delete = delete
        _hex = State(initialValue: start.lowercased())
        _code = State(initialValue: start.lowercased())
    }

    /// Twelve hues, light to dark, and a row of greys.
    static let grid: [String] = {
        var out: [String] = []
        let shades: [(s: Double, b: Double)] = [(0.25, 1), (0.5, 1), (0.8, 0.95), (1, 0.8), (1, 0.55)]
        for shade in shades {
            for i in 0..<12 { out.append(hsb(Double(i) / 12, shade.s, shade.b)) }
        }
        for i in 0..<12 {
            let v = Int((1 - Double(i) / 11) * 255)
            out.append(String(format: "#%02x%02x%02x", v, v, v))
        }
        return out
    }()

    static func hsb(_ h: Double, _ s: Double, _ b: Double) -> String {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double)
        switch i {
        case 0: rgb = (b, t, p)
        case 1: rgb = (q, b, p)
        case 2: rgb = (p, b, t)
        case 3: rgb = (p, q, b)
        case 4: rgb = (t, p, b)
        default: rgb = (b, p, q)
        }
        return String(format: "#%02x%02x%02x", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Circle().fill(Color(inkHex: hex)).frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.gray.opacity(0.4)))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 12), spacing: 4) {
                ForEach(Self.grid, id: \.self) { c in
                    Button { pick(c) } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(inkHex: c)).frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hex == c ? Color.accentColor : .gray.opacity(0.25), lineWidth: hex == c ? 2.5 : 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(c)")
                }
            }
            HStack(spacing: 12) {
                ColorPicker("Any colour", selection: Binding(get: { Color(inkHex: hex) }, set: { pick($0.inkHex) }), supportsOpacity: false)
                    .fixedSize()
                Spacer()
                TextField("#rrggbb", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 96)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: code) { _, typed in
                        let c = (typed.hasPrefix("#") ? typed : "#" + typed).lowercased()
                        if InkSettings.isHex(c) { hex = c }
                    }
            }
            HStack {
                if canDelete {
                    Button("Delete", role: .destructive) { delete() }
                }
                Spacer()
                Button(canDelete ? "Done" : "Add") { done(hex) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func pick(_ c: String) {
        hex = c.lowercased()
        code = hex
    }
}

// MARK: The squeeze palette's arcs

/// A band of a ring round `centre` from `from` to `to` degrees (0 = right, 90 = up), with round ends.
struct InkArcBand: Shape {
    var centre: CGPoint
    var radius: CGFloat
    var width: CGFloat
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: centre, radius: radius, startAngle: .degrees(-from), endAngle: .degrees(-to), clockwise: false)
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

/// Items along an arc that turns when dragged along it, so a long list (every tool, all your
/// colours) goes round under the finger or Pencil. Items fade out at the arc's ends.
struct InkArcDial<Item: Hashable, Content: View>: View {
    let items: [Item]
    let centre: CGPoint
    let radius: CGFloat
    let band: CGFloat
    /// The arc's ends in degrees, `from` (left) above `to` (right).
    let from: Double
    let to: Double
    /// Degrees between items when they don't all fit.
    let step: Double
    let selected: Item?
    @ViewBuilder let content: (Item) -> Content
    @State private var offset: Double = 0
    @State private var dragStart: (angle: Double, offset: Double)?

    private var span: Double { from - to }
    private var spacing: Double {
        guard items.count > 1 else { return 0 }
        let n = Double(items.count - 1)
        return n * step <= span ? span / n : step
    }
    private var maxOffset: Double { max(0, Double(max(0, items.count - 1)) * spacing - span) }

    private func angle(_ i: Int) -> Double {
        if items.count == 1 { return (from + to) / 2 }
        return from - Double(i) * spacing + offset
    }

    /// 1 inside the arc, fading to 0 half a step past either end.
    private func opacity(_ a: Double) -> Double {
        let fade = max(1, spacing / 2)
        if a > from { return max(0, 1 - (a - from) / fade) }
        if a < to { return max(0, 1 - (to - a) / fade) }
        return 1
    }

    private func point(_ a: Double) -> CGPoint {
        let r = a * .pi / 180
        return CGPoint(x: centre.x + radius * cos(r), y: centre.y - radius * sin(r))
    }

    private func degrees(at p: CGPoint) -> Double {
        atan2(Double(centre.y - p.y), Double(p.x - centre.x)) * 180 / .pi
    }

    var body: some View {
        let shape = InkArcBand(centre: centre, radius: radius, width: band, from: from, to: to)
        ZStack {
            shape.fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                let a = angle(i)
                let o = opacity(a)
                if o > 0 {
                    content(item)
                        .position(point(a))
                        .opacity(o)
                        .allowsHitTesting(o > 0.6)
                }
            }
        }
        .contentShape(shape)
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { g in
                    let now = degrees(at: g.location)
                    if dragStart == nil { dragStart = (degrees(at: g.startLocation), offset) }
                    guard let start = dragStart else { return }
                    offset = min(maxOffset, max(0, start.offset + now - start.angle))
                }
                .onEnded { _ in
                    dragStart = nil
                    guard spacing > 0 else { return }
                    let snapped = (offset / spacing).rounded() * spacing
                    withAnimation(.snappy(duration: 0.2)) { offset = min(maxOffset, max(0, snapped)) }
                }
        )
        .onAppear { showSelected() }
    }

    /// Turns the arc so the selected item is in view.
    private func showSelected() {
        guard let selected, let i = items.firstIndex(of: selected), maxOffset > 0 else { return }
        let a = from - Double(i) * spacing
        guard a < to || a > from else { return }
        offset = min(maxOffset, max(0, Double(i) * spacing - span / 2))
    }
}
