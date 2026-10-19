// Vault keys for the browser (docs/PROTOCOL.md §1). The raw vault key is used once to derive
// non-extractable CryptoKeys, which are what gets stored, so page script can use them but never
// read the key bytes back. The X25519 private key isn't needed here (the apps open the inbox) and
// is never kept.
import { b64uDecode, utf8 } from "./bytes.js";

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
