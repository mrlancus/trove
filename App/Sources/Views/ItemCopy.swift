import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// ⌘C (and Copy in an item's menu) copies the item itself: a picture as a picture, a link as its
/// address, a note as its text, a PDF or other file as the file. Several picked items copy together.
extension AppModel {
    /// The selected item, or the picked ones in select mode.
    var itemsToCopy: [Item] {
        if selecting, !picked.isEmpty { return items.filter { picked.contains($0.id) } }
        return selectedItem.map { [$0] } ?? []
    }

    func copySelection() async { await copy(itemsToCopy) }

    func copy(_ list: [Item]) async {
        guard let library, !list.isEmpty else { return }
        var entries: [ItemCopy.Entry] = []
        for item in list {
            if let file = item.attachments.first, let data = try? await library.attachmentData(file) {
                if file.mime.hasPrefix("image/"), let image = PlatformImage(data: data) {
                    entries.append(.image(image, data, file))
                } else {
                    entries.append(.file(data, file))
                }
            } else if let url = item.url {
                entries.append(.link(url, item.displayTitle))
            } else {
                let text = item.body.isEmpty ? item.displayTitle : item.body
                entries.append(.text(text))
            }
        }
        ItemCopy.write(entries)
        toast = list.count == 1 ? "Copied" : "Copied \(list.count) items"
    }
}

@MainActor
enum ItemCopy {
    enum Entry {
        case image(PlatformImage, Data, Attachment)
        case file(Data, Attachment)
        case link(URL, String)
        case text(String)
    }

    static func write(_ entries: [Entry]) {
        #if canImport(UIKit)
        var items: [[String: Any]] = []
        for e in entries {
            switch e {
            case .image(let image, let data, let file):
                var item: [String: Any] = [UTType.image.identifier: image]
                if let type = UTType(mimeType: file.mime) { item[type.identifier] = data }
                items.append(item)
            case .file(let data, let file):
                let type = UTType(mimeType: file.mime) ?? UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
                items.append([type.identifier: data])
            case .link(let url, _):
                items.append([UTType.url.identifier: url, UTType.plainText.identifier: url.absoluteString])
            case .text(let text):
                items.append([UTType.plainText.identifier: text])
            }
        }
        UIPasteboard.general.items = items
        ClipPasteboard.ownChangeCount = UIPasteboard.general.changeCount
        #else
        var objects: [NSPasteboardWriting] = []
        for e in entries {
            switch e {
            case .image(let image, _, _): objects.append(image)
            case .file(let data, let file):
                // Finder and other apps paste a file from its URL.
                if let url = temporaryFile(data, name: file.name) { objects.append(url as NSURL) }
            case .link(let url, _): objects.append(url as NSURL)
            case .text(let text): objects.append(text as NSString)
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(objects)
        ClipPasteboard.ownChangeCount = pb.changeCount
        #endif
    }

    #if os(macOS)
    private static func temporaryFile(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Copied/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
    #endif
}

#if os(macOS)
/// ⌘C in the library window when nothing editable has the keyboard (text fields and editors keep
/// their own copy): copies the selected items.
@MainActor
enum MacCopyKey {
    private static var monitor: Any?

    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c",
                  let window = event.window, !(window is NSPanel),
                  !(window.firstResponder is NSText), !model.itemsToCopy.isEmpty else { return event }
            Task { await model.copySelection() }
            return nil
        }
    }
}
#endif

#if os(iOS)
/// A hardware keyboard's ⌘C on iPad and iPhone: an invisible responder that takes "copy" whenever no
/// text field is being typed in (text fields keep their own copy).
struct CopyKeyCatcher: UIViewRepresentable {
    /// Changes when the selection does, so the catcher takes the keyboard again.
    let token: String
    let copy: () -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onCopy = copy
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.onCopy = copy
        view.claim()
    }

    final class CatcherView: UIView {
        var onCopy: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            claim()
        }

        /// Becomes first responder unless something is being typed in.
        func claim() {
            guard window != nil, !isFirstResponder else { return }
            if let current = UIResponder.currentFirst, current is UITextInput { return }
            becomeFirstResponder()
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            action == #selector(copy(_:)) ? onCopy != nil : super.canPerformAction(action, withSender: sender)
        }

        override func copy(_ sender: Any?) { onCopy?() }
    }
}

extension UIResponder {
    private nonisolated(unsafe) static weak var found: UIResponder?

    /// The first responder now (nil when there is none).
    static var currentFirst: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.noteFirst(_:)), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func noteFirst(_ sender: Any?) { UIResponder.found = self }
}
#endif

extension View {
    /// ⌘C copies the selected (or picked) items when no text is being edited.
    func copiesSelection(_ model: AppModel) -> some View {
        #if os(macOS)
        onAppear { MacCopyKey.install(model) }
        #else
        background(CopyKeyCatcher(token: (model.selectedItemID ?? "") + model.picked.sorted().joined()) {
            Task { await model.copySelection() }
        }.frame(width: 0, height: 0))
        #endif
    }
}
