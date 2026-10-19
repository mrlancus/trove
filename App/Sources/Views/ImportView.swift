import SwiftUI
import TroveCore
import UniformTypeIdentifiers

/// The Import screen: one big drop zone that takes anything (files, folders, zips, exports from
/// other apps), then shows things arriving as they're added.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var choosing = false

    private struct Format: Identifiable {
        let symbol: String
        let title: String
        var id: String { title }
    }

    private let formats: [Format] = [
        .init(symbol: "doc.zipper", title: "Zip archives"), .init(symbol: "square.stack.3d.up", title: "Notion & Obsidian exports"),
        .init(symbol: "bookmark", title: "Browser bookmarks"), .init(symbol: "highlighter", title: "Kindle highlights"),
        .init(symbol: "tablecells", title: "Pocket & Raindrop CSV"), .init(symbol: "quote.bubble", title: "Readwise"),
        .init(symbol: "doc.richtext", title: "PDFs & documents"), .init(symbol: "photo", title: "Photos & screenshots"),
        .init(symbol: "folder", title: "Whole folders"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("Bring everything in").font(.largeTitle.bold())
                    Text("Drop files, folders or whole exports. Zips are opened for you, and nothing leaves your devices unencrypted.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                DropZone(targeted: targeted, run: model.importRun, choose: { choosing = true })
                    .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted) { DropHandler.handle($0, model: model) }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(formats) { f in
                        Label(f.title, systemImage: f.symbol)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .card(cornerRadius: 12)
                    }
                }
                Text("You can also drop things anywhere on the Trove window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Import")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls) } }
        }
    }
}

/// The animated target: a slowly turning gradient outline while idle, a lit-up one while something
/// hovers over it, a progress ring while importing, and a burst when it's done.
private struct DropZone: View {
    @Environment(AppModel.self) private var model
    let targeted: Bool
    let run: AppModel.ImportRun?
    let choose: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
    private let brand: [Color] = [.orange, .pink, .purple, .orange]

    var body: some View {
        ZStack {
            if let run {
                if run.finished { finished(run).transition(.scale(scale: 0.8).combined(with: .opacity)) }
                else { progress(run).transition(.opacity) }
            } else {
                idle.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(28)
        .background {
            shape.fill(RadialGradient(colors: [.orange.opacity(targeted ? 0.22 : 0.10), .clear], center: .center, startRadius: 10, endRadius: 420))
        }
        .overlay { border }
        .scaleEffect(targeted ? 1.02 : 1)
        .shadow(color: .orange.opacity(targeted ? 0.35 : 0), radius: 24)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: targeted)
        .animation(.spring(duration: 0.5), value: run?.finished)
        .animation(.spring(duration: 0.5), value: run == nil)
    }

    private var border: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360
            shape.strokeBorder(AngularGradient(colors: brand, center: .center, angle: .degrees(turn)),
                               style: StrokeStyle(lineWidth: targeted ? 3 : 2, dash: targeted || run != nil ? [] : [10, 7]))
        }
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                .symbolEffect(.bounce, value: targeted)
                .contentTransition(.symbolEffect(.replace))
            Text(targeted ? "Let go to add it" : "Drop anything here").font(.title2.weight(.semibold))
            Text("or").foregroundStyle(.secondary)
            Button(action: choose) { Label("Choose files or folders…", systemImage: "folder") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }

    private func progress(_ run: AppModel.ImportRun) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, run.fraction))
                    .stroke(AngularGradient(colors: brand, center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.4), value: run.fraction)
                VStack(spacing: 2) {
                    Text("\(run.added)").font(.system(size: 34, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text("added").font(.caption).foregroundStyle(.secondary)
                }
                .animation(.spring, value: run.added)
            }
            .frame(width: 130, height: 130)
            Text(run.current.map { "Reading \($0)…" } ?? "Finishing up…")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("\(run.done) of \(run.total) files").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            arrivals(run)
        }
    }

    private func finished(_ run: AppModel.ImportRun) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Burst()
                Image(systemName: run.added > 0 ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(run.added > 0 ? Color.green : Color.orange)
                    .symbolEffect(.bounce, value: run.finished)
            }
            .frame(height: 110)
            Text(run.added == 0 ? "Nothing new to add" : run.added == 1 ? "Added 1 thing" : "Added \(run.added) things")
                .font(.title2.weight(.semibold))
            if run.added == 0 {
                Text("Everything here was already in Trove, or the files couldn't be read.").font(.callout).foregroundStyle(.secondary)
            }
            arrivals(run)
            HStack {
                if run.added > 0 {
                    Button("Show them") {
                        model.dismissImport()
                        model.selection = .source(.import)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Import more") { model.dismissImport() }.buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }

    /// The latest arrivals, sliding in from the top.
    private func arrivals(_ run: AppModel.ImportRun) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(run.recent.prefix(5).enumerated()), id: \.element.id) { i, arrival in
                Label(arrival.label, systemImage: "plus.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(1 - Double(i) * 0.17))
                    .lineLimit(1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: run.recent)
        .frame(maxWidth: 420)
    }
}

/// A ring of dots flying outward once, for the "done" moment.
private struct Burst: View {
    @State private var out = false
    private let colors: [Color] = [.orange, .pink, .purple, .yellow, .mint, .blue]

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 8, height: 8)
                    .offset(x: out ? cos(angle) * 70 : 0, y: out ? sin(angle) * 70 : 0)
                    .opacity(out ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { out = true } }
    }
}
