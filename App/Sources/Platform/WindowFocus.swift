#if os(macOS)
import AppKit

/// Keeps a Trove window active. When a sheet, the Settings window, a sketch or file window, the
/// or the menu bar window closes, macOS now and then leaves the library window in
/// front but not key: every toolbar button then looks greyed out (that's how AppKit draws an
/// inactive window) until you click it. After any of those closes, the frontmost Trove window is
/// made key again. (Not after the clipboard palette: that hands the keyboard back to the app
/// you're pasting into.)
@MainActor
enum WindowFocus {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didEndSheetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { restoreSoon() }
            })
        }
    }

    /// A moment later, once the closing window has gone.
    static func restoreSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { restore() } }
    }

    static func restore() {
        guard NSApp.isActive else { return }
        if let key = NSApp.keyWindow, key.isVisible, !(key is NSPanel) || key.isSheet { return }
        let candidates = NSApp.orderedWindows.filter { $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey && !($0 is NSPanel) }
        (candidates.first(where: \.canBecomeMain) ?? candidates.first)?.makeKeyAndOrderFront(nil)
    }
}
#endif
