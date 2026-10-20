import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import ApplicationServices
#endif

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        // A real Settings window with tabs, so it never outgrows the main window.
        TabView {
            Form { VaultSection(); UpdatesSection(); AboutSection() }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { WebSection(); DevicesSection(); RelaySection() }.formStyle(.grouped)
                .tabItem { Label("Devices & Web", systemImage: "laptopcomputer.and.iphone") }
            Form { ClipboardSection() }.formStyle(.grouped)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            Form { AISection() }.formStyle(.grouped)
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            Form { IntegrationsSection() }.formStyle(.grouped)
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 600, height: 560)
        #else
        SettingsList()
        #endif
    }
}

#if os(iOS)
private struct SettingsList: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            VaultSection()
            WebSection()
            DevicesSection()
            RelaySection()
            AISection()
            IntegrationsSection()
            ClipboardSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
#endif

#if os(macOS)
private struct UpdatesSection: View {
    @State private var updater = Updater.shared

    var body: some View {
        Section {
            LabeledContent("This version", value: "\(updater.currentVersion) (build \(updater.currentBuild))")
            Toggle("Download and offer updates automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                .disabled(!updater.isEnabled)
            HStack {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking)
                Spacer()
                Text(status).foregroundStyle(.secondary).font(.callout)
            }
        } header: {
            Text("Updates")
        } footer: {
            FormFooter("New versions come from the latest build on GitHub. Each one is checked against Trove's signing key before it's installed, and permissions you've given Trove stay as they are.")
        }
    }

    private var status: String {
        switch updater.state {
        case .idle: updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? ""
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .downloading(let v): "Downloading \(v)…"
        case .ready(let v): updater.canInstall ? "\(v) is ready to install" : "\(v) is out. Update from an administrator account."
        case .failed(let message): message
        }
    }
}
#endif

private struct AboutSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            Link("How Trove works (docs)", destination: URL(string: "https://github.com/mrlancus/trove/blob/main/docs/RESEARCH.md")!)
        }
        Section {
            Button("Remove Trove from this device…", role: .destructive) { confirmRemove = true }
                .confirmationDialog("Remove Trove from this device?", isPresented: $confirmRemove) {
                    Button("Remove from this device", role: .destructive) { model.resetThisDevice(); dismiss() }
                } message: {
                    Text("You'll need your recovery code or another device to set it up again.")
                }
        } footer: {
            FormFooter("Removes the keys and local copy from this device only. Your vault in iCloud and on other devices is untouched.")
        }
    }
}

private struct VaultSection: View {
    @Environment(AppModel.self) private var model
    @State private var showRecovery = false

    var body: some View {
        Section("Vault") {
            if let c = model.config {
                LabeledContent("Storage") {
                    switch c.storage {
                    case .path(let p): Text(URL(fileURLWithPath: p).lastPathComponent + " (iCloud Drive)")
                    case .bookmark: Text("Folder in Files")
                    case .none: Text("Relay only")
                    }
                }
                LabeledContent("Encryption", value: c.encrypted ? "End-to-end" : "Off (iCloud only)")
                LabeledContent("Items", value: "\(model.items.count)")
                if let last = model.sync.lastSync { LabeledContent("Last sync", value: last.relative) }
                if let err = model.sync.lastError { Text(err).font(.caption).foregroundStyle(.orange) }
                Button("Show recovery code") { showRecovery = true }
                    .sheet(isPresented: $showRecovery) { RecoveryCodeView() }
            }
        }
    }
}

private struct RecoveryCodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("Recovery code").font(.title2.bold())
            Text("If you lose every device, this code (plus your iCloud folder) is the only way back in. Print it or keep it in a password manager.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let keys = model.vault.keys, let config = model.config {
                let code = PairingPayload(vaultId: config.vaultId, keys: keys.exported(), encrypted: config.encrypted).setupCode
                Text(code).font(.caption.monospaced()).textSelection(.enabled).padding().card(cornerRadius: 12)
                Button { Pasteboard.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

/// "Use Trove in a browser": turns the relay on if needed, then makes a one-time setup code to paste
/// on the website. The code is copied as soon as it's made.
struct WebSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var code: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            if let relay = model.config?.relay, let site = URL(string: relay.url) {
                LabeledContent("Website") { Link(site.host ?? relay.url, destination: site) }
                if let code {
                    CopyRow(title: "Setup code (copied)", value: code, copied: true)
                    Text("On the website, open the Setup code tab, paste it and press Join. It works once, for 10 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { makeCode() } label: {
                        if working { ProgressView().controlSize(.small) } else { Text(code == nil ? "Make a setup code" : "Make a new code") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    Button("Open the website") { openURL(site) }
                }
            } else {
                Text("The website syncs through your Cloudflare relay. Turn it on to use Trove in any browser, with the browser extension, email-in and GoodNotes backups.")
                    .font(.callout).foregroundStyle(.secondary)
                if let relay = AppModel.defaultRelay {
                    Button { turnOnRelay(relay) } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Turn on the relay (\(URL(string: relay)?.host ?? relay))") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Trove on the web")
        }
    }

    private func turnOnRelay(_ url: String) {
        working = true
        error = nil
        Task {
            do { try await model.connectRelay(url); working = false; makeCode() } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }

    private func makeCode() {
        working = true
        error = nil
        Task {
            do {
                let made = try await model.vault.pairingPayload().setupCode
                Pasteboard.copy(made)
                code = made
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

private struct DevicesSection: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [RelayClient.Device] = []
    @State private var adding = false

    var body: some View {
        Section("Devices") {
            Button { adding = true } label: { Label("Add a device", systemImage: "qrcode") }
                .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { AddDeviceView() }
            ForEach(devices) { d in
                HStack {
                    Image(systemName: d.kind == "mac" ? "laptopcomputer" : d.kind == "ipad" ? "ipad" : d.kind == "web" ? "globe" : "iphone")
                    VStack(alignment: .leading) {
                        Text(d.name + (d.deviceId == model.config?.deviceId.uppercased() ? " (this device)" : ""))
                        Text(d.revoked ? "Removed" : "Seen \(Date(timeIntervalSince1970: d.lastSeenAt / 1000).relative)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !d.revoked, d.deviceId != model.config?.deviceId.uppercased() {
                        Button("Remove", role: .destructive) {
                            Task { try? await model.vault.relayClient?.revoke(device: d.deviceId); await load() }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async { devices = (try? await model.vault.relayClient?.devices()) ?? [] }
}

private struct RelaySection: View {
    @Environment(AppModel.self) private var model
    @State private var url = AppModel.defaultRelay ?? ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Section {
            if let relay = model.config?.relay {
                LabeledContent("Relay", value: URL(string: relay.url)?.host ?? relay.url)
                LabeledContent("Live updates", value: model.sync.live ? "Connected" : "Not connected")
                if let code = model.vault.browserSetupCode() {
                    CopyRow(title: "Browser extension setup code", value: code)
                }
                if let inbox = relay.inboxToken, let dav = model.vault.relayClient?.webDAVSettings(inboxToken: inbox) {
                    DisclosureGroup("GoodNotes Auto Backup (WebDAV)") {
                        CopyRow(title: "Server", value: dav.server)
                        CopyRow(title: "Username", value: dav.username)
                        CopyRow(title: "Password", value: dav.password)
                        Text("GoodNotes → Settings → Cloud & Backup → Auto Backup → WebDAV. Choose PDF format.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Disconnect relay", role: .destructive) { Task { await model.disconnectRelay() } }
            } else {
                TextField("https://trove-relay.<you>.workers.dev", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    working = true
                    Task {
                        do { try await model.connectRelay(url); error = nil } catch { self.error = error.localizedDescription }
                        working = false
                    }
                } label: { if working { ProgressView() } else { Text("Connect relay") } }
                .disabled(url.isEmpty || working)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } header: {
            Text("Cloudflare relay (optional)")
        } footer: {
            FormFooter("Adds instant sync, email-in, GoodNotes backups, the browser extension and cloud AI. Everything stays end-to-end encrypted; see server/README.")
        }
    }
}

private struct AISection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("This device", value: OnDeviceAI.isAvailable ? "Apple Intelligence" : "Basic")
            if !OnDeviceAI.isAvailable {
                Text(OnDeviceAI.unavailableReason).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Use cloud AI when no device can (opt-in)", isOn: Binding(
                get: { model.config?.cloudAI ?? false },
                set: { on in Task { await model.setCloudAI(on) } }))
            .disabled(model.config?.relay == nil)
            if model.enriching { HStack { ProgressView().controlSize(.small); Text("Organising…") } }
        } header: {
            Text("Intelligence")
        } footer: {
            FormFooter("Search by meaning, text in images, dates and places work on every device. Smart titles and summaries come from Apple Intelligence (your iPad does it for everything). Cloud AI sends that item's text to Claude via your relay; items processed this way show a cloud icon.")
        }
    }
}

private struct IntegrationsSection: View {
    @Environment(AppModel.self) private var model
    @State private var choosingObsidian = false

    var body: some View {
        Section {
            #if os(macOS)
            Toggle("Mirror Apple Notes into Trove search", isOn: Binding(
                get: { model.config?.appleNotesImport ?? false },
                set: { on in model.updateConfig { $0.appleNotesImport = on }; if on { Task { await model.syncNow() } } }))
            Button { choosingObsidian = true } label: {
                Label(model.config?.obsidianFolder.map { "Obsidian vault: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Sync with an Obsidian vault…", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .fileImporter(isPresented: $choosingObsidian, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.updateConfig { $0.obsidianFolder = url.path } }
            }
            if model.config?.obsidianFolder != nil {
                Button("Stop syncing Obsidian") { model.updateConfig { $0.obsidianFolder = nil } }
            }
            #endif
            #if os(iOS)
            Toggle("Import new screenshots", isOn: Binding(
                get: { model.config?.screenshotsImport ?? false },
                set: { on in
                    Task {
                        let ok = on ? await ScreenshotImporter.requestAccess() : true
                        model.updateConfig { $0.screenshotsImport = on && ok }
                    }
                }))
            #endif
        } header: {
            Text("Other apps")
        } footer: {
            FormFooter("To bring in files, folders, zips and exports, use Import in the sidebar or drop them on the Trove window.")
        }
    }
}

/// Section footnote. macOS right-aligns form footers by default; these are sentences, so they
/// read from the left.
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CopyRow: View {
    let title: String
    let value: String
    @State private var copied: Bool

    init(title: String, value: String, copied: Bool = false) {
        self.title = title
        self.value = value
        _copied = State(initialValue: copied)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                Pasteboard.copy(value)
                copied = true
            }
        }
    }
}

private struct ClipboardSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    static let autoSaveKinds: [(kind: ClipKind, title: String)] = [(.link, "Links"), (.image, "Images"), (.code, "Code"), (.text, "Text"), (.color, "Colours")]
    #if os(macOS)
    @State private var trusted = AXIsProcessTrusted()
    @State private var recordPages = ClipSourceProbe.recordPages
    #endif

    var body: some View {
        @Bindable var clipboard = model.clipboard
        Section {
            Toggle("Keep clipboard history", isOn: $clipboard.enabled)
            Toggle("Hold passwords and codes briefly (this device only)", isOn: $clipboard.keepSensitive)
            #if os(macOS)
            if clipboard.enabled {
                LabeledContent("Last copy recorded") {
                    if let last = clipboard.lastCaptured {
                        Text(last.heldBriefly ? "\(last.date.relative) (looked like a password: kept 2 min, not synced)" : last.date.relative)
                    } else {
                        Text("None yet. Copy something to try it.")
                    }
                }
            }
            LabeledContent("Open from anywhere", value: "⌥Space")
            LabeledContent("Paste straight into apps") {
                if trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else {
                    Button("Allow in Accessibility…") {
                        _ = ClipboardPaletteController.canPostKeystrokes(prompt: true)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            .task { while !Task.isCancelled { trusted = AXIsProcessTrusted(); try? await Task.sleep(for: .seconds(2)) } }
            if !trusted {
                Text("Until this is allowed, picking a clip copies it and you press ⌘V. If Trove is already switched on in Accessibility but this still says so, select Trove there, remove it with −, then allow it again: macOS treats each new download as a different app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            Toggle("Save what I copied when I open Trove", isOn: $clipboard.captureOnOpen)
            Text("iOS asks “Allow Paste?” each time unless you choose Settings → Apps → Trove → Paste from Other Apps → Allow.")
                .font(.caption).foregroundStyle(.secondary)
            Text("For your clipboard in any app, add the Trove keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Trove, then turn on Allow Full Access (it only reads clips Trove saved on this device; it never sends anything).")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            #if os(macOS)
            Toggle("Record the page and window each copy came from", isOn: Binding(get: { recordPages }, set: { recordPages = $0; ClipSourceProbe.recordPages = $0 }))
            Text("The window title needs Accessibility (above). For Safari and other browsers, macOS asks once whether Trove may read the front page's address.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            LabeledContent("Save to Trove automatically") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Self.autoSaveKinds, id: \.kind) { option in
                        Toggle(option.title, isOn: Binding(get: { clipboard.autoSave.contains(option.kind) },
                                                           set: { on in Task { await clipboard.setAutoSave(option.kind, on) } }))
                    }
                }
            }
            Text("Copies of these kinds go straight into your library, with where they came from. Applies on all your devices.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Delete every unpinned clip on all your devices?", isPresented: $confirmClear) {
                    Button("Clear history", role: .destructive) { Task { await model.clipboard.clearHistory() } }
                }
        } header: {
            Text("Clipboard")
        } footer: {
            FormFooter("Copies sync end-to-end encrypted to your other devices and are kept for 30 days (pinned ones forever). Passwords, API keys and one-time codes are never synced, and copies from password managers are skipped.")
        }
    }
}

