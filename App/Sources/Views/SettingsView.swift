import SwiftUI
import TroveCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            VaultSection()
            DevicesSection()
            RelaySection()
            AISection()
            IntegrationsSection()
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("How Trove works (docs)", destination: URL(string: "https://github.com/mrlancus/trove/blob/main/docs/RESEARCH.md")!)
            }
            Section {
                Button("Remove Trove from this device…", role: .destructive) { model.resetThisDevice(); dismiss() }
            } footer: {
                Text("Removes the keys and local copy from this device only. Your vault in iCloud and on other devices is untouched.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .frame(minWidth: 480, minHeight: 560)
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

private struct DevicesSection: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [RelayClient.Device] = []
    @State private var adding = false

    var body: some View {
        Section("Devices") {
            Button { adding = true } label: { Label("Add a device", systemImage: "qrcode") }
                .sheet(isPresented: $adding) { AddDeviceView() }
            ForEach(devices) { d in
                HStack {
                    Image(systemName: d.kind == "mac" ? "laptopcomputer" : d.kind == "ipad" ? "ipad" : "iphone")
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
    @State private var url = ""
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
            Text("Adds instant sync, email-in, GoodNotes backups, the browser extension and cloud AI. Everything stays end-to-end encrypted; see server/README.")
        }
    }
}

private struct AISection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("This device", value: OnDeviceAI.isAvailable ? "Apple Intelligence ✓" : "Basic")
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
            Text("Search by meaning, text in images, dates and places work on every device. Smart titles and summaries come from Apple Intelligence (your iPad does it for everything). Cloud AI sends that item's text to Claude via your relay; items processed this way get a ☁︎ badge.")
        }
    }
}

private struct IntegrationsSection: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var choosingObsidian = false

    var body: some View {
        Section("Bring things in") {
            Button { importing = true } label: { Label("Import files (Kindle My Clippings, bookmarks, CSV, Markdown, PDFs…)", systemImage: "square.and.arrow.down") }
            #if os(macOS)
            Toggle("Mirror Apple Notes into Trove search", isOn: Binding(
                get: { model.config?.appleNotesImport ?? false },
                set: { on in model.updateConfig { $0.appleNotesImport = on }; if on { Task { await model.syncNow() } } }))
            Button { choosingObsidian = true } label: {
                Label(model.config?.obsidianFolder.map { "Obsidian vault: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Sync with an Obsidian vault…", systemImage: "point.3.connected.trianglepath.dotted")
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
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls, source: .import) } }
        }
        .fileImporter(isPresented: $choosingObsidian, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.updateConfig { $0.obsidianFolder = url.path } }
        }
    }
}

struct CopyRow: View {
    let title: String
    let value: String
    @State private var copied = false

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
