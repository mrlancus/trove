import SwiftUI
import TroveCore

/// Everything about one clip, and editing it: its name, text, tags and note, what was found in it,
/// and where and when it was copied (PROTOCOL.md §8). The Mac palette shows it in place of the
/// preview (⌘E); iPhone and iPad open it as a sheet (`ClipDetailSheet`).
struct ClipDetailForm: View {
    let clip: Clip
    let store: ClipboardStore
    let thisDevice: String?
    var saveToLibrary: (Clip) -> Void
    var done: () -> Void

    @State private var name = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var note = ""
    /// Cancel was pressed: leaving doesn't save. Anything else that closes the form (switching clips,
    /// swiping the sheet away, the palette closing) keeps what was typed, like the website does.
    @State private var cancelled = false

    private var editableText: Bool { clip.image == nil && clip.files.isEmpty }
    private var monospaced: Bool { [.code, .json].contains(clip.kind) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name, prompt: Text(clip.aiTitle ?? clip.autoTitle))
                    .onSubmit { let d = draft; Task { await Self.save(d) } }
                if let summary = clip.summary { Text(summary).font(.callout).foregroundStyle(.secondary) }
            }
            if editableText {
                Section("Text") {
                    TextEditor(text: $text)
                        .font(monospaced ? .callout.monospaced() : .callout)
                        .frame(minHeight: 90)
                }
            }
            if let ocr = clip.ocrText {
                Section("Text in the image") {
                    Text(ocr).textSelection(.enabled).lineLimit(12)
                    Button("Copy text") { ClipPasteboard.write(text: ocr) }
                }
            }
            found
            Section("Tags") {
                TextField("Tags", text: $tags, prompt: Text("work, ideas"))
            }
            Section("Note") {
                TextEditor(text: $note).frame(minHeight: 54)
            }
            Section("Where it came from") { facts }
            Section("Where and when") { ClipHistoryList(clipId: clip.id, store: store) }
            Section {
                HStack {
                    Button(clip.isPinned ? "Unpin" : "Pin") { Task { await store.togglePin(clip) } }
                    Button(clip.savedItem == nil ? "Save to Trove" : "Saved in Trove") { saveToLibrary(clip) }
                        .disabled(clip.savedItem != nil)
                    Spacer()
                    Button("Cancel", role: .cancel) { cancelled = true; done() }
                    Button("Save") { let d = draft; Task { await Self.save(d); done() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
                // In an iOS Form, a row's buttons all fire on a tap unless each is borderless.
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: clip.id) { old, _ in
            // Another clip is shown in the same form: keep what was typed for the one before.
            if !cancelled, let previous = store.clips.first(where: { $0.id == old }) { let d = draft(of: previous); Task { await Self.save(d) } }
            load()
        }
        .onDisappear { if !cancelled { let d = draft; Task { await Self.save(d) } } }
    }

    @ViewBuilder private var found: some View {
        let i = clip.insights
        let any = !(i.links.isEmpty && i.emails.isEmpty && i.phones.isEmpty && i.colors.isEmpty)
        if any, clip.kind != .link, clip.kind != .color {
            Section("Found in it") {
                ForEach(i.links, id: \.self) { link in
                    if let url = URL(string: link) { Link(destination: url) { Label(link, systemImage: "link").lineLimit(1) } }
                }
                ForEach(i.emails, id: \.self) { email in
                    if let url = URL(string: "mailto:\(email)") { Link(destination: url) { Label(email, systemImage: "envelope") } }
                }
                ForEach(i.phones, id: \.self) { phone in
                    if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") { Link(destination: url) { Label(phone, systemImage: "phone") } }
                }
                ForEach(i.colors, id: \.self) { hex in
                    Button { ClipPasteboard.write(text: hex) } label: {
                        HStack {
                            if let c = ClipClassifier.color(hex) {
                                RoundedRectangle(cornerRadius: 4).fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 16, height: 16)
                            }
                            Text(hex).font(.callout.monospaced())
                            Spacer()
                            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var facts: some View {
        if let app = clip.sourceApp { LabeledContent("App", value: app) }
        if let title = clip.sourceTitle { LabeledContent("Window", value: title) }
        if let url = clip.sourceURL {
            if url.scheme?.hasPrefix("http") == true {
                LabeledContent("Page") { Link(url.host ?? url.absoluteString, destination: url) }
            } else {
                LabeledContent("File", value: url.path)
            }
        }
        LabeledContent("Device", value: clip.device == thisDevice ? "This device" : (clip.sourceDevice ?? "Another device"))
        LabeledContent("Copied", value: clip.createdAt.formatted(date: .abbreviated, time: .shortened))
        if let edited = clip.editedAt { LabeledContent("Edited", value: edited.formatted(date: .abbreviated, time: .shortened)) }
        if clip.uses > 0 { LabeledContent("Used", value: clip.uses == 1 ? "1 more time" : "\(clip.uses) more times") }
        if editableText {
            let i = clip.insights
            LabeledContent("Size", value: [count(i.chars, "character"), count(i.words, "word"), count(i.lines, "line")].joined(separator: " · "))
        }
        if let e = clip.enrichment {
            LabeledContent("Named by", value: ["Built-in rules", "Apple Intelligence", "Helper", "Cloud AI"][min(3, e.tier.rawValue)])
        }
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

    private func load() {
        cancelled = false
        name = clip.title ?? ""
        text = clip.text
        tags = clip.tags.joined(separator: ", ")
        note = clip.note
    }

    /// What's typed, taken while the view is still there, so saving after it closes reads the right values.
    struct Draft {
        let id: String
        let store: ClipboardStore
        let name, text, tags, note: String
        let editableText: Bool
    }

    private var draft: Draft { draft(of: clip) }

    private func draft(of clip: Clip) -> Draft {
        Draft(id: clip.id, store: store, name: name, text: text, tags: tags, note: note, editableText: clip.image == nil && clip.files.isEmpty)
    }

    /// Writes only what differs from the clip as it is now (so saving twice writes nothing the second time).
    private static func save(_ d: Draft) async {
        guard let clip = d.store.clips.first(where: { $0.id == d.id }) else { return }
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != (clip.title ?? "") { await d.store.rename(clip, to: name) }
        if d.editableText, d.text != clip.text, !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await d.store.edit(clip, text: d.text) }
        let newTags = d.tags.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if Library.cleanTags(newTags) != clip.tags { await d.store.setTags(clip, newTags) }
        if d.note != clip.note { await d.store.setNote(clip, d.note) }
    }
}

/// iPhone and iPad: the clip's details in a sheet.
struct ClipDetailSheet: View {
    let clipID: String
    let store: ClipboardStore
    let thisDevice: String?
    var saveToLibrary: (Clip) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let clip = store.clips.first(where: { $0.id == clipID }) {
                ClipDetailForm(clip: clip, store: store, thisDevice: thisDevice, saveToLibrary: saveToLibrary) { dismiss() }
                    .navigationTitle(clip.displayTitle)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            } else {
                EmptyState(symbol: "doc.on.clipboard", title: "Clip deleted", message: "It was removed on another device.")
            }
        }
        .sheetSize(width: 500, height: 600)
    }
}

/// Clips matching the main search, under the library's results: tap to copy, the menu to edit.
struct ClipSearchRows: View {
    @Environment(AppModel.self) private var model
    @State private var detail: String?

    var body: some View {
        Group {
            ForEach(model.clipResults) { clip in
                Button { Task { await model.clipboard.copy(clip); model.toast = "Copied" } } label: {
                    ClipRow(entry: .clip(clip), store: model.clipboard, index: nil, selected: false, stacked: nil).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { detail = clip.id } label: { Label("Details and edit…", systemImage: "pencil") }
                    Button { model.saveClip(clip) } label: { Label("Save to Trove", systemImage: "tray.and.arrow.down") }
                }
            }
        }
        .sheet(item: Binding(get: { detail.map(ClipSheetID.init) }, set: { detail = $0?.id })) { sheet in
            ClipDetailSheet(clipID: sheet.id, store: model.clipboard, thisDevice: model.config?.deviceId, saveToLibrary: { model.saveClip($0) })
        }
    }
}

struct ClipSheetID: Identifiable { let id: String }

/// Every copy and paste of a clip, newest first: what, where to or from, when, on which device and
/// where you were (PROTOCOL.md §8 copy and paste events). Places open in Maps.
struct ClipHistoryList: View {
    let clipId: String
    let store: ClipboardStore
    @State private var events: [ClipEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                Text("No copies or pastes recorded yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(events.reversed().prefix(30)) { e in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(e.type == .copy ? Color.green : e.type == .paste ? Color.pink : Color.gray).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline(e)).font(.callout.weight(.semibold))
                        Text([e.at.formatted(date: .abbreviated, time: .shortened), e.deviceName, e.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let place = e.place, let url = URL(string: "https://maps.apple.com/?ll=\(place.lat),\(place.lon)&q=\(place.key.label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                            Link(destination: url) { Label(place.key.label, systemImage: "mappin.and.ellipse").font(.caption) }
                        }
                    }
                }
            }
        }
        .task(id: clipId) { events = await store.events(for: clipId) }
    }

    private func headline(_ e: ClipEvent) -> String {
        let place = e.whereKey?.label
        switch e.type {
        case .copy: return place.map { "Copied from \($0)" } ?? "Copied"
        case .paste: return place.map { "Pasted into \($0)" } ?? "Pasted"
        case .use: return "Copied again from Trove"
        }
    }
}
