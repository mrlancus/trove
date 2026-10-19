// Vault keys for the browser (docs/PROTOCOL.md §1, §7). Raw key bytes are used once and turned into
// non-extractable CryptoKeys, which are what gets stored, so page script can use them but never
// read the key bytes back.
import { b64uDecode, b64uEncode, utf8 } from "./bytes.js";

async function derive(hkdf, info, algorithm, usages) {
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: utf8.encode(info) },
    hkdf, algorithm, false, usages);
}

/** From `VaultKeys.Exported` ({v, vaultKey, privateKey}) to the keys the web app needs. */
export async function importVaultKeys(exported) {
  const raw = b64uDecode(exported.vaultKey);
  if (raw.length !== 32) throw new Error("bad vault key");
  const hkdf = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  raw.fill(0);
  return {
    segment: await derive(hkdf, "trove/v1/segment", { name: "AES-GCM", length: 256 }, ["encrypt", "decrypt"]),
    blob: await derive(hkdf, "trove/v1/blob", { name: "AES-GCM", length: 256 }, ["encrypt", "decrypt"]),
    blobId: await derive(hkdf, "trove/v1/blob-id", { name: "HMAC", hash: "SHA-256", length: 256 }, ["sign"]),
  };
}

// ---------- vault creation, recovery and the sealed inbox ----------

// PKCS#8 wrapper for a raw 32-byte X25519 private key (OID 1.3.101.110).
const PKCS8_X25519 = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);

/** New vault secrets in the apps' `VaultKeys.Exported` format, plus the public key (b64u). */
export async function generateVaultSecrets() {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    exported: { v: 1, vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))), privateKey: b64uEncode(pkcs8.subarray(pkcs8.length - 32)) },
    publicKey: b64uEncode(publicKey),
  };
}

/**
 * The vault private key as a non-extractable CryptoKey (for opening the sealed inbox and recovery
 * challenges), plus its public key, which is checked against the vault's.
 */
export async function importInboxKey(privateKeyB64u) {
  const raw = b64uDecode(privateKeyB64u);
  if (raw.length !== 32) throw new Error("bad private key");
  const pkcs8 = new Uint8Array(PKCS8_X25519.length + 32);
  pkcs8.set(PKCS8_X25519);
  pkcs8.set(raw, PKCS8_X25519.length);
  const temp = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "X25519" }, true, ["deriveBits"]);
  const { x } = await crypto.subtle.exportKey("jwk", temp);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "X25519" }, false, ["deriveBits"]);
  pkcs8.fill(0);
  raw.fill(0);
  return { privateKey, publicKey: x };
}
