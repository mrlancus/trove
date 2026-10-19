import CoreImage.CIFilterBuiltins
import SwiftUI
import TroveCore
#if os(iOS)
import VisionKit
#endif

/// Shows the QR code (and copyable setup code) that adds another device to this vault.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var payload: PairingPayload?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Add a device").font(.title2.bold())
            Text("On the new device, open Trove → “I already use Trove” and scan this code. It contains your vault key, so only show it to your own devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let payload {
                QRCodeView(text: payload.url.absoluteString)
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                Button { Pasteboard.copy(payload.setupCode) } label: { Label("Copy setup code instead", systemImage: "doc.on.doc") }
                if payload.pairingCode != nil {
                    Text("The relay part of this code works once, for 10 minutes.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .task {
            do { payload = try await model.vault.pairingPayload() } catch { self.error = error.localizedDescription }
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
