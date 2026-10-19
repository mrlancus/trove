import Foundation
import Crypto

/// The vault's secrets (PROTOCOL.md §1). The app stores `exported()` in the Keychain and moves it
/// between devices only through the pairing QR code; the relay never sees it.
public struct VaultKeys: Sendable {
    public let vaultKey: SymmetricKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init(vaultKey: SymmetricKey, agreementKey: Curve25519.KeyAgreement.PrivateKey) {
        self.vaultKey = vaultKey
        self.agreementKey = agreementKey
    }

    public static func generate() -> VaultKeys {
        VaultKeys(vaultKey: SymmetricKey(size: .bits256), agreementKey: Curve25519.KeyAgreement.PrivateKey())
    }

    public var publicKey: Curve25519.KeyAgreement.PublicKey { agreementKey.publicKey }
    public var publicKeyBase64URL: String { publicKey.rawRepresentation.base64URL }

    public var segmentKey: SymmetricKey { derive("trove/v1/segment") }
    public var blobKey: SymmetricKey { derive("trove/v1/blob") }
    var blobIdKey: SymmetricKey { derive("trove/v1/blob-id") }

    private func derive(_ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Deterministic attachment id: HMAC(blobIdKey, plaintext), lowercase hex.
    public func blobId(for plaintext: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: plaintext, using: blobIdKey)).hex
    }

    // MARK: Export / import (Keychain + pairing QR)

    public struct Exported: Codable, Equatable, Sendable {
        public var v: Int = 1
        public var vaultKey: String     // b64u
        public var privateKey: String   // b64u raw X25519
    }

    public func exported() -> Exported {
        Exported(
            vaultKey: vaultKey.withUnsafeBytes { Data($0) }.base64URL,
            privateKey: agreementKey.rawRepresentation.base64URL
        )
    }

    public init(_ e: Exported) throws {
        guard let k = Data(base64URL: e.vaultKey), k.count == 32, let p = Data(base64URL: e.privateKey) else {
            throw TRV1.Failure.missingKey
        }
        self.init(vaultKey: SymmetricKey(data: k), agreementKey: try .init(rawRepresentation: p))
    }
}
