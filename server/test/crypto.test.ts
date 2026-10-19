import { describe, expect, it } from "vitest";
import {
  importSymmetricKey,
  open,
  seal,
  sealStream,
  sealedLength,
  envelopePrefix,
  parseEnvelope,
  b64uDecode,
  b64uEncode,
  MODE_SYMMETRIC,
} from "../src/crypto";

async function keypair() {
  const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const pub = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  return { keys, pub };
}

function bytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = (i * 31 + 7) & 0xff;
  return out;
}

async function streamSeal(data: Uint8Array, pub: Uint8Array, chunkSize: number, pieces: number) {
  const ts = sealStream({ recipientPublicKey: pub, chunkSize });
  const writer = ts.writable.getWriter();
  const step = Math.max(1, Math.ceil(data.length / pieces));
  const writing = (async () => {
    for (let i = 0; i < data.length; i += step) await writer.write(data.subarray(i, i + step));
    await writer.close();
  })();
  const out = new Uint8Array(await new Response(ts.readable).arrayBuffer());
  await writing;
  return out;
}

describe("TRV1 container", () => {
  it("round-trips sealed data of awkward sizes", async () => {
    const { keys, pub } = await keypair();
    for (const size of [0, 1, 15, 16, 17, 64, 65, 200]) {
      const data = bytes(size);
      const box = await seal(data, { recipientPublicKey: pub, chunkSize: 16 });
      expect(box.length).toBe(sealedLength(size, 16));
      const back = await open(box, { recipientPrivateKey: keys.privateKey, recipientPublicKey: pub });
      expect([...back]).toEqual([...data]);
    }
  });

  it("streaming seal matches the predicted length and decrypts", async () => {
    const { keys, pub } = await keypair();
    for (const size of [0, 10, 64, 1000, 4096]) {
      const data = bytes(size);
      const box = await streamSeal(data, pub, 64, 7);
      expect(box.length).toBe(sealedLength(size, 64));
      const back = await open(box, { recipientPrivateKey: keys.privateKey, recipientPublicKey: pub });
      expect(back.length).toBe(size);
      expect([...back]).toEqual([...data]);
    }
  });

  it("symmetric mode round-trips", async () => {
    const key = await importSymmetricKey(bytes(32));
    const box = await seal(bytes(300), { key, chunkSize: 100 });
    expect(box[4]).toBe(MODE_SYMMETRIC);
    expect(box.length).toBe(sealedLength(300, 100, MODE_SYMMETRIC));
    expect((await open(box, { key })).length).toBe(300);
  });

  it("rejects truncation, extension and tampering", async () => {
    const { keys, pub } = await keypair();
    const box = await seal(bytes(100), { recipientPublicKey: pub, chunkSize: 32 });
    const opts = { recipientPrivateKey: keys.privateKey, recipientPublicKey: pub };
    // Cut exactly one whole chunk off the end: the new final chunk was not sealed as "last".
    await expect(open(box.subarray(0, box.length - (100 - 96 + 16)), opts)).rejects.toThrow();
    const extended = new Uint8Array(box.length + 1);
    extended.set(box);
    await expect(open(extended, opts)).rejects.toThrow();
    const tampered = box.slice();
    tampered[60]! ^= 1;
    await expect(open(tampered, opts)).rejects.toThrow();
  });

  it("only the vault key opens a sealed box", async () => {
    const a = await keypair();
    const b = await keypair();
    const box = await seal(bytes(10), { recipientPublicKey: a.pub });
    await expect(open(box, { recipientPrivateKey: b.keys.privateKey, recipientPublicKey: a.pub })).rejects.toThrow();
  });

  it("envelope and base64url helpers round-trip", () => {
    const prefix = envelopePrefix({ v: 1, source: "web", receivedAt: "2026-01-01T00:00:00Z", title: "Hi ✨" });
    const all = new Uint8Array(prefix.length + 3);
    all.set(prefix);
    all.set([1, 2, 3], prefix.length);
    const { header, body } = parseEnvelope(all);
    expect(header.title).toBe("Hi ✨");
    expect([...body]).toEqual([1, 2, 3]);
    const data = bytes(33);
    expect([...b64uDecode(b64uEncode(data))]).toEqual([...data]);
  });
});
