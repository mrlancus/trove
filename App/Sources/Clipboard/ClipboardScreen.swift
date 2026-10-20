import SwiftUI
import TroveCore

/// The clipboard history as a screen (iPhone/iPad, and the Mac's toolbar button): tap to copy.
struct ClipboardScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = ClipPaletteState()
    /// In the sidebar's column (or pushed on iPhone) instead of a sheet.
    var embedded = false

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
        ClipsView(style: .list, state: state, store: model.clipboard, thisDevice: model.config?.deviceId,
                  activate: { entry, transform in copy(entry, transform) },
                  saveToLibrary: { model.saveClip($0) })
            .navigationTitle("Clipboard")
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
