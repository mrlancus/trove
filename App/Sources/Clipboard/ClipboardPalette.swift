#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import TroveCore

/// A floating panel that can take typing without activating Trove, so the app you were in stays in
/// front and gets the paste.
final class ClipboardPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 620, height: 380)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onResignKey: (() -> Void)?
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// ⌥Space from anywhere: the clipboard palette. Type to search, arrows to move, ⏎ to paste into the
/// app you were using (with Accessibility allowed; otherwise it's copied and you press ⌘V).
@MainActor
final class ClipboardPaletteController {
    private let store: ClipboardStore
    private let state = ClipPaletteState()
    private let thisDevice: () -> String?
    private let saveToLibrary: (Clip) -> Void
    private var panel: ClipboardPanel?
    private var monitor: Any?
    private var hotKey: HotKey?
    private var promptedForAccessibility = false

    init(store: ClipboardStore, thisDevice: @escaping () -> String?, saveToLibrary: @escaping (Clip) -> Void) {
        self.store = store
        self.thisDevice = thisDevice
        self.saveToLibrary = saveToLibrary
    }

    func installHotKey() {
        guard hotKey == nil else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        state.query = ""
        state.filter = .all
        state.stack = []
        state.editing = nil
        state.tag = nil
        state.newTag = nil
        state.focusRequest += 1
        state.selection = state.entries(store, thisDevice: thisDevice()).first?.id
        // Centre on the screen with the mouse, a little above the middle (like Spotlight).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        let root = ClipsView(style: .palette, state: state, store: store, thisDevice: thisDevice(),
                             activate: { [weak self] entry, transform in self?.paste(entry, transform: transform) },
                             saveToLibrary: { [weak self] clip in self?.saveToLibrary(clip) },
                             close: { [weak self] in self?.hide() })
            .glass(cornerRadius: 20)
            .padding(1)
        panel.contentView = NSHostingView(rootView: root)
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        self.panel = panel
        return panel
    }

    // MARK: Keyboard

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only Sendable values cross into the main actor; the event itself stays here.
            let flags = event.modifierFlags
            let key = KeyPress(code: Int(event.keyCode), command: flags.contains(.command), option: flags.contains(.option),
                               characters: event.charactersIgnoringModifiers?.lowercased() ?? "", typed: event.characters ?? "",
                               windowNumber: event.windowNumber)
            let handled = MainActor.assumeIsolated { self?.handle(key) ?? false }
            return handled ? nil : event
        }
    }

    struct KeyPress: Sendable {
        var code: Int
        var command: Bool
        var option: Bool
        var characters: String
        /// What the key types, for sending stray typing to the search box.
        var typed: String
        var windowNumber: Int
    }

    /// Returns true when the palette handled the key (otherwise it goes to the search field).
    private func handle(_ event: KeyPress) -> Bool {
        guard let panel, event.windowNumber == panel.windowNumber else { return false }
        let entries = state.entries(store, thisDevice: thisDevice())
        let current = entries.first { $0.id == state.selection } ?? entries.first
        let command = event.command

        // Editing a clip: keys go to its fields; esc goes back to the preview.
        if state.editing != nil {
            if event.code == kVK_Escape { state.editing = nil; return true }
            return false
        }
        // Naming a new tag: keys go to its field; esc closes it.
        if state.newTag != nil {
            if event.code == kVK_Escape { state.newTag = nil; state.focusRequest += 1; return true }
            return false
        }
        switch event.code {
        case kVK_Escape:
            if !state.query.isEmpty { state.query = "" } else { hide() }
            return true
        case kVK_DownArrow:
            state.move(1, in: entries); return true
        case kVK_UpArrow:
            state.move(-1, in: entries); return true
        case kVK_Tab:
            if let current { state.toggleStack(current.id); state.move(1, in: entries) }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !state.stack.isEmpty {
                pasteStack(entries, copyOnly: event.option)
            } else if let current {
                paste(current, transform: nil, copyOnly: event.option)
            }
            return true
        case kVK_Delete where command:
            if let clip = current?.clip { state.move(1, in: entries); Task { await store.delete(clip) } }
            else if case .sensitive(let e) = current { store.forget(e) }
            return true
        default:
            break
        }
        guard command else {
            // Typing always searches, even if a click moved the focus off the search box.
            if !event.option, !event.typed.isEmpty, event.typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                focusSearch(panel)
            }
            return false
        }
        let key = event.characters
        if let n = Int(key), (1...9).contains(n), n <= entries.count {
            paste(entries[n - 1], transform: nil)
            return true
        }
        switch key {
        case "p":
            if let clip = current?.clip { Task { await store.togglePin(clip) } }
            return true
        case "s":
            if let clip = current?.clip { saveToLibrary(clip) }
            return true
        case "e":
            if let clip = current?.clip { state.selection = clip.id; state.editing = clip.id }
            return true
        case "[":
            shiftFilter(-1); return true
        case "]":
            shiftFilter(1); return true
        default:
            return false
        }
    }

    /// Puts the cursor at the end of the search box, unless a text field already has it. The key
    /// that called this then goes on to the box.
    private func focusSearch(_ panel: NSPanel) {
        if panel.firstResponder is NSTextView { return } // a field's editor: something is being typed in
        guard let field = Self.firstTextField(in: panel.contentView) else { return }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let field = firstTextField(in: sub) { return field } }
        return nil
    }

    private func shiftFilter(_ delta: Int) {
        let all = ClipFilter.allCases
        let i = all.firstIndex(of: state.filter) ?? 0
        state.filter = all[(i + delta + all.count) % all.count]
    }

    // MARK: Pasting

    private func paste(_ entry: ClipEntry, transform: ClipTransform?, copyOnly: Bool = false) {
        Task {
            switch entry {
            case .clip(let clip): await store.copy(clip, transform: transform, use: copyOnly)
            case .sensitive(let e): store.copy(e)
            }
            finish(copyOnly: copyOnly)
            if !copyOnly, let id = entry.clip?.id { notePaste([id]) }
        }
    }

    private func pasteStack(_ entries: [ClipEntry], copyOnly: Bool) {
        let clips = state.stack.compactMap { id in entries.first { $0.id == id }?.clip }
        Task {
            await store.copy(joined: clips)
            finish(copyOnly: copyOnly)
            if !copyOnly { notePaste(clips.map(\.id)) }
        }
    }

    /// Where the clips went: the app (and its window or page) in front once the palette is gone.
    private func notePaste(_ ids: [String]) {
        let store = store
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let app = NSWorkspace.shared.frontmostApplication
            guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            let (found, askBrowser) = ClipSourceProbe.immediate(app: app, pasteboard: NSPasteboard(name: .init("com.mrlancus.trove.none")))
            var source = found
            if askBrowser, let bundle = found.bundle, let page = await ClipSourceProbe.pageURL(bundle: bundle) { source.url = page }
            for id in ids { await store.note(id, .paste, app: app?.localizedName, source: source) }
        }
    }

    private func finish(copyOnly: Bool) {
        hide()
        guard !copyOnly else { return }
        guard Self.canPostKeystrokes(prompt: !promptedForAccessibility) else {
            promptedForAccessibility = true
            return // it's on the pasteboard; the user presses ⌘V
        }
        // Give the previous app a moment to become key again, then send ⌘V to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.sendCommandV() }
    }

    /// Pasting into another app means sending it ⌘V, which needs Accessibility permission.
    nonisolated static func canPostKeystrokes(prompt: Bool) -> Bool {
        // Either answer will do: sending ⌘V needs the event-posting right, which Accessibility grants.
        if AXIsProcessTrusted() || CGPreflightPostEventAccess() { return true }
        if prompt {
            _ = CGRequestPostEventAccess()
            // "AXTrustedCheckOptionPrompt" is kAXTrustedCheckOptionPrompt (a C global Swift 6 won't touch).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    nonisolated static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
#endif
