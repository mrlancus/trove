// TRV1 symmetric mode (docs/PROTOCOL.md §2) for journal segments and attachments.
// Byte-compatible with Packages/TroveCore/Sources/TroveCore/Crypto/TRV1.swift and server/src/crypto.ts.
import { concat, u32 } from "./bytes.js";

const MAGIC = new Uint8Array([0x54, 0x52, 0x56, 0x31]);
const TAG = 16;
export const CHUNK = 64 * 1024;

export function isTRV1(data) {
  return data.length >= 17 && MAGIC.every((b, i) => data[i] === b);
}

export async function encrypt(plaintext, key, chunkSize = CHUNK) {
  const prefix = crypto.getRandomValues(new Uint8Array(8));
  const header = concat(MAGIC, new Uint8Array([1]), u32(chunkSize), prefix);
  const count = plaintext.length === 0 ? 1 : Math.ceil(plaintext.length / chunkSize);
  const parts = [header];
  for (let i = 0; i < count; i++) {
    const chunk = plaintext.subarray(i * chunkSize, Math.min((i + 1) * chunkSize, plaintext.length));
    const aad = concat(header, new Uint8Array([i === count - 1 ? 1 : 0]));
    const iv = concat(prefix, u32(i));
    parts.push(new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, key, chunk)));
  }
  return concat(...parts);
}

export async function decrypt(box, key) {
  if (!isTRV1(box)) throw new Error("not a TRV1 container");
  if (box[4] !== 1) throw new Error("expected a symmetric (mode 1) container");
  const chunkSize = new DataView(box.buffer, box.byteOffset + 5, 4).getUint32(0);
  const hlen = 17;
  if (box.length < hlen + TAG || chunkSize === 0) throw new Error("truncated");
  const header = box.subarray(0, hlen);
  const prefix = box.subarray(hlen - 8, hlen);
  const parts = [];
  let offset = hlen;
  for (let index = 0; ; index++) {
    const remaining = box.length - offset;
    const last = remaining <= chunkSize + TAG;
    const take = last ? remaining : chunkSize + TAG;
    if (take < TAG) throw new Error("truncated");
    const aad = concat(header, new Uint8Array([last ? 1 : 0]));
    try {
      parts.push(new Uint8Array(await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: concat(prefix, u32(index)), additionalData: aad }, key, box.subarray(offset, offset + take))));
    } catch {
      throw new Error("authentication failed");
    }
    offset += take;
    if (last) break;
  }
  return concat(...parts);
}

/** Opens a sealed (mode 2) container with the vault private key (docs/PROTOCOL.md §2). */
export async function unseal(box, privateKey, vaultPublic) {
  if (!isTRV1(box) || box[4] !== 2) throw new Error("expected a sealed (mode 2) container");
  const chunkSize = new DataView(box.buffer, box.byteOffset + 5, 4).getUint32(0);
  const hlen = 49;
  if (box.length < hlen + TAG || chunkSize === 0) throw new Error("truncated");
  const header = box.subarray(0, hlen);
  const ephPublic = box.subarray(9, 41);
  const prefix = box.subarray(hlen - 8, hlen);
  const peer = await crypto.subtle.importKey("raw", ephPublic, { name: "X25519" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "X25519", public: peer }, privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: concat(ephPublic, vaultPublic), info: new TextEncoder().encode("trove/v1/sealed") },
    hkdf, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
  const parts = [];
  let offset = hlen;
  for (let index = 0; ; index++) {
    const remaining = box.length - offset;
    const last = remaining <= chunkSize + TAG;
    const take = last ? remaining : chunkSize + TAG;
    if (take < TAG) throw new Error("truncated");
    try {
      parts.push(new Uint8Array(await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: concat(prefix, u32(index)), additionalData: concat(header, new Uint8Array([last ? 1 : 0])) }, key, box.subarray(offset, offset + take))));
    } catch {
      throw new Error("authentication failed");
    }
    offset += take;
    if (last) break;
  }
  return concat(...parts);
}

/** Inbox plaintext: `u32 headerLength | header JSON | body` (docs/PROTOCOL.md §4). */
export function parseEnvelope(plain) {
  const length = new DataView(plain.buffer, plain.byteOffset, 4).getUint32(0);
  return { header: JSON.parse(new TextDecoder().decode(plain.subarray(4, 4 + length))), body: plain.subarray(4 + length) };
}
