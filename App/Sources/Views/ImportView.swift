import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

/// The Import screen: one big drop zone that takes anything (files, folders, zips, exports from
/// other apps), then shows things arriving as they're added.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showImporter) private var showImporter
    @Environment(\.pickFiles) private var pickFiles
    @State private var targeted = false

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

                DropZone(targeted: targeted, run: model.importRun, choose: showImporter)
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
                PasteImportCard(choose: choosePaste)
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Import")
    }

    /// Paste's db.sqlite (and its -wal), through the window's one file picker (`ImportPickers`).
    private func choosePaste() {
        let model = model
        pickFiles(FilePick(types: [.item], multiple: true) { urls in
            guard let db = urls.first(where: { !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent.hasSuffix("-shm") }) else { return }
            Task { await model.importFromPaste(db: db, wal: urls.first { $0.lastPathComponent.hasSuffix("-wal") }) }
        })
    }
}

/// The target: a gradient outline (still, so the screen isn't redrawn all the time; that made
/// scrolling stutter on Intel Macs), lit up while something hovers over it, a progress ring while
/// importing, and a burst when it's done.
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
        .shadow(color: .orange.opacity(0.35), radius: targeted ? 24 : 0)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: targeted)
        .animation(.spring(duration: 0.5), value: run?.finished)
        .animation(.spring(duration: 0.5), value: run == nil)
    }

    private var border: some View {
        shape.strokeBorder(AngularGradient(colors: brand, center: .center, angle: .degrees(targeted ? 90 : 0)),
                           style: StrokeStyle(lineWidth: targeted ? 3 : 2, dash: targeted || run != nil ? [] : [10, 7]))
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
            #if os(iOS)
            // Files (iCloud Drive, On My iPad, other apps' storage), Photos, or the camera.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { pickButtons }
                VStack(spacing: 10) { pickButtons }
            }
            .controlSize(.large)
            #else
            Button(action: choose) { Label("Choose files or folders…", systemImage: "folder") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            #endif
        }
        .multilineTextAlignment(.center)
    }

    #if os(iOS)
    @Environment(\.pickPhotos) private var pickPhotos
    @Environment(\.scanDocument) private var scanDocument

    @ViewBuilder private var pickButtons: some View {
        Button(action: choose) { Label("Files…", systemImage: "folder") }
            .buttonStyle(.borderedProminent)
        Button(action: pickPhotos) { Label("Photos…", systemImage: "photo.on.rectangle") }
            .buttonStyle(.borderedProminent)
        Button(action: scanDocument) { Label("Scan", systemImage: "doc.viewfinder") }
            .buttonStyle(.bordered)
            .disabled(!VNDocumentCameraViewController.isSupported)
    }
    #endif

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
            Text("\(run.done) of \(run.total) \(run.unit)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
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
                        let destination = run.destination
                        model.dismissImport()
                        model.selection = destination
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

/// "Everything from Paste": finds Paste's database on this Mac (App Store, direct download or
/// Setapp copy) and brings its whole history and pinboards into the clipboard. On iPhone and iPad
/// (or if it isn't found) the files are picked instead.
private struct PasteImportCard: View {
    @Environment(AppModel.self) private var model
    let choose: () -> Void
    @State private var found: (db: URL, wal: URL?)?
    @State private var looked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything from Paste").font(.headline)
                    Text("Your whole Paste history and pinboards go into Trove's Clipboard, with when each was copied and the app it came from. Pinboards become tags. Passwords and codes are left out.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                #if os(macOS)
                if let found {
                    Button { Task { await model.importFromPaste(db: found.db, wal: found.wal) } } label: {
                        Label("Import from Paste", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.importingPaste)
                    Button("Choose the file…", action: choose).buttonStyle(.bordered)
                } else {
                    Button("Choose Paste's db.sqlite…", action: choose).buttonStyle(.borderedProminent)
                }
                #else
                Button("Choose Paste's db.sqlite…", action: choose).buttonStyle(.borderedProminent)
                #endif
                if model.importingPaste { ProgressView().controlSize(.small) }
            }
            if let status = model.pasteImportStatus {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                #if os(macOS)
                Text(found.map { "Found Paste's history in \($0.db.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))." }
                     ?? (looked ? "Paste's history wasn't found on this Mac. Pick db.sqlite (and db.sqlite-wal) from its folder: in the file picker press ⇧⌘G and type ~/Library/Application Support or ~/Library/Containers, then the folder starting with com.wiheads.paste." : "Looking for Paste…"))
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Copy db.sqlite and db.sqlite-wal from Paste's folder on your Mac to iCloud Drive, then pick both here.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
        #if os(macOS)
        .task {
            let candidates = await Task.detached(priority: .utility) { PasteImport.candidates() }.value
            found = candidates.first
            looked = true
        }
        #endif
    }
}
