import CoreImage.CIFilterBuiltins
import SwiftUI
import TroveCore
#if os(iOS)
import VisionKit
#endif

/// Shows the QR code (and copyable setup code) that adds another device to this vault. With the
/// relay it watches the device list and closes itself once the new device has joined.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var payload: PairingPayload?
    @State private var error: String?
    @State private var joined: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Add a device").font(.title2.bold())
            if let joined {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: joined)
                    Text("\(joined) is set up").font(.headline)
                }
                .frame(minHeight: 272)
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("On the new device, open Trove → “I already use Trove” and scan this code. It contains your vault key, so only show it to your own devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let payload {
                    QRCodeView(text: payload.url.absoluteString)
                        .frame(width: 240, height: 240)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    Button {
                        Pasteboard.copy(payload.setupCode)
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy setup code instead", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    if payload.pairingCode != nil {
                        Label("Waiting for the new device…", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(.secondary).symbolEffect(.pulse)
                        Text("The relay part of this code works once, for 10 minutes.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .animation(.spring(duration: 0.4), value: joined)
        .task {
            func snapshot(_ devices: [RelayClient.Device]) -> [String: Double] {
                Dictionary(devices.map { ($0.deviceId, $0.createdAt) }, uniquingKeysWith: { a, _ in a })
            }
            var before = (try? await model.vault.relayClient?.devices()).map(snapshot)
            do { payload = try await model.vault.pairingPayload() } catch { self.error = error.localizedDescription; return }
            guard payload?.pairingCode != nil, let client = model.vault.relayClient else { return }
            // A device that joined after this opened: a new id, or a re-paired one with a new createdAt.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let devices = try? await client.devices() else { continue }
                guard let before else { before = snapshot(devices); continue }
                if let new = devices.first(where: { !$0.revoked && before[$0.deviceId] != $0.createdAt && $0.deviceId != model.config?.deviceId.uppercased() }) {
                    joined = new.name
                    try? await Task.sleep(for: .seconds(1.6))
                    dismiss()
                    return
                }
            }
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
        }
    }

    static func make(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

#if os(iOS)
/// Live camera QR scanner (VisionKit DataScanner).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.hasPrefix("trove://") {
                    done = true
                    scanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}
#endif
