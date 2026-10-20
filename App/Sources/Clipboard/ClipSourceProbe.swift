#if os(macOS)
import AppKit
import ApplicationServices
import TroveCore

/// Where a copy on the Mac came from, beyond the app (PROTOCOL.md §8 `sourceURL`, `sourceTitle`):
///  - the front window's title, through Accessibility (Trove already asks for it to paste);
///  - the page address: Chromium browsers mark copies with it, others are asked by AppleScript
///    (macOS asks once per browser whether Trove may);
///  - a document app's file (`AXDocument`).
enum ClipSourceProbe {
    /// AppleScript that returns the front page's address, by browser bundle id.
    static let browserScripts: [String: String] = {
        let chromium = "get URL of active tab of front window"
        var scripts = ["com.apple.Safari": "get URL of front document", "com.apple.SafariTechnologyPreview": "get URL of front document"]
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser", "com.brave.Browser",
                   "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"] { scripts[id] = chromium }
        return scripts
    }()

    static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// Recording page addresses can be turned off in Settings → Clipboard.
    static var recordPages: Bool {
        get { UserDefaults.standard.object(forKey: "clipboard.recordPages") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clipboard.recordPages") }
    }

    /// What can be read right away, on the main thread, while the copy is fresh.
    @MainActor
    static func immediate(app: NSRunningApplication?, pasteboard: NSPasteboard) -> (source: ClipSource, needsScript: Bool) {
        var source = ClipSource(bundle: app?.bundleIdentifier)
        if let app, AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if let raw = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let window = raw as! AXUIElement
                source.title = (attribute(window, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
                if let document = attribute(window, kAXDocumentAttribute) as? String, let url = URL(string: document) {
                    source.url = url.isFileURL ? url.path : url.absoluteString
                }
            }
        }
        guard recordPages else { return (source, false) }
        if let page = pasteboard.string(forType: chromiumSourceURL), page.hasPrefix("http") {
            source.url = page
            return (source, false)
        }
        let isBrowser = app?.bundleIdentifier.map { browserScripts[$0] != nil } ?? false
        return (source, isBrowser && (source.url?.hasPrefix("http") != true))
    }

    /// Asks the browser for its front page (off the main thread; gives up after two seconds).
    static func pageURL(bundle: String) async -> String? {
        guard let body = browserScripts[bundle] else { return nil }
        let script = "tell application id \"\(bundle)\" to \(body)"
        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            if process.isRunning { process.terminate(); return nil }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasPrefix("http") ? text : nil
        }.value
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
#endif
