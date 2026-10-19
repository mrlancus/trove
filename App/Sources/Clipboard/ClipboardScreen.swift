import SwiftUI
import TroveCore

/// The clipboard history as a screen (iPhone/iPad, and the Mac's toolbar button): tap to copy.
struct ClipboardScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = ClipPaletteState()

    var body: some View {
        NavigationStack {
            ClipsView(style: .list, state: state, store: model.clipboard, thisDevice: model.config?.deviceId,
                      activate: { entry, transform in copy(entry, transform) },
                      saveToLibrary: { model.saveClip($0) })
                .navigationTitle("Clipboard")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
        .task { await model.clipboard.reload() }
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
