import SwiftUI
import TroveCore

/// The clipboard history as a screen (iPhone/iPad, and the Mac's toolbar button): tap to copy.
struct ClipboardScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = ClipPaletteState()
    /// In the sidebar's column (or pushed on iPhone) instead of a sheet.
    var embedded = false
    /// Beside a detail column: tapping a clip opens it there instead of copying it.
    var select: ((String) -> Void)?

    var body: some View {
        if embedded {
            clips.task { await model.clipboard.reload() }
        } else {
            NavigationStack {
                clips.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .sheetSize(width: 760, height: 720)
            .task { await model.clipboard.reload() }
        }
    }

    private var clips: some View {
        #if os(macOS)
        // In the window, its search box (one per toolbar) searches the clipboard.
        let shared = embedded
        #else
        let shared = false
        #endif
        return ClipsView(style: .list, state: state, store: model.clipboard, thisDevice: model.config?.deviceId,
                         activate: { entry, transform in copy(entry, transform) },
                         saveToLibrary: { model.saveClip($0) }, ownSearch: !shared,
                         select: select, selectedID: select == nil ? nil : model.selectedClipID)
            .navigationTitle("Clipboard")
            .onAppear { if shared { state.query = model.searchText } }
            .onChange(of: model.searchText) { _, text in if shared { state.query = text } }
    }

    private func copy(_ entry: ClipEntry, _ transform: ClipTransform?) {
        Task {
            switch entry {
            case .clip(let clip): await model.clipboard.copy(clip, transform: transform)
            case .sensitive(let e): model.clipboard.copy(e)
            }
            model.toast = "Copied"
        }
    }
}

/// One clip in the window's detail column: copy it, and everything `ClipDetailForm` shows and edits.
struct ClipDetailPanel: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    /// Bumped by Cancel and Save so the form reads the clip again.
    @State private var round = 0

    var body: some View {
        ClipDetailForm(clip: clip, store: model.clipboard, thisDevice: model.config?.deviceId, saveToLibrary: { model.saveClip($0) }) { round += 1 }
            .id("\(clip.id)-\(round)")
            .navigationTitle(clip.displayTitle)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.clipboard.copy(clip, transform: nil); model.toast = "Copied" }
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy it to the clipboard")
                }
            }
    }
}
