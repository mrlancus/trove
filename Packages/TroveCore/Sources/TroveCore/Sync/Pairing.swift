import Foundation

/// What the QR code carries from an existing device to a new one. It holds the vault secrets, so
/// it is only ever shown on screen (never sent to the relay) and the pairing code inside is single-use.
public struct PairingPayload: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var vaultId: String
    public var keys: VaultKeys.Exported
    public var encrypted: Bool
    public var relayURL: String?
    public var pairingCode: String?

    public init(vaultId: String, keys: VaultKeys.Exported, encrypted: Bool, relayURL: String? = nil, pairingCode: String? = nil) {
        self.vaultId = vaultId
        self.keys = keys
        self.encrypted = encrypted
        self.relayURL = relayURL
        self.pairingCode = pairingCode
    }

    public static let scheme = "trove"

    /// `trove://pair?d=<base64url JSON>`; also typeable as a setup code (just the `d` value).
    public var url: URL {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return URL(string: "\(Self.scheme)://pair?d=\(json.base64URL)")!
    }

    public var setupCode: String { (try? JSONEncoder().encode(self))?.base64URL ?? "" }

    public init?(scanned text: String) {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: code), comps.scheme == Self.scheme, let d = comps.queryItems?.first(where: { $0.name == "d" })?.value {
            code = d
        }
        guard let data = Data(base64URL: code), let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else { return nil }
        self = payload
    }
}

/// Code pasted into the browser extension (extensions/browser/trv1.js `parseSetupCode`). It holds an
/// inbox token and the vault *public* key only, so a browser can add to the inbox but never read.
public struct BrowserSetupCode: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var relayURL: String
    public var vaultId: String
    public var inboxToken: String
    public var vaultPublicKey: String

    public init(relayURL: String, vaultId: String, inboxToken: String, vaultPublicKey: String) {
        self.relayURL = relayURL
        self.vaultId = vaultId
        self.inboxToken = inboxToken
        self.vaultPublicKey = vaultPublicKey
    }

    public var code: String { (try? JSONEncoder().encode(self))?.base64URL ?? "" }
}

/// Pulls sealed inbox entries (email, GoodNotes, browser, share sheet) from the relay into the library.
public enum InboxSync {
    public struct Result: Sendable, Equatable {
        public var imported: [String] = []
        public var errors: [String] = []
    }

    public static func run(client: RelayClient, keys: VaultKeys, library: Library) async -> Result {
        var result = Result()
        let entries: [RelayClient.InboxEntry]
        do { entries = try await client.inbox() } catch {
            result.errors.append("list: \(error)")
            return result
        }
        for entry in entries {
            do {
                let sealed = try await client.inboxEntry(entry.id)
                let envelope = try InboxEnvelope.open(sealed, with: keys)
                result.imported.append(try await library.importInbox(envelope))
                // Make the item durable in the journal before deleting the server copy.
                _ = await library.sync()
                try await client.ackInbox(entry.id)
            } catch {
                result.errors.append("\(entry.id): \(error)")
            }
        }
        return result
    }
}
