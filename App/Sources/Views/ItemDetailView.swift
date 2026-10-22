import EventKit
import SwiftUI
import TroveCore

struct ItemDetailView: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var body_ = ""
    @State private var editing = false
    @State private var saveTask: Task<Void, Never>?
    @State private var similar: [Item] = []
    @State private var newTag = ""
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                FolderLine(item: item)
                if item.hasConflicts { ConflictBanner(item: item) }
                if let summary = item.summary, !summary.isEmpty, item.kind != .note { SummaryCard(item: item, summary: summary) }
                ExtractedCards(item: item)
                if item.kind == .sketch { SketchSection(item: item) }
                if !item.attachments.isEmpty { FilesSection(item: item) }
                editor
                if let ocr = item.ocrText, !ocr.isEmpty, item.kind != .note {
                    DisclosureGroup("Text found in this item") {
                        Text(ocr).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .card(cornerRadius: 14)
                }
                tags
                ConnectionsSection(item: item)
                if !similar.isEmpty { similarSection }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                if item.kind == .sketch || item.attachments.contains(where: AppModel.canInk) {
                    Button { model.draw(on: item) } label: { Label("Draw", systemImage: "pencil.tip.crop.circle") }
                        .help("Draw with Apple Pencil, a finger, the trackpad or the mouse")
                }
                Button { Task { await model.togglePin(item) } } label: { Image(systemName: item.isPinned ? "pin.fill" : "pin") }
                if let url = item.url { ShareLink(item: url) }
                Menu { ItemMenu(item: item) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            title = item.title
            body_ = item.body
            editing = item.kind == .note && item.body.isEmpty
        }
        .task(id: item.id) {
            let ids = await model.semantic.similar(to: item.id)
            similar = ids.compactMap { id in model.items.first { $0.id == id } }
        }
        .onDisappear { flush() }
        .sheet(isPresented: $showHistory) { HistorySheet(item: item) }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "trove", url.host == "link",
                  let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value else { return .systemAction }
            flush()
            Task { await model.openWikilink(title) }
            return .handled
        })
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ItemStyle.symbol(for: item)).foregroundStyle(ItemStyle.tint(for: item))
                Text(ItemStyle.sourceLabel(item.source))
                Text("·")
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let site = item.siteName { Text("·"); Text(site) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            TextField("Title", text: $title, axis: .vertical)
                .font(.largeTitle.weight(.bold))
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.update(item.id, [Field.title: .string(title)]) } }
                .onChange(of: title) { scheduleSave() }
            if let url = item.url {
                Link(destination: url) {
                    Label(url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString, systemImage: "arrow.up.right.square")
                }
                .font(.callout)
            }
            #if os(macOS)
            if let noteId = item.record[Field.origin]?.object?["appleNotesId"]?.string {
                Button { AppleNotesBridge.open(noteId: noteId) } label: { Label("Open in Apple Notes", systemImage: "note.text") }
                    .buttonStyle(.link)
            }
            #endif
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.kind == .note ? "Note" : "Your notes").font(.headline)
                Spacer()
                if item.kind == .note && model.noteAIAvailable {
                    NoteAIMenu(item: item, text: $body_)
                }
                Button { flush(); showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless)
                    .help("Earlier versions of this text")
                Picker("", selection: $editing) {
                    Text("Read").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if editing {
                MarkdownEditor(text: $body_)
                    .frame(minHeight: 260)
                    .onChange(of: body_) { scheduleSave() }
            } else if body_.isEmpty {
                Button { editing = true } label: {
                    Label("Add notes… (Markdown, #tags and [[links]] work)", systemImage: "square.and.pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                MarkdownText(markdown: body_) { index in
                    body_ = Notes.toggle(body_, at: index)
                    scheduleSave()
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private var tags: some View {
        HStack {
            ForEach(item.tags, id: \.self) { tag in
                TagChip(tag: tag)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            Task { await model.update(item.id, [Field.tags: JSONValue(item.tags.filter { $0 != tag })]) }
                        }
                        Button("Show all #\(tag)") { model.searchText = "tag:\(tag)" }
                    }
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .frame(maxWidth: 120)
                .onSubmit {
                    let t = newTag.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
                    newTag = ""
                    guard !t.isEmpty else { return }
                    Task { await model.update(item.id, [Field.tags: JSONValue(Array(Set(item.tags + [t])).sorted())]) }
                }
        }
        .tint(ItemStyle.tint(for: item))
    }

    private var similarSection: some View {
        VStack(alignment: .leading) {
            Text("Similar").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(similar) { other in
                        Button { model.selectedItemID = other.id } label: {
                            ItemCard(item: other).frame(width: 220)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        if body_ != item.body { await model.setBody(item.id, body_) }
        if title != item.title { await model.update(item.id, [Field.title: .string(title)]) }
    }
}

// MARK: - Pieces

struct SummaryCard: View {
    let item: Item
    let summary: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tierLabel, systemImage: item.enrichment?.tier == .cloud ? "cloud" : "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summary).font(.body)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }

    private var tierLabel: String {
        switch item.enrichment?.tier {
        case .cloud: "Summary · processed in the cloud"
        case .onDevice, .helper: "Summary · Apple Intelligence"
        default: "From the page"
        }
    }
}

struct ConflictBanner: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This note was edited on two devices at once. Nothing was lost.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            DisclosureGroup("Other version\(item.conflictingVersions.count > 1 ? "s" : "")", isExpanded: $expanded) {
                ForEach(Array(item.conflictingVersions.enumerated()), id: \.offset) { _, version in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(version).font(.callout).textSelection(.enabled)
                        HStack {
                            Button("Use this version") { Task { await model.resolveConflicts(item, keeping: version) } }
                            Button("Append to current") { Task { await model.resolveConflicts(item, keeping: item.body + "\n\n" + version) } }
                        }
                    }
                    .padding(10)
                    .card(cornerRadius: 10)
                }
            }
            Button("Keep current version") { Task { await model.resolveConflicts(item, keeping: item.body) } }
        }
        .padding(14)
        .card(cornerRadius: 16)
    }
}

/// Recipes, products, places, events, dates/addresses found in the item.
struct ExtractedCards: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var checked: Set<Int> = []
    @State private var calendarMessage: String?

    var body: some View {
        let x = item.extracted
        if let r = x["recipe"]?.object {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Recipe", systemImage: "fork.knife").font(.headline).foregroundStyle(.orange)
                    Spacer()
                    if let t = r["totalTime"]?.string { Text(Self.isoDuration(t)).foregroundStyle(.secondary) }
                    if let y = r["yield"]?.string { Text("Serves \(y)").foregroundStyle(.secondary) }
                }
                let ingredients = r["ingredients"]?.stringArray ?? []
                ForEach(Array(ingredients.enumerated()), id: \.offset) { i, ingredient in
                    Button {
                        if checked.contains(i) { checked.remove(i) } else { checked.insert(i) }
                    } label: {
                        Label(ingredient, systemImage: checked.contains(i) ? "checkmark.circle.fill" : "circle")
                            .strikethrough(checked.contains(i))
                            .foregroundStyle(checked.contains(i) ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                }
                let steps = r["steps"]?.stringArray ?? []
                if !steps.isEmpty {
                    Divider()
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top) {
                            Text("\(i + 1)").font(.headline).foregroundStyle(.orange).frame(width: 22)
                            Text(step)
                        }
                    }
                }
            }
            .padding(16).card(cornerRadius: 16)
        }
        if let p = x["product"]?.object {
            HStack {
                Label(p["brand"]?.string ?? "Product", systemImage: "bag").foregroundStyle(.pink)
                Spacer()
                if let price = p["price"]?.number { Text(price.formatted(.currency(code: p["currency"]?.string ?? "GBP"))).font(.title3.weight(.semibold)) }
                if let a = p["availability"]?.string { Text(a.replacingOccurrences(of: "InStock", with: "In stock")).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16).card(cornerRadius: 16)
        }
        if item.watchableURL != nil { priceTracking }
        if let place = x["place"]?.object {
            placeCard(name: place["name"]?.string ?? item.displayTitle, address: place["address"]?.string,
                      lat: place["lat"]?.number, lon: place["lon"]?.number)
        } else if let address = x["addresses"]?.stringArray.first {
            placeCard(name: item.displayTitle, address: address, lat: nil, lon: nil)
        }
        if let e = x["event"]?.object {
            eventCard(name: e["name"]?.string ?? item.displayTitle, start: e["startDate"]?.string.flatMap(Self.parseDate), venue: e["venue"]?.string)
        } else if let first = x["dates"]?.array?.first?.date, first > Date() {
            eventCard(name: item.displayTitle, start: first, venue: x["addresses"]?.stringArray.first)
        }
    }

    private var priceTracking: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { item.priceWatch != nil }, set: { on in Task { await model.setTracking(item, on) } })) {
                Label("Track price drops", systemImage: "bell.badge")
            }
            if let w = item.priceWatch {
                if let price = w.price {
                    HStack {
                        Text("Now \(PriceAlerts.price(price, w.currency))").font(.headline)
                        if let previous = w.previous, price < previous {
                            Text("was \(PriceAlerts.price(previous, w.currency))").strikethrough().foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let lowest = w.lowest { Text("Lowest \(PriceAlerts.price(lowest, w.currency))").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let checked = w.checkedAt {
                        Text("Checked \(checked.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.hasRelay ? "Checking the price…" : "Starts when a device with the relay syncs")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16).card(cornerRadius: 16)
    }

    private func placeCard(name: String, address: String?, lat: Double?, lon: Double?) -> some View {
        HStack {
            Label { VStack(alignment: .leading) { Text(name).font(.headline); if let address { Text(address).font(.caption).foregroundStyle(.secondary) } } }
                icon: { Image(systemName: "mappin.circle.fill").foregroundStyle(.green).font(.title2) }
            Spacer()
            if let url = Self.mapsURL(name: name, address: address, lat: lat, lon: lon) {
                Link("Directions", destination: url).buttonStyle(.bordered)
            }
        }
        .padding(16).card(cornerRadius: 16)
    }

    private func eventCard(name: String, start: Date?, venue: String?) -> some View {
        HStack {
            Label { VStack(alignment: .leading) {
                Text(name).font(.headline)
                if let start { Text(start.formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                if let venue { Text(venue).font(.caption).foregroundStyle(.secondary) }
            } } icon: { Image(systemName: "calendar.circle.fill").foregroundStyle(.red).font(.title2) }
            Spacer()
            if let start {
                Button(calendarMessage ?? "Add to Calendar") { Task { calendarMessage = await Self.addToCalendar(name, start, venue) } }
                    .buttonStyle(.bordered)
                    .disabled(calendarMessage != nil)
            }
        }
        .padding(16).card(cornerRadius: 16)
    }

    static func mapsURL(name: String, address: String?, lat: Double?, lon: Double?) -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")!
        if let lat, let lon { c.queryItems = [.init(name: "ll", value: "\(lat),\(lon)"), .init(name: "q", value: name)] }
        else { c.queryItems = [.init(name: "q", value: [name, address].compactMap { $0 }.joined(separator: ", "))] }
        return c.url
    }

    static func addToCalendar(_ title: String, _ start: Date, _ location: String?) async -> String {
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return "No calendar access" }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(2 * 3600)
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        do { try store.save(event, span: .thisEvent); return "Added to Calendar" } catch { return "Couldn't add" }
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return iso.date(from: s)
    }

    /// "PT1H20M" → "1h 20m"
    static func isoDuration(_ s: String) -> String {
        guard s.hasPrefix("P") else { return s }
        var out: [String] = []
        for (value, unit) in HTMLLikeDuration.parts(s) { out.append("\(value)\(unit)") }
        return out.isEmpty ? s : out.joined(separator: " ")
    }
}

enum HTMLLikeDuration {
    static func parts(_ s: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var number = ""
        for ch in s.dropFirst() {
            if ch.isNumber { number.append(ch) } else if ch == "T" { continue } else if let n = Int(number) {
                switch ch { case "H": result.append((n, "h")); case "M": result.append((n, "m")); case "D": result.append((n, "d")); default: break }
                number = ""
            }
        }
        return result
    }
}
