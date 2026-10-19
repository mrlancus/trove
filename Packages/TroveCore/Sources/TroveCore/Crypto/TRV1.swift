import Foundation
import Crypto

/// TRV1 chunked AEAD container (docs/PROTOCOL.md §2). Byte-for-byte compatible with
/// server/src/crypto.ts. Used for journal segments, attachments and the sealed inbox.
public enum TRV1 {
    public static let magic = Data("TRV1".utf8)
    public static let defaultChunkSize = 64 * 1024
    static let tagSize = 16
    static let sealedInfo = Data("trove/v1/sealed".utf8)

    public enum Mode: UInt8, Sendable { case symmetric = 1, sealed = 2 }

    public enum Failure: Error, Equatable {
        case badMagic, unsupportedMode, missingKey, truncated, authenticationFailed
    }

    public static func headerLength(_ mode: Mode) -> Int { 4 + 1 + 4 + (mode == .sealed ? 32 : 0) + 8 }

    public static func ciphertextLength(plaintext: Int, chunkSize: Int = defaultChunkSize, mode: Mode) -> Int {
        let chunks = plaintext == 0 ? 1 : (plaintext + chunkSize - 1) / chunkSize
        return headerLength(mode) + plaintext + tagSize * chunks
    }

    // MARK: Encrypt

    /// Symmetric mode: segments and attachments (key from `VaultKeys`).
    public static func encrypt(_ plaintext: Data, key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws -> Data {
        let prefix = randomBytes(8)
        var header = magic
        header.append(Mode.symmetric.rawValue)
        header.appendUInt32(UInt32(chunkSize))
        header.append(prefix)
        return try sealChunks(plaintext, key: key, header: header, prefix: prefix, chunkSize: chunkSize)
    }

    /// Sealed mode: anyone with the vault *public* key can add; only holders of the private key can read.
    public static func seal(
        _ plaintext: Data,
        to vaultPublicKey: Curve25519.KeyAgreement.PublicKey,
        chunkSize: Int = defaultChunkSize
    ) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let key = try sealedKey(
            secret: ephemeral.sharedSecretFromKeyAgreement(with: vaultPublicKey),
            ephemeralPublic: ephemeralPublic,
            vaultPublic: vaultPublicKey.rawRepresentation
        )
        let prefix = randomBytes(8)
        var header = magic
        header.append(Mode.sealed.rawValue)
        header.appendUInt32(UInt32(chunkSize))
        header.append(ephemeralPublic)
        header.append(prefix)
        return try sealChunks(plaintext, key: key, header: header, prefix: prefix, chunkSize: chunkSize)
    }

    // MARK: Decrypt

    public static func decrypt(_ box: Data, key: SymmetricKey) throws -> Data {
        try open(box) { mode, _ in
            guard mode == .symmetric else { throw Failure.missingKey }
            return key
        }
    }

    public static func unseal(_ box: Data, with vaultPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        try open(box) { mode, ephemeralPublic in
            guard mode == .sealed, let ephemeralPublic else { throw Failure.missingKey }
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
            return try sealedKey(
                secret: vaultPrivateKey.sharedSecretFromKeyAgreement(with: peer),
                ephemeralPublic: ephemeralPublic,
                vaultPublic: vaultPrivateKey.publicKey.rawRepresentation
            )
        }
    }

    /// Reads just the mode, so callers can route a container to the right key.
    public static func mode(of box: Data) -> Mode? {
        guard box.count >= 17, box.prefix(4) == magic else { return nil }
        return Mode(rawValue: box[box.startIndex + 4])
    }

    // MARK: Internals

    static func sealedKey(secret: SharedSecret, ephemeralPublic: Data, vaultPublic: Data) throws -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublic + vaultPublic,
            sharedInfo: sealedInfo,
            outputByteCount: 32
        )
    }

    private static func nonce(_ prefix: Data, _ index: Int) throws -> AES.GCM.Nonce {
        var n = prefix
        n.appendUInt32(UInt32(index))
        return try AES.GCM.Nonce(data: n)
    }

    private static func sealChunks(_ plaintext: Data, key: SymmetricKey, header: Data, prefix: Data, chunkSize: Int) throws -> Data {
        var out = header
        let count = plaintext.isEmpty ? 1 : (plaintext.count + chunkSize - 1) / chunkSize
        out.reserveCapacity(header.count + plaintext.count + tagSize * count)
        for i in 0..<count {
            let start = plaintext.startIndex + i * chunkSize
            let end = min(start + chunkSize, plaintext.endIndex)
            var aad = header
            aad.append(i == count - 1 ? 1 : 0)
            let box = try AES.GCM.seal(plaintext[start..<end], using: key, nonce: nonce(prefix, i), authenticating: aad)
            out.append(box.ciphertext)
            out.append(box.tag)
        }
        return out
    }

    private static func open(_ input: Data, key resolve: (Mode, Data?) throws -> SymmetricKey) throws -> Data {
        let box = Data(input) // zero-based indices
        guard box.count >= 17, box.prefix(4) == magic else { throw Failure.badMagic }
        guard let mode = Mode(rawValue: box[4]) else { throw Failure.unsupportedMode }
        let chunkSize = Int(box.uint32(at: 5))
        let hlen = headerLength(mode)
        guard box.count >= hlen + tagSize, chunkSize > 0 else { throw Failure.truncated }
        let header = Data(box.prefix(hlen))
        let prefix = Data(box[(hlen - 8)..<hlen])
        let key = try resolve(mode, mode == .sealed ? Data(box[9..<41]) : nil)

        var out = Data()
        var offset = hlen
        var index = 0
        while true {
            let remaining = box.count - offset
            let last = remaining <= chunkSize + tagSize
            let take = last ? remaining : chunkSize + tagSize
            guard take >= tagSize else { throw Failure.truncated }
            var aad = header
            aad.append(last ? 1 : 0)
            let chunk = box[offset..<(offset + take)]
            do {
                let sealed = try AES.GCM.SealedBox(
                    nonce: nonce(prefix, index),
                    ciphertext: chunk.dropLast(tagSize),
                    tag: chunk.suffix(tagSize)
                )
                out.append(try AES.GCM.open(sealed, using: key, authenticating: aad))
            } catch {
                throw Failure.authenticationFailed
            }
            offset += take
            index += 1
            if last { break }
        }
        return out
    }

    static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }
}
