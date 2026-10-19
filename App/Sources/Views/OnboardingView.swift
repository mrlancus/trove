import SwiftUI
import TroveCore
import UniformTypeIdentifiers

/// First run: make a new vault or join one from another device.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var encrypted = true
    @State private var pickedFolder: URL?
    @State private var choosingFolder = false
    @State private var payload: PairingPayload?
    @State private var working = false

    enum Step { case welcome, create, join, joinFolder }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            switch step {
            case .welcome: welcome
            case .create: create
            case .join: join
            case .joinFolder: joinFolder
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [.orange.opacity(0.18), .pink.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                pickedFolder = url
            }
        }
        .animation(.spring(duration: 0.4), value: step)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
            Text("Welcome to Trove").font(.largeTitle.bold())
            Text("Save anything. It organises itself, syncs through your own iCloud, and stays encrypted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button { step = .create } label: { Text("Create a new Trove").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { step = .join } label: { Text("I already use Trove on another device").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var create: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where should it live?").font(.title.bold())
            #if os(macOS)
            Text("Your Trove is a folder in iCloud Drive. iCloud syncs it to your other devices in the background, for free.")
                .foregroundStyle(.secondary)
            if VaultStore.iCloudDriveAvailable {
                Label(VaultStore.macICloudFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), systemImage: "icloud")
                    .font(.callout.monospaced())
            } else {
                Label("iCloud Drive isn't turned on. Turn it on in System Settings → Apple Account → iCloud, or choose another folder.", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
            #else
            Text("Choose (or create) a folder named Trove in iCloud Drive. iCloud syncs it to your other devices for free.")
                .foregroundStyle(.secondary)
            #endif
            Button { choosingFolder = true } label: {
                Label(pickedFolder?.lastPathComponent ?? "Choose a different folder…", systemImage: "folder")
            }
            Toggle("Encrypt everything (recommended)", isOn: $encrypted)
            Text(encrypted ? "Files in iCloud are unreadable without your devices. You'll get a recovery code, so keep it safe." :
                    "Notes are readable in Finder/Files. Apple's iCloud encryption still applies.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { step = .welcome }
                Spacer()
                Button {
                    working = true
                    Task {
                        #if os(macOS)
                        await model.createVault(useICloud: pickedFolder == nil, pickedFolder: pickedFolder, encrypted: encrypted)
                        #else
                        await model.createVault(useICloud: false, pickedFolder: pickedFolder, encrypted: encrypted)
                        #endif
                        working = false
                    }
                } label: { if working { ProgressView() } else { Text("Create") } }
                .buttonStyle(.borderedProminent)
                .disabled(working || !canCreate)
            }
        }
    }

    private var canCreate: Bool {
        #if os(macOS)
        return pickedFolder != nil || VaultStore.iCloudDriveAvailable
        #else
        return pickedFolder != nil
        #endif
    }

    private var join: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Join your Trove").font(.title.bold())
            Text("On a device that already has Trove, open Settings → Devices → Add a device. On the website, open Devices & extension → Make a setup code. Then scan the code here or paste it.")
                .foregroundStyle(.secondary)
            PairingInput { scanned in
                payload = scanned
                step = .joinFolder
            }
            Button("Back") { step = .welcome }
        }
    }

    private var joinFolder: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect the Trove folder").font(.title.bold())
            #if os(macOS)
            Text("Using \(VaultStore.macICloudFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")). Choose another folder if yours is elsewhere.")
                .foregroundStyle(.secondary)
            #else
            Text("Pick the Trove folder in iCloud Drive. If this device can't use iCloud, skip it and you'll sync through your relay instead.")
                .foregroundStyle(.secondary)
            #endif
            Button { choosingFolder = true } label: { Label(pickedFolder?.lastPathComponent ?? "Choose the Trove folder…", systemImage: "folder") }
            HStack {
                Button("Back") { step = .join }
                Spacer()
                if payload?.relayURL != nil {
                    Button("Skip (relay only)") { finishJoin(useFolder: false) }
                }
                Button { finishJoin(useFolder: true) } label: { if working { ProgressView() } else { Text("Join") } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
        }
    }

    private func finishJoin(useFolder: Bool) {
        guard let payload else { return }
        working = true
        Task {
            #if os(macOS)
            await model.join(payload, useICloud: useFolder && pickedFolder == nil, pickedFolder: useFolder ? pickedFolder : nil)
            #else
            await model.join(payload, useICloud: false, pickedFolder: useFolder ? pickedFolder : nil)
            #endif
            working = false
        }
    }
}

/// Scan a QR code (iPhone/iPad camera) or paste the setup code (any device).
struct PairingInput: View {
    var onPayload: (PairingPayload) -> Void
    @State private var code = ""
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .sheet(isPresented: $scanning) {
                    QRScannerView { text in
                        scanning = false
                        use(text)
                    }
                    .ignoresSafeArea()
                }
            #endif
            TextField("…or paste the setup code", text: $code, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Use code") { use(code) }.disabled(code.isEmpty)
            }
        }
    }

    private func use(_ text: String) {
        if let payload = PairingPayload(scanned: text) { error = nil; onPayload(payload) } else { error = "That code isn't valid." }
    }
}
