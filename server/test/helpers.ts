import { exports } from "cloudflare:workers";
import { b64uEncode } from "../src/crypto";

export const BASE = "https://relay.test";

export function call(path: string, init: RequestInit = {}): Promise<Response> {
  return (exports as unknown as { default: Fetcher }).default.fetch(new Request(BASE + path, init));
}

export interface TestVault {
  vaultId: string;
  deviceId: string;
  deviceToken: string;
  inboxToken: string;
  keys: CryptoKeyPair;
  publicKey: Uint8Array;
}

export async function createVault(deviceName = "Mac"): Promise<TestVault> {
  const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const publicKey = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  const res = await call("/v1/vaults", {
    method: "POST",
    body: JSON.stringify({ vaultPublicKey: b64uEncode(publicKey), deviceName, deviceKind: "mac" }),
  });
  if (res.status !== 201) throw new Error(`createVault failed: ${res.status} ${await res.text()}`);
  const body = (await res.json()) as Omit<TestVault, "keys" | "publicKey">;
  return { ...body, keys, publicKey };
}

export function auth(token: string, extra: Record<string, string> = {}): Record<string, string> {
  return { authorization: `Bearer ${token}`, ...extra };
}
