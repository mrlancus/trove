import SwiftUI
import TroveCore

/// "New sketch" asks for its pages first (docs/plans/sketch-2-plan.md T6): name, notebook or
/// whiteboard, paper, size, page colour. Everything starts at what you chose last time, so Create
/// (or Return) makes your usual sketch in one tap. "Ask every time" off skips this sheet.
struct NewSketchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: String?
    @State private var choice = NewSketchChoice.load(UserDefaults.standard.data(forKey: "sketch.new"))
    @State private var name = ""
    @FocusState private var naming: Bool

    private static let papers: [InkPaper] = [.blank, .lined, .narrow, .wide, .grid, .smallgrid, .dotted, .cornell, .todo, .music, .isometric, .calligraphy]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .focused($naming)
                        .onSubmit(create)
                    Picker("Kind", selection: $choice.kind) {
                        Text("Notebook").tag(NewSketchChoice.Kind.notebook)
                        Text("Whiteboard").tag(NewSketchChoice.Kind.whiteboard)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Paper") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.papers, id: \.self) { paper in
                                Button { choice.paper = paper } label: { thumbnail(paper) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(paper.title)
                                    .accessibilityAddTraits(choice.paper == paper ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if choice.kind == .notebook {
                    Section("Page size") {
                        Picker("Size", selection: $choice.size) {
                            ForEach(InkPageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Orientation", selection: $choice.landscape) {
                            Text("Portrait").tag(false)
                            Text("Landscape").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Page colour") {
                    HStack(spacing: 14) {
                        ForEach(NewSketchChoice.colours, id: \.name) { c in
                            Button { choice.color = c.hex } label: {
                                Circle().fill(Color(inkHex: c.hex ?? "#ffffff"))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(choice.color == c.hex ? Color.accentColor : .gray.opacity(0.4), lineWidth: choice.color == c.hex ? 3 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                        }
                    }
                }
                Section {
                    Toggle("Ask every time", isOn: $choice.ask)
                } footer: {
                    Text("Off: New sketch makes one like this straight away. Also in Settings → Sketch.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New sketch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).keyboardShortcut(.defaultAction) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let c = choice, title = name.trimmingCharacters(in: .whitespacesAndNewlines), folder = folder
        dismiss()
        Task { await model.createSketch(c, title: title, in: folder) }
    }

    /// A small page with its paper drawn on it.
    private func thumbnail(_ paper: InkPaper) -> some View {
        let on = choice.paper == paper
        return VStack(spacing: 4) {
            Canvas { ctx, size in
                ctx.withCGContext { cg in
                    let scale = size.width / 200
                    cg.scaleBy(x: scale, y: scale)
                    InkRenderer.drawPaper(paper, size: CGSize(width: 200, height: 260), color: choice.color, in: cg)
                }
            }
            .frame(width: 54, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.accentColor : .gray.opacity(0.35), lineWidth: on ? 2.5 : 1))
            Text(paper.title).font(.caption2).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
        }
        .frame(width: 64)
    }
}
