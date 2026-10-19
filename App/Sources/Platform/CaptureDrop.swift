import Foundation
import TroveCore

/// How extensions and intents hand things to Trove without the vault's secret keys:
/// seal the envelope to the vault *public* key, then post it to the relay inbox (so other devices
/// get it right away) or, offline / no relay, drop it in the App Group inbox for the app to import.
enum CaptureDrop {
    enum Failure: LocalizedError {
        case notSetUp
        var errorDescription: String? { "Open Trove once on this device to finish setting it up." }
    }

    @discardableResult
    static func send(_ envelope: InboxEnvelope) async throws -> String {
        guard let capture = SharedConfig.loadCapture() else { throw Failure.notSetUp }
        let sealed = try envelope.sealed(toPublicKey: capture.vaultPublicKey)
        if let url = capture.relayURL.flatMap(URL.init(string:)), let vault = capture.relayVaultId, let token = capture.inboxToken {
            let client = RelayClient(baseURL: url, vaultId: vault, token: token)
            if (try? await client.postInbox(sealed: sealed, source: envelope.header.source)) != nil { return "relay" }
        }
        let file = SharedConfig.localInbox.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).trv")
        try sealed.write(to: file, options: .atomic)
        return "local"
    }

    static func text(_ text: String, title: String? = nil, source: String = "ios") -> InboxEnvelope {
        InboxEnvelope(header: .init(source: source, mime: "text/plain", title: title), body: Data(text.utf8))
    }

    static func link(_ url: URL, title: String? = nil, note: String = "", source: String = "ios") -> InboxEnvelope {
        InboxEnvelope(header: .init(source: source, mime: "text/plain", url: url.absoluteString, title: title), body: Data(note.utf8))
    }

    static func file(_ data: Data, name: String, mime: String, source: String = "ios") -> InboxEnvelope {
        InboxEnvelope(header: .init(source: source, name: name, mime: mime, title: (name as NSString).deletingPathExtension), body: data)
    }
}
