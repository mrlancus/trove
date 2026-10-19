// Shared by the relay e2e tests: make a vault on a local relay and a setup code for it, like the apps do.
import { b64uEncode, utf8 } from "../public/core/bytes.js";

export const BASE = process.env.TROVE_RELAY_URL ?? "http://127.0.0.1:8787";

export function memoryStorage() {
  const m = new Map();
  return { map: m, get: async (k) => structuredClone(m.get(k)), set: async (k, v) => { m.set(k, structuredClone(v)); }, clear: async () => m.clear() };
}

/** Creates a vault (as the "Mac") and returns its token plus a function that mints setup codes. */
export async function createVault() {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const res = await fetch(`${BASE}/v1/vaults`, { method: "POST", body: JSON.stringify({ vaultPublicKey: b64uEncode(publicKey), deviceName: "Mac", deviceKind: "mac" }) });
  if (res.status !== 201) throw new Error(`create vault: ${res.status}`);
  const mac = await res.json();
  const keys = { v: 1, vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))), privateKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) };
  async function setupCode() {
    const p = await fetch(`${BASE}/v1/vaults/${mac.vaultId}/pairings`, { method: "POST", headers: { authorization: `Bearer ${mac.deviceToken}` } });
    const { pairingCode } = await p.json();
    const payload = { v: 1, vaultId: "icloud-vault-id", keys, encrypted: true, relayURL: BASE, relayVaultId: mac.vaultId, pairingCode, inboxToken: mac.inboxToken };
    return b64uEncode(utf8.encode(JSON.stringify(payload)));
  }
  return { mac, keys, setupCode };
}
