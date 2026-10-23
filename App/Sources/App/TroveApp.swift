import CoreSpotlight
import SwiftUI
import TroveCore

@main
struct TroveApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        BackgroundTasks.register(model: model)
        #endif
        MetricsReporter.shared.start()
        #if os(macOS)
        WindowFocus.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { handle($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.selectedItemID = id }
                }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                .modifier(GlobalCaptureHotKey())
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.becameActive() } }
            #if os(iOS)
            if phase == .background {
                model.enteredBackground()
                BackgroundTasks.scheduleRefresh()
                BackgroundTasks.scheduleEnrichment()
            }
            #endif
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Capture…") { model.showCapture = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Today's Note") { Task { await model.openToday() } }
                Button("Sync Now") { Task { await model.syncNow() } }.keyboardShortcut("r", modifiers: .command)
            }
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
            }
            #endif
        }

        #if os(macOS)
        // Sketches (and drawing on PDFs and images) in a window of their own.
        WindowGroup("Sketch", id: "ink", for: InkTarget.self) { $target in
            if let target {
                InkEditorView(target: target, app: model)
                    .environment(model)
                    .navigationTitle(target.title)
            }
        }
        .defaultSize(width: 1100, height: 820)

        // A file opened with Open: view-only until Edit.
        WindowGroup("File", id: "file", for: FileTarget.self) { $target in
            if let target {
                FileViewer(target: target)
                    .environment(model)
                    .navigationTitle(target.title)
            }
        }
        .defaultSize(width: 1000, height: 820)

        Window("Capture", id: "capture") {
            CaptureView()
                .environment(model)
                .frame(width: 520)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // Settings → AI → Activity and costs.
        Window("AI Activity", id: "ai-activity") {
            AIActivityView().environment(model).frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 680, height: 720)

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            // Trove's own box, not the generic one.
            Image(nsImage: TroveMark.menuBarImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
        #endif
    }

    private func handle(_ url: URL) {
        if url.isFileURL { model.openFile(url); return }
        guard url.scheme == "trove" else { return }
        switch url.host {
        case "capture":
            model.showCapture = true
        case "item":
            model.selectedItemID = url.pathComponents.dropFirst().first
        case "search":
            model.searchText = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        case "link":
            if let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                Task { await model.openWikilink(title) }
            }
        case "pair":
            break // handled by onboarding's PairingInput when not set up
        default:
            break
        }
    }
}

#if os(macOS)
/// ⌘⇧Space from anywhere opens the capture window.
struct GlobalCaptureHotKey: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var hotKey: HotKey?

    func body(content: Content) -> some View {
        content.onAppear {
            guard hotKey == nil else { return }
            hotKey = HotKey {
                openWindow(id: "capture")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Menu bar popover: quick capture, recent items, sync status.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Capture a link or thought…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button(action: save) { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless).disabled(text.isEmpty)
            }
            if let url = Pasteboard.url {
                Button { Task { await model.capture(url.absoluteString) } } label: {
                    Label("Save copied link: \(url.host ?? "")", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
            }
            Button { model.clipboardPalette?.show() } label: {
                Label("Clipboard history  ⌥Space", systemImage: "list.clipboard")
            }
            .buttonStyle(.borderless)
            Divider()
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            ForEach(model.items.prefix(6)) { item in
                Button {
                    model.selectedItemID = item.id
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(item.displayTitle, systemImage: ItemStyle.symbol(for: item)).lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
            Divider()
            HStack {
                SyncIndicator()
                Text(model.sync.lastSync.map { "Synced \($0.relative)" } ?? "Not synced yet").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Trove") { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func save() {
        let t = text
        text = ""
        Task { await model.capture(t) }
    }
}
#endif
