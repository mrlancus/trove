import Foundation
import TroveCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Writes clips back to the system pasteboard. On the Mac it remembers the change count of its own
/// writes so the watcher doesn't record them as new copies.
@MainActor
enum ClipPasteboard {
    #if os(macOS)
    static var ownChangeCount = -1
    #endif

    static func write(text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownChangeCount = pb.changeCount
        #endif
    }

    static func write(image: PlatformImage) {
        #if canImport(UIKit)
        UIPasteboard.general.image = image
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        ownChangeCount = pb.changeCount
        #endif
    }

    /// Files that still exist are pasted as files; otherwise their paths as text.
    static func write(files: [String]) {
        #if os(macOS)
        let urls = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { write(text: files.joined(separator: "\n")); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(existing as [NSURL])
        ownChangeCount = pb.changeCount
        #else
        write(text: files.joined(separator: "\n"))
        #endif
    }
}
