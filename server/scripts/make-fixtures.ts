// Generates TRV1 test vectors with the Worker's implementation for the Swift tests
// (Packages/TroveCore/Tests/TroveCoreTests/Fixtures/trv1.json).
// Run: node --experimental-strip-types scripts/make-fixtures.ts > ../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/trv1.json
import { b64uEncode, envelopePrefix, importSymmetricKey, seal } from "../src/crypto.ts";

const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
const jwk = await crypto.subtle.exportKey("jwk", keys.privateKey);
const publicKey = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
const symmetric = crypto.getRandomValues(new Uint8Array(32));
const symKey = await importSymmetricKey(symmetric);

const text = new TextEncoder().encode("Hello from the Worker — 🧠 Trove ".repeat(9));
const big = new Uint8Array(70_000).map((_, i) => (i * 7) % 256);
const prefix = envelopePrefix({ v: 1, source: "web", receivedAt: "2026-10-19T12:00:00Z", url: "https://example.com/a", title: "Example" });
const envelope = new Uint8Array(prefix.length + 5);
envelope.set(prefix);
envelope.set(new TextEncoder().encode("hello"), prefix.length);

console.log(JSON.stringify({
  vaultPrivateKey: jwk.d,
  vaultPublicKey: b64uEncode(publicKey),
  symmetricKey: b64uEncode(symmetric),
  cases: [
    { name: "sealed-small-chunks", plaintext: b64uEncode(text), box: b64uEncode(await seal(text, { recipientPublicKey: publicKey, chunkSize: 32 })) },
    { name: "sealed-empty", plaintext: "", box: b64uEncode(await seal(new Uint8Array(0), { recipientPublicKey: publicKey })) },
    { name: "sealed-70k", plaintext: b64uEncode(big), box: b64uEncode(await seal(big, { recipientPublicKey: publicKey })) },
    { name: "symmetric", plaintext: b64uEncode(text), box: b64uEncode(await seal(text, { key: symKey, chunkSize: 100 })) },
    { name: "envelope", plaintext: b64uEncode(envelope), box: b64uEncode(await seal(envelope, { recipientPublicKey: publicKey })) },
  ],
}, null, 1));
