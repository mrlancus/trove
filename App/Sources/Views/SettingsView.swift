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
            NavigationStack { Form { AISection() }.formStyle(.grouped) }
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            Form { IntegrationsSection(); BridgesSection() }.formStyle(.grouped)
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            Form { BatterySection() }.formStyle(.grouped)
                .tabItem { Label("Battery", systemImage: "battery.75percent") }
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
            BridgesSection()
            ClipboardSection()
            BatterySection()
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
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("This version", value: "\(updater.currentVersion) (build \(updater.currentBuild))")
            Toggle("Download and offer updates automatically", isOn: Binding(get: { model.isOn(.autoUpdate) }, set: { model.setShared(.autoUpdate, $0) }))
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
            // Whether the share sheet, widgets and keyboard can reach the app (they share an App Group).
            LabeledContent("Share sheet and widgets", value: SharedConfig.appGroupFound.map { "Connected (\($0))" } ?? "Can't share storage on this install")
                .textSelection(.enabled)
            if !SharedConfig.hasSharedContainer, let keys = model.vault.keys, let c = model.config, let relay = c.relay,
               let code = SharedConfig.setupCode(.init(vaultPublicKey: keys.publicKeyBase64URL, relayURL: relay.url,
                                                       relayVaultId: relay.vaultId, inboxToken: relay.inboxToken)) {
                Button("Copy share sheet code") {
                    Pasteboard.copy(code)
                    model.toast = "Copied. In the share sheet, tap Paste code"
                }
            }
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

/// Your own AI: provider, key and the three models (`AISettings`), saved for every device.
private struct OwnAISection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AISettings()
    @State private var loaded = false
    @State private var available: [String] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Section {
            // Another provider has other models: the ones chosen are cleared.
            Picker("Provider", selection: Binding(get: { draft.provider }, set: { p in
                guard p != draft.provider else { return }
                draft.provider = p
                draft.models = [:]
                available = []
            })) {
                ForEach(AISettings.Provider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            SecureField(draft.provider == .custom ? "API key (if it needs one)" : "API key", text: $draft.apiKey)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if draft.provider == .custom {
                TextField("API address, e.g. http://localhost:11434/v1", text: $draft.customURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            if let page = URL(string: draft.provider.keyPage), !draft.provider.keyPage.isEmpty {
                Link("Get a key from \(draft.provider.label)…", destination: page)
            }
            ForEach(AISettings.Tier.allCases, id: \.self) { tier in
                HStack {
                    Text(tier.label).frame(width: 74, alignment: .leading)
                    TextField(draft.provider.defaultModels[tier] ?? (tier == .fast ? "model name" : "same as Fast"), text: Binding(
                        get: { draft.models[tier] ?? "" },
                        set: { draft.models[tier] = $0.isEmpty ? nil : $0 }))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !available.isEmpty {
                        Menu {
                            ForEach(available, id: \.self) { m in Button(m) { draft.models[tier] = m } }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Choose the \(tier.label) model")
                    }
                }
            }
            Toggle("Read handwriting with your AI", isOn: $draft.readHandwriting)
            if draft.readHandwriting {
                LabeledContent("Background limit a month") {
                    HStack(spacing: 6) {
                        Text("$")
                        TextField("1.00", value: $draft.monthlyLimit, format: .number.precision(.fractionLength(2)))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }
                Text(draft.monthlyLimit > 0
                     ? "Reading handwriting stops for the month at this (spent so far: \(AIUsage.dollars(model.backgroundAISpend))); Apple's text recognition takes over. 0 means no limit. Ask and actions you start aren't limited."
                     : "No limit on reading handwriting (spent this month: \(AIUsage.dollars(model.backgroundAISpend))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink {
                AIActivityView()
            } label: {
                LabeledContent("Activity and costs") {
                    Text("\(AIUsage.dollars(model.aiTotal(.month).cost)) this month")
                }
            }
            HStack {
                Button("Save") {
                    Task {
                        await model.saveAISettings(draft)
                        status = draft.isReady ? "Saved. Every device uses it now." : "Saved. Add a key and a Fast model to use it."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == model.aiSettings)
                Button("Test") { test() }.disabled(!draft.isReady || busy)
                Button("Load models") { loadModels() }.disabled(busy || (draft.apiKey.isEmpty && draft.provider != .custom))
                if busy { ProgressView().controlSize(.small) }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Your AI")
        } footer: {
            FormFooter("Paste an API key from Claude, OpenAI, Gemini, OpenRouter or any OpenAI-compatible service (a local Ollama or LM Studio too). Fast does everything by default: Ask, note and page actions, and reading handwriting as soon as a sketch, GoodNotes notebook, inked or scanned PDF or photo of a page arrives. Pick Smarter or Best per question in Ask. Medium effort (low for reading pages, which is mostly copying). Every request and its cost is listed under Activity and costs. The key is kept in your vault, end-to-end encrypted, and reaches your other devices; requests go straight from this device to the provider with only what each one needs. The provider bills you for what you use, so set a monthly limit on their site.")
        }
        .onAppear {
            guard !loaded else { return }
            draft = model.aiSettings
            loaded = true
        }
    }

    private func test() {
        busy = true
        status = nil
        let client = AIClient(settings: draft, meter: { [weak model] call in await model?.logAI(call) })
        Task {
            do {
                let reply = try await client.complete([.text("Reply with just the word OK.")], tier: .fast, maxTokens: 1000,
                                                      effort: "low", purpose: .init(.test))
                status = "Works: \(reply.model) said “\(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))”."
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }

    private func loadModels() {
        busy = true
        status = nil
        let client = AIClient(settings: draft)
        Task {
            do {
                available = try await client.listModels()
                status = available.isEmpty ? "No models listed." : "\(available.count) models: choose them with the arrows."
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct AISection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OwnAISection()
        Section {
            LabeledContent("This device", value: OnDeviceAI.isAvailable ? "Apple Intelligence" : "Basic")
            if !OnDeviceAI.isAvailable {
                Text(OnDeviceAI.unavailableReason).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Use cloud AI when no device can (opt-in)", isOn: Binding(
                get: { model.isOn(.cloudAI) },
                set: { model.setShared(.cloudAI, $0) }))
            .disabled(model.config?.relay == nil)
            if model.enriching { HStack { ProgressView().controlSize(.small); Text("Organising…") } }
        } header: {
            Text("Intelligence")
        } footer: {
            FormFooter("Search by meaning, text in images, dates and places work on every device. Smart titles and summaries come from Apple Intelligence (your iPad does it for everything). Cloud AI sends that item's text to Claude via your relay; items processed this way show a cloud icon.")
        }
        // The relay's AI status is asked for once per launch, and again here.
        .task { await model.refreshAIStatus() }
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
                set: { on in model.updateConfig { $0.appleNotesImport = on }; if on { Task { await model.importAppleNotes(force: true) } } }))
            if model.config?.appleNotesImport == true {
                HStack {
                    Text(model.appleNotesStatus ?? "Checks Apple Notes every few minutes while Trove is open.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import now") { Task { await model.importAppleNotes(force: true) } }
                }
            }
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
            Toggle("Import new screenshots", isOn: Binding(
                get: { model.config?.screenshotsImport ?? false },
                set: { on in
                    Task {
                        #if os(iOS)
                        let ok = on ? await ScreenshotImporter.requestAccess() : true
                        #else
                        let ok = true
                        #endif
                        model.updateConfig { $0.screenshotsImport = on && ok }
                        model.watchScreenshots()
                    }
                }))
            #if os(iOS)
            Text("Screenshots only, not other photos: as soon as you take one while Trove is open, otherwise when you come back to Trove.").font(.caption).foregroundStyle(.secondary)
            #else
            Text("Screenshots only, as soon as you take them.").font(.caption).foregroundStyle(.secondary)
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

    /// A toggle for a setting every device shares.
    private func shared(_ key: SharedSetting) -> Binding<Bool> {
        Binding(get: { model.isOn(key) }, set: { model.setShared(key, $0) })
    }

    /// The usual choices, plus whatever another device set if it isn't one of them.
    static func choices(_ list: [Int], current: Int) -> [Int] { list.contains(current) ? list : list + [current] }
    #if os(macOS)
    @State private var trusted = AXIsProcessTrusted()
    #endif

    var body: some View {
        @Bindable var clipboard = model.clipboard
        Section {
            Toggle("Keep clipboard history", isOn: shared(.clipboardHistory))
            Toggle("Hold passwords and codes briefly (never synced)", isOn: shared(.holdSensitive))
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
            Text("On iPhone and iPad Trove doesn't read your clipboard by itself (iOS would ask “Allow Paste?” each time). Tap Paste in Clipboard to save what you copied, or use the Save Clipboard to Trove shortcut.")
                .font(.caption).foregroundStyle(.secondary)
            Text("For your clipboard in any app, add the Trove keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Trove, then turn on Allow Full Access (it only reads clips Trove saved on this device; it never sends anything).")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            #if os(macOS)
            Toggle("Record the page and window each copy came from", isOn: shared(.recordPages))
            Text("The window title needs Accessibility (above). For Safari and other browsers, macOS asks once whether Trove may read the front page's address.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            Toggle("Record where you copy and paste", isOn: shared(.recordPlaces))
            Text("Each copy and paste keeps the app or site, the device, the time and where you were (from this device's location, never your IP address). Encrypted like everything else. Applies on every device.")
                .font(.caption).foregroundStyle(.secondary)
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
            Picker("Keep clips for", selection: Binding(get: { clipboard.keep.days },
                                                         set: { days in Task { await clipboard.setKeep(ClipKeep(days: days, count: clipboard.keep.count)) } })) {
                ForEach(Self.choices(ClipKeep.dayChoices, current: clipboard.keep.days), id: \.self) { Text(ClipKeep.daysTitle($0)).tag($0) }
            }
            Picker("Keep at most", selection: Binding(get: { clipboard.keep.count },
                                                       set: { count in Task { await clipboard.setKeep(ClipKeep(days: clipboard.keep.days, count: count)) } })) {
                ForEach(Self.choices(ClipKeep.countChoices, current: clipboard.keep.count), id: \.self) { Text(ClipKeep.countTitle($0)).tag($0) }
            }
            Text("Older clips are deleted on all your devices (pinned ones always stay). \(model.clipboard.clips.count.formatted()) kept now.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Delete every unpinned clip on all your devices?", isPresented: $confirmClear) {
                    Button("Clear history", role: .destructive) { Task { await model.clipboard.clearHistory() } }
                }
        } header: {
            Text("Clipboard")
        } footer: {
            FormFooter("These settings apply on all your devices. Copies sync end-to-end encrypted to your other devices. Passwords, API keys and one-time codes are never synced, and copies from password managers are skipped.")
        }
    }
}

