// Sealed-mode TRV1 + inbox envelope (docs/PROTOCOL.md §2 and §4), browser edition.
// The extension only ever holds the vault *public* key, so it can add to the inbox but never read.
// Kept in step with server/src/crypto.ts; test/trv1.test.mjs checks the Worker can open what this makes.

const MAGIC = new Uint8Array([0x54, 0x52, 0x56, 0x31]);
const CHUNK = 64 * 1024;
const INFO = new TextEncoder().encode("trove/v1/sealed");

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

export function b64uEncode(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64uDecode(text) {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/** Seals `plaintext` (Uint8Array) to the vault's raw X25519 public key. */
export async function seal(plaintext, vaultPublicKey, chunkSize = CHUNK) {
  const eph = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const ephPublic = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const peer = await crypto.subtle.importKey("raw", vaultPublicKey, { name: "X25519" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "X25519", public: peer }, eph.privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: concat(ephPublic, vaultPublicKey), info: INFO },
    hkdf, { name: "AES-GCM", length: 256 }, false, ["encrypt"],
  );
  const prefix = crypto.getRandomValues(new Uint8Array(8));
  const size = new Uint8Array(4);
  new DataView(size.buffer).setUint32(0, chunkSize);
  const header = concat(MAGIC, new Uint8Array([2]), size, ephPublic, prefix);
  const parts = [header];
  const count = plaintext.length === 0 ? 1 : Math.ceil(plaintext.length / chunkSize);
  for (let i = 0; i < count; i++) {
    const iv = new Uint8Array(12);
    iv.set(prefix);
    new DataView(iv.buffer).setUint32(8, i);
    const chunk = plaintext.subarray(i * chunkSize, Math.min((i + 1) * chunkSize, plaintext.length));
    const aad = concat(header, new Uint8Array([i === count - 1 ? 1 : 0]));
    parts.push(new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, key, chunk)));
  }
  return concat(...parts);
}

/** u32 headerLength | header JSON | body */
export function envelope(header, body) {
  const json = new TextEncoder().encode(JSON.stringify({ v: 1, receivedAt: new Date().toISOString(), ...header }));
  const len = new Uint8Array(4);
  new DataView(len.buffer).setUint32(0, json.length);
  return concat(len, json, body);
}

/** Setup code shown by the Trove app: base64url JSON {v, relayURL, vaultId, inboxToken, vaultPublicKey}. */
export function parseSetupCode(code) {
  const json = JSON.parse(new TextDecoder().decode(b64uDecode(code.trim())));
  if (json.v !== 1 || !json.relayURL || !json.vaultId || !json.inboxToken || !json.vaultPublicKey) {
    throw new Error("That doesn't look like a Trove browser setup code.");
  }
  const key = b64uDecode(json.vaultPublicKey);
  if (key.length !== 32) throw new Error("The vault key in that code is invalid.");
  return { relayURL: json.relayURL.replace(/\/$/, ""), vaultId: json.vaultId, inboxToken: json.inboxToken, vaultPublicKey: json.vaultPublicKey };
}
