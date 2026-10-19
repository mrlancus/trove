import Foundation
import Testing
import Crypto
@testable import TroveCore

struct Fixture: Decodable {
    struct Case: Decodable { var name: String; var plaintext: String; var box: String }
    var vaultPrivateKey: String
    var vaultPublicKey: String
    var symmetricKey: String
    var cases: [Case]

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "trv1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

@Suite struct CryptoTests {
    @Test func roundTripsSymmetricAndSealedAcrossChunkBoundaries() throws {
        let keys = VaultKeys.generate()
        for size in [0, 1, 15, 16, 17, 63, 64, 65, 1000] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let box = try TRV1.encrypt(data, key: keys.segmentKey, chunkSize: 16)
            #expect(box.count == TRV1.ciphertextLength(plaintext: size, chunkSize: 16, mode: .symmetric))
            #expect(try TRV1.decrypt(box, key: keys.segmentKey) == data)
            let sealed = try TRV1.seal(data, to: keys.publicKey, chunkSize: 16)
            #expect(sealed.count == TRV1.ciphertextLength(plaintext: size, chunkSize: 16, mode: .sealed))
            #expect(try TRV1.unseal(sealed, with: keys.agreementKey) == data)
        }
    }

    @Test func rejectsTamperingTruncationAndWrongKeys() throws {
        let keys = VaultKeys.generate()
        let box = try TRV1.encrypt(Data(repeating: 9, count: 100), key: keys.blobKey, chunkSize: 32)
        var tampered = box
        tampered[30] ^= 1
        #expect(throws: TRV1.Failure.authenticationFailed) { try TRV1.decrypt(tampered, key: keys.blobKey) }
        #expect(throws: TRV1.Failure.authenticationFailed) { try TRV1.decrypt(box.dropLast(20), key: keys.blobKey) }
        #expect(throws: TRV1.Failure.authenticationFailed) { try TRV1.decrypt(box + Data([0]), key: keys.blobKey) }
        #expect(throws: TRV1.Failure.authenticationFailed) { try TRV1.decrypt(box, key: keys.segmentKey) }
        let sealed = try TRV1.seal(Data("x".utf8), to: keys.publicKey)
        #expect(throws: TRV1.Failure.authenticationFailed) { try TRV1.unseal(sealed, with: VaultKeys.generate().agreementKey) }
        #expect(throws: TRV1.Failure.badMagic) { try TRV1.decrypt(Data("nope nope nope nope".utf8), key: keys.blobKey) }
    }

    /// The Worker (server/src/crypto.ts) and TroveCore must agree byte-for-byte.
    @Test func decryptsWorkerProducedFixtures() throws {
        let f = try Fixture.load()
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(Data(base64URL: f.vaultPrivateKey)))
        #expect(privateKey.publicKey.rawRepresentation.base64URL == f.vaultPublicKey)
        let symmetric = SymmetricKey(data: try #require(Data(base64URL: f.symmetricKey)))
        for c in f.cases {
            let box = try #require(Data(base64URL: c.box))
            let expected = try #require(Data(base64URL: c.plaintext))
            let plain = TRV1.mode(of: box) == .sealed ? try TRV1.unseal(box, with: privateKey) : try TRV1.decrypt(box, key: symmetric)
            #expect(plain == expected, "case \(c.name)")
            if c.name == "envelope" {
                let env = try InboxEnvelope(decoding: plain)
                #expect(env.header.title == "Example")
                #expect(env.header.url == "https://example.com/a")
                #expect(env.body == Data("hello".utf8))
            }
        }
    }

    /// Writes a Swift-sealed vector the Worker side can check (`TROVE_SWIFT_VECTOR=path swift test`).
    @Test func exportsSwiftVectorWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["TROVE_SWIFT_VECTOR"] else { return }
        let f = try Fixture.load()
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: #require(Data(base64URL: f.vaultPublicKey)))
        let plain = Data("sealed by Swift ✅".utf8)
        let out = ["plaintext": plain.base64URL, "box": try TRV1.seal(plain, to: pub, chunkSize: 8).base64URL]
        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: path))
    }

    @Test func vaultKeysExportImportAndDerive() throws {
        let keys = VaultKeys.generate()
        let restored = try VaultKeys(keys.exported())
        #expect(restored.publicKeyBase64URL == keys.publicKeyBase64URL)
        #expect(restored.blobId(for: Data("abc".utf8)) == keys.blobId(for: Data("abc".utf8)))
        #expect(keys.blobId(for: Data("abc".utf8)).count == 64)
        #expect(keys.blobId(for: Data("abc".utf8)) != VaultKeys.generate().blobId(for: Data("abc".utf8)))
        let box = try TRV1.encrypt(Data("x".utf8), key: keys.segmentKey)
        #expect(try TRV1.decrypt(box, key: restored.segmentKey) == Data("x".utf8))
    }

    @Test func inboxEnvelopeRoundTrip() throws {
        let keys = VaultKeys.generate()
        let env = InboxEnvelope(header: .init(source: "ios", name: "a.txt", mime: "text/plain", title: "Hi"), body: Data("body".utf8))
        let opened = try InboxEnvelope.open(env.sealed(for: keys), with: keys)
        #expect(try InboxEnvelope.open(env.sealed(toPublicKey: keys.publicKeyBase64URL), with: keys).body == Data("body".utf8))
        #expect(opened.header.title == "Hi")
        #expect(opened.body == Data("body".utf8))
    }

    @Test func base64URL() {
        let d = Data((0..<40).map { UInt8($0 * 7 % 256) })
        #expect(Data(base64URL: d.base64URL) == d)
        #expect(!d.base64URL.contains("="))
    }
}

@Suite struct PairingTests {
    @Test func qrPayloadRoundTripsAsURLOrCode() throws {
        let keys = VaultKeys.generate()
        let p = PairingPayload(vaultId: "V", keys: keys.exported(), encrypted: true, relayURL: "https://relay.example", pairingCode: "tpc_x")
        #expect(PairingPayload(scanned: p.url.absoluteString) == p)
        #expect(PairingPayload(scanned: "  \(p.setupCode)\n") == p)
        #expect(PairingPayload(scanned: "nonsense") == nil)
        #expect(try VaultKeys(p.keys).publicKeyBase64URL == keys.publicKeyBase64URL)
    }
}
