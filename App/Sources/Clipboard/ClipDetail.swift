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

    private var editableText: Bool { clip.image == nil && clip.files.isEmpty }
    private var monospaced: Bool { [.code, .json].contains(clip.kind) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name, prompt: Text(clip.aiTitle ?? clip.autoTitle))
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
            Section {
                HStack {
                    Button(clip.isPinned ? "Unpin" : "Pin") { Task { await store.togglePin(clip) } }
                    Button(clip.savedItem == nil ? "Save to Trove" : "Saved in Trove") { saveToLibrary(clip) }
                        .disabled(clip.savedItem != nil)
                    Spacer()
                    Button("Cancel", role: .cancel) { done() }
                    Button("Save") { Task { await save(); done() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: clip.id) { load() }
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
        name = clip.title ?? ""
        text = clip.text
        tags = clip.tags.joined(separator: ", ")
        note = clip.note
    }

    /// Writes only what changed.
    private func save() async {
        if name != (clip.title ?? "") { await store.rename(clip, to: name) }
        if editableText, text != clip.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await store.edit(clip, text: text) }
        let newTags = tags.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if newTags.map({ $0.lowercased().replacingOccurrences(of: "#", with: "") }) != clip.tags { await store.setTags(clip, newTags) }
        if note != clip.note { await store.setNote(clip, note) }
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
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
        #endif
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
