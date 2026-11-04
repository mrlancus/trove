import PhotosUI
import SwiftUI
import TroveCore
import UniformTypeIdentifiers

/// A subject's symbol and colour, so courses are easy to tell apart at a glance.
enum SubjectStyle {
    static func symbol(_ subject: String) -> (name: String, color: Color) {
        let s = subject.lowercased()
        let table: [([String], String, Color)] = [
            (["physics"], "atom", .indigo),
            (["chemistry"], "flask", .teal),
            (["biology", "environmental", "agriculture"], "leaf", .green),
            (["science", "geology"], "testtube.2", .mint),
            (["math", "statistic"], "function", .blue),
            (["computer", "ict", "information"], "laptopcomputer", .cyan),
            (["english", "literature", "classical", "latin", "greek"], "book", .brown),
            (["french", "german", "spanish", "italian", "chinese", "mandarin", "urdu", "bengali", "panjabi", "polish", "hebrew",
              "arabic", "russian", "japanese", "welsh", "portuguese", "language"], "character.bubble", .pink),
            (["history", "ancient"], "building.columns", .orange),
            (["geography"], "globe.europe.africa", .green),
            (["economics", "business", "accounting", "enterprise"], "chart.line.uptrend.xyaxis", .purple),
            (["psychology", "sociology", "criminology"], "brain.head.profile", .purple),
            (["religious", "philosophy", "ethics"], "sparkles", .yellow),
            (["art", "design", "photography", "media", "film", "textile"], "paintpalette", .red),
            (["music"], "music.note", .pink),
            (["drama", "dance", "theatre", "performing"], "theatermasks", .orange),
            (["physical education", "sport"], "figure.run", .red),
            (["law", "politics", "government", "citizenship"], "scalemass", .gray),
            (["food", "nutrition", "hospitality"], "fork.knife", .orange),
            (["engineering", "electronics", "technology"], "gearshape.2", .gray),
        ]
        for (words, name, color) in table where words.contains(where: s.contains) { return (name, color) }
        return ("book.closed", Theme.accent)
    }
}

/// A round subject badge.
struct SubjectBadge: View {
    let subject: String
    var size: CGFloat = 40
    var body: some View {
        let style = SubjectStyle.symbol(subject)
        Image(systemName: style.name)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.color.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// "Your courses" on Develop's home: each course with how much of it is on this device.
struct CoursesCard: View {
    @Bindable var develop: DevelopModel
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your courses").font(.headline)
                Spacer()
                Button { adding = true } label: { Label("Add a course", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if develop.courses.isEmpty {
                Button { adding = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "graduationcap.fill").font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose what you're studying").font(.subheadline.weight(.semibold))
                            Text("GCSE, IGCSE and A-level from AQA, OCR, WJEC, Eduqas and Cambridge. Past papers come straight from the board's website.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.medium))
                }
                .buttonStyle(.plain)
            }
            ForEach(develop.courses) { course in
                let spec = develop.courseSpecs.first { $0.id == course.spec }
                NavigationLink {
                    CourseView(develop: develop, course: course)
                } label: {
                    CourseRow(develop: develop, course: course, spec: spec)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove course", systemImage: "minus.circle", role: .destructive) { Task { await develop.removeCourse(course) } }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .sheet(isPresented: $adding) { CoursePicker(develop: develop) }
    }
}

struct CourseRow: View {
    let develop: DevelopModel
    let course: Course
    let spec: Catalogue.Spec?

    var body: some View {
        HStack(spacing: 12) {
            SubjectBadge(subject: spec?.subject ?? course.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.map { "\($0.qualification) \($0.subject)" } ?? course.name).font(.subheadline.weight(.semibold))
                if let spec {
                    let have = develop.downloaded(spec), total = spec.questionPapers.count
                    Text("\(develop.boardName(spec.board)) · \(spec.code) · \(have) of \(total) papers on this device")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(have), total: Double(max(total, 1)))
                        .tint(SubjectStyle.symbol(spec.subject).color)
                } else {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
        .contentShape(.rect)
    }
}

/// Pick a level, then a subject: every spec the catalogue knows, searchable.
struct CoursePicker: View {
    @Bindable var develop: DevelopModel
    @Environment(\.dismiss) private var dismiss
    @State private var level: ProblemLevel = .alevel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Level", selection: $level) {
                        Text("GCSE").tag(ProblemLevel.gcse)
                        Text("IGCSE").tag(ProblemLevel.igcse)
                        Text("A-level").tag(ProblemLevel.alevel)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let cat = develop.catalogue {
                    let specs = query.isEmpty ? cat.specs(level: level) : cat.search(query, level: level)
                    let bySubject = Dictionary(grouping: specs) { $0.subject }
                    ForEach(bySubject.keys.sorted(), id: \.self) { subject in
                        Section {
                            ForEach(bySubject[subject] ?? []) { spec in
                                let chosen = develop.courses.contains { $0.spec == spec.id }
                                Button {
                                    Task {
                                        await develop.addCourse(spec)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        SubjectBadge(subject: spec.subject, size: 32)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(develop.boardName(spec.board)) \(spec.qualification)").font(.subheadline.weight(.medium))
                                            Text(detail(spec)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    }
                                }
                                .disabled(chosen)
                            }
                        } header: { Text(subject) }
                    }
                    if specs.isEmpty {
                        Text("Nothing matches. Try the subject's name, the board or the spec code.").foregroundStyle(.secondary)
                    }
                    Section {
                        Text(unlistedNote(cat)).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .searchable(text: $query, prompt: "Subject, board or code")
            .navigationTitle("Add a course")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func detail(_ spec: Catalogue.Spec) -> String {
        var parts = ["Spec \(spec.code)"]
        if let n = spec.papers { parts.append("\(n) paper\(n == 1 ? "" : "s")") }
        if let y = spec.years, y.count == 2 { parts.append(y[0] == y[1] ? "\(y[0])" : "\(y[0])–\(y[1])") }
        return parts.joined(separator: " · ")
    }

    private func unlistedNote(_ cat: Catalogue) -> String {
        let names = (cat.unlisted ?? []).map { u in u.id == "pearson" ? "Pearson Edexcel" : u.id == "ccea" ? "CCEA" : u.id.uppercased() }
        let missing = names.isEmpty ? "" : "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "isn't" : "aren't") listed yet. "
        return missing + "For CCEA, use Upload → From a board's website in Your own papers: you browse its site and add the papers you want. "
            + "For anything else, upload the papers yourself: they're saved in your trove and sync to all your devices."
    }
}

/// One course: its papers by series, each downloadable with its mark scheme, then practised.
struct CourseView: View {
    @Bindable var develop: DevelopModel
    let course: Course
    @State private var spec: Catalogue.Spec?
    @State private var tier: String = "All"

    var body: some View {
        List {
            if let spec {
                Section {
                    HStack(spacing: 14) {
                        SubjectBadge(subject: spec.subject, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(spec.qualification) \(spec.subject)").font(.title3.weight(.semibold))
                            Text("\(develop.boardName(spec.board)) · spec \(spec.code)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    let have = develop.downloaded(spec), total = spec.questionPapers.count
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(have), total: Double(max(total, 1))).tint(SubjectStyle.symbol(spec.subject).color)
                        Text("\(have) of \(total) papers on this device · \(ready(spec)) questions ready")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = develop.downloading {
                        HStack {
                            ProgressView(value: Double(d.done), total: Double(max(1, d.total)))
                            Text("\(d.done) of \(d.total)").font(.caption).monospacedDigit()
                            Button("Cancel") { develop.cancelDownload() }
                        }
                    } else {
                        Button { develop.download(spec) } label: {
                            Label(have == total ? "Split into questions" : "Download every paper", systemImage: have == total ? "scissors" : "arrow.down.circle")
                        }
                        .disabled(develop.splitting)
                    }
                    Text("Downloads come from \(develop.boardName(spec.board))'s own website, on Wi-Fi only, and stay on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if tiers(spec).count > 1 {
                    Picker("Tier", selection: $tier) {
                        Text("All").tag("All")
                        ForEach(tiers(spec), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                ForEach(series(spec), id: \.self) { key in
                    Section(key) {
                        ForEach(spec.questionPapers.filter { seriesKey($0) == key && (tier == "All" || $0.tier == tier) }) { qp in
                            PaperRow(develop: develop, spec: spec, qp: qp)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(spec?.subject ?? course.name)
        .task { spec = await develop.loadSpec(course.spec) }
        .toolbar {
            ToolbarItem {
                Menu {
                    if let url = spec.flatMap({ URL(string: $0.url) }) { Link("Board's page", destination: url) }
                    Button("Remove course", systemImage: "minus.circle", role: .destructive) { Task { await develop.removeCourse(course) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func ready(_ spec: Catalogue.Spec) -> Int {
        let prefix = spec.id + "-"
        return develop.practisable.filter { p in (develop.docId(p) ?? "").hasPrefix(prefix) }.count
    }

    private func seriesKey(_ d: Catalogue.Doc) -> String {
        [d.series, d.year.map(String.init)].compactMap { $0 }.joined(separator: " ").ifEmpty("Other")
    }

    private func series(_ spec: Catalogue.Spec) -> [String] {
        var seen: [String] = []
        for d in spec.questionPapers where !seen.contains(seriesKey(d)) { seen.append(seriesKey(d)) }
        return seen
    }

    private func tiers(_ spec: Catalogue.Spec) -> [String] {
        Array(Set(spec.questionPapers.compactMap(\.tier))).sorted { $0 == "Higher" && $1 != "Higher" }
    }
}

struct PaperRow: View {
    let develop: DevelopModel
    let spec: Catalogue.Spec
    let qp: Catalogue.Doc

    var body: some View {
        let have = develop.cached.contains(qp.id)
        let ready = develop.practisable.contains { $0.sourceKey == "cat:\(qp.id)" }
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : have ? "doc.fill" : "arrow.down.circle")
                .foregroundStyle(ready ? .green : have ? Color.secondary : Theme.accent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(ready ? "Ready to practise" : have ? "On this device" : "Tap to download with its mark scheme")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if qp.tier != nil { Text(qp.tier!).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule) }
        }
        .contentShape(.rect)
        .onTapGesture { if !ready, develop.downloading == nil { develop.download(spec, papers: [qp.id]) } }
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        let t = qp.title ?? "Paper \(qp.paper ?? "")"
        if let p = qp.paper, !t.localizedCaseInsensitiveContains("paper \(p)"), !t.localizedCaseInsensitiveContains("component") { return "Paper \(p): \(t)" }
        return t
    }
}

/// Your own papers: upload a PDF or a picture from anywhere; it's saved in your trove (so it syncs to
/// every device) and split into questions.
struct UploadsCard: View {
    @Bindable var develop: DevelopModel
    @Environment(\.pickFiles) private var pickFiles
    @State private var photos: [PhotosPickerItem] = []
    @State private var photosOpen = false
    @State private var naming: [DevelopModel.PendingUpload] = []
    @State private var browsing: BoardSite?
    @State private var renaming: Item?
    @State private var newName = ""
    #if os(iOS)
    @State private var scanning = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your own papers").font(.headline)
                Spacer()
                Menu {
                    Button("From Files…", systemImage: "folder") { pickFiles(FilePick(types: [.pdf, .image], multiple: true) { urls in Task { await upload(urls) } }) }
                    Button("From Photos…", systemImage: "photo.on.rectangle") { photosOpen = true }
                    #if os(iOS)
                    Button("Scan with the camera", systemImage: "doc.viewfinder") { scanning = true }
                    #endif
                    Section("From a board's website") {
                        ForEach(BoardSite.all) { site in
                            Button(site.menuTitle, systemImage: "safari") { browsing = site }
                        }
                    }
                } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(develop.splitting)
            }
            Text("Competition papers, worksheets, papers from other boards, a page of a textbook. Saved in your trove, so they're on all your devices.")
                .font(.caption).foregroundStyle(.secondary)
            let uploaded = develop.myPDFs.filter { develop.practisedItems.contains($0.id) }
            ForEach(uploaded.prefix(8)) { item in
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext").foregroundStyle(Theme.accent)
                    Text(item.displayTitle).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(develop.problems.filter { $0.sourceKey == "item:\(item.id)" }.count) questions").font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { newName = item.displayTitle; renaming = item }
                }
            }
            let others = develop.myPDFs.filter { !develop.practisedItems.contains($0.id) }
            if !others.isEmpty {
                Menu {
                    ForEach(others.prefix(40)) { item in
                        Button(item.displayTitle) { Task { await develop.split(item: item) } }
                    }
                } label: { Label("Or practise a PDF already in your trove…", systemImage: "doc.text.magnifyingglass").font(.caption) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .photosPicker(isPresented: $photosOpen, selection: $photos, maxSelectionCount: 20, matching: .images)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task {
                var files: [DevelopModel.PendingUpload] = []
                for (i, p) in picked.enumerated() {
                    if let data = try? await p.loadTransferable(type: Data.self) {
                        files.append(develop.pending(data, fileName: "Photo \(i + 1).jpg", mime: "image/jpeg"))
                    }
                }
                naming = files
            }
        }
        .sheet(isPresented: Binding(get: { !naming.isEmpty }, set: { if !$0 { naming = [] } })) {
            NameUploadsSheet(develop: develop, uploads: $naming)
        }
        .sheet(item: $browsing) { site in BoardBrowser(develop: develop, site: site) }
        .alert("Rename paper", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let item = renaming { Task { await develop.rename(item, to: newName) } }
                renaming = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { pdf in
                scanning = false
                guard let pdf else { return }
                naming = [develop.pending(pdf, fileName: "Scan \(Date().formatted(date: .abbreviated, time: .omitted)).pdf", mime: "application/pdf")]
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func upload(_ urls: [URL]) async {
        var files: [DevelopModel.PendingUpload] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            files.append(develop.pending(data, fileName: url.lastPathComponent,
                                         mime: type?.conforms(to: .pdf) == true ? "application/pdf" : (type?.preferredMIMEType ?? "image/jpeg")))
        }
        naming = files
    }
}

/// Name what you're uploading before it's saved. Trove reads each paper and suggests a name ("CCEA GCSE Physics
/// Unit 1 Foundation, June 2023"), tidied by Apple Intelligence where the device has it; the board's name is
/// kept as the board spells it. Type over it to use your own.
struct NameUploadsSheet: View {
    @Bindable var develop: DevelopModel
    @Binding var uploads: [DevelopModel.PendingUpload]
    var onSave: ((Int) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                ForEach($uploads) { $u in
                    Section {
                        TextField("Name", text: $u.name, axis: .vertical)
                            .lineLimit(1...3)
                        HStack(spacing: 6) {
                            if u.thinking {
                                ProgressView().controlSize(.small)
                                Text("Reading the paper…")
                            } else {
                                Image(systemName: u.byAI ? "sparkles" : "doc.text.magnifyingglass")
                                Text(u.byAI ? "Suggested with Apple Intelligence" : "Suggested from the paper")
                                if u.name != u.suggested {
                                    Spacer()
                                    Button("Use suggestion") { u.name = u.suggested }.buttonStyle(.borderless)
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Text(u.fileName).textCase(nil).lineLimit(1)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(uploads.count == 1 ? "Name this paper" : "Name these papers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { uploads = [] } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let chosen = uploads
                        uploads = []
                        onSave?(chosen.count)
                        Task { await develop.save(chosen) }
                    }
                    .disabled(uploads.isEmpty)
                }
            }
            .task {
                for u in uploads where u.thinking {
                    let named = await develop.suggestName(for: u)
                    // Apply to the current copy so anything typed meanwhile stays.
                    if let i = uploads.firstIndex(where: { $0.id == u.id }) {
                        if uploads[i].name != u.name { uploads[i].suggested = named.suggested; uploads[i].byAI = named.byAI; uploads[i].thinking = false }
                        else { uploads[i] = named }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
