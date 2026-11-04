import SwiftUI
import TroveCore

/// Home (docs/prompts/practice-space-home.md: "it shouldn't just immediately be notes"): where the
/// app opens. A greeting, four things to start, three numbers, Develop's next step, and what you were
/// last working on. Calm, one column, nothing you have to read.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var develop = DevelopModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl + 4) {
                greeting
                actions
                stats
                if !develop.courses.isEmpty || !develop.attempts.isEmpty { developCard }
                shelf("Jump back in", items: recent)
                shelf("Pinned", items: pinned)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await develop.start(model)
            Diagnostics.shared.ready("Home")
        }
        .perfWorkflow("Home")
    }

    // MARK: Parts

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(Self.hello(Date.now)).font(.largeTitle.weight(.bold))
        }
    }

    static func hello(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            tile("New note", symbol: "square.and.pencil", tint: .blue) { Task { await model.newNote() } }
            tile("New sketch", symbol: "pencil.tip.crop.circle", tint: .purple) { Task { await model.newSketch() } }
            tile("Practise", symbol: "graduationcap.fill", tint: Theme.accent) {
                model.selection = .develop
                if !develop.practisable.isEmpty { develop.startSession(count: 5) }
            }
            tile("Import", symbol: "square.and.arrow.down.on.square", tint: .teal) { model.selection = .importer }
        }
    }

    private func tile(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                Text(title).font(.headline).foregroundStyle(.primary)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .card(cornerRadius: Theme.Radius.large)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        let saved = model.items.filter { $0.createdAt > weekAgo }.count
        let made = model.items.filter { $0.kind == .note || $0.kind == .sketch }.count
        let s = develop.stats
        return HStack(spacing: Theme.Space.m) {
            stat("\(saved)", "saved this week", symbol: "tray.and.arrow.down")
            stat("\(made)", "notes and sketches", symbol: "doc.text")
            stat("\(s.streak)", s.streak == 1 ? "day practising" : "days practising", symbol: "flame")
        }
    }

    private func stat(_ value: String, _ label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.callout).foregroundStyle(Theme.accent)
            Text(value).font(.title.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    /// Develop's next step, small: the whole of it is one tap away.
    private var developCard: some View {
        Button { model.selection = .develop } label: {
            HStack(spacing: Theme.Space.l) {
                ScoreRing(score: develop.stats.recentAverage, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(develop.next?.skill.name ?? "Practise your papers").font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(develop.stats.thisWeek) question\(develop.stats.thisWeek == 1 ? "" : "s") this week").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.l)
            .card(cornerRadius: Theme.Radius.large)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
        .buttonStyle(.plain)
    }

    private var recent: [Item] {
        Array(model.items.lazy.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }.prefix(10))
    }

    private var pinned: [Item] { Array(model.items.filter(\.isPinned).prefix(10)) }

    @ViewBuilder private func shelf(_ title: String, items: [Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(title).font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(items) { item in
                            Button { open(item) } label: { ItemCard(item: item).frame(width: 200) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Opens an item where the library shows it (the iPhone pushes it onto the Library tab).
    private func open(_ item: Item) {
        #if os(macOS)
        model.selection = .smart(.recent)
        #else
        if DeviceInfo.isPad { model.selection = .smart(.recent) }
        #endif
        model.selectedItemID = item.id
    }
}
