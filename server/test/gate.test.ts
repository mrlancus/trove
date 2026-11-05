// The 8-digit code to create a vault (src/gate.ts, PROTOCOL.md §4, learn-pivot plan §7 E2). The test config
// has no VAULT_CREATE_CODE, so these call the Worker with one added to its env.
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import { b64uEncode } from "../src/crypto";
import { sameCode } from "../src/gate";
import type { Env } from "../src/vault";

const CODE = "48151623";
const withCode = { ...(env as unknown as Env), VAULT_CREATE_CODE: CODE } as Env;

async function create(e: Env, ip: string, code?: string): Promise<Response> {
  const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const pub = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  const headers: Record<string, string> = { "cf-connecting-ip": ip };
  if (code !== undefined) headers["x-trove-create-code"] = code;
  const request = new Request("https://relay.test/v1/vaults", { method: "POST", headers, body: JSON.stringify({ vaultPublicKey: b64uEncode(pub), deviceName: "Mac" }) });
  return worker.fetch(request, e);
}

describe("creating a vault needs the relay's code", () => {
  it("compares codes in constant time, by hash", async () => {
    expect(await sameCode(CODE, CODE)).toBe(true);
    expect(await sameCode("48151624", CODE)).toBe(false);
    expect(await sameCode("", CODE)).toBe(false);
  });

  it("with no secret set, behaves as before", async () => {
    const res = await create({ ...(env as unknown as Env), VAULT_CREATE_CODE: undefined } as Env, "10.0.0.1");
    expect(res.status).toBe(201);
  });

  it("ALLOW_NEW_VAULTS false still closes creation completely", async () => {
    const res = await create({ ...withCode, ALLOW_NEW_VAULTS: "false" } as Env, "10.0.0.2", CODE);
    expect(res.status).toBe(403);
  });

  it("refuses no code and a wrong code with create_code_required; the right code works", async () => {
    const none = await create(withCode, "10.0.1.1");
    expect(none.status).toBe(403);
    expect(await none.json()).toMatchObject({ code: "create_code_required" });
    const wrong = await create(withCode, "10.0.1.1", "00000000");
    expect(wrong.status).toBe(403);
    expect(await wrong.json()).toMatchObject({ code: "create_code_required" });
    const right = await create(withCode, "10.0.1.1", CODE);
    expect(right.status).toBe(201);
    expect(await right.json()).toHaveProperty("deviceToken");
  });

  it("after 5 wrong codes from one IP, the 6th try is refused even with the right code; other IPs still work", async () => {
    for (let i = 0; i < 5; i++) expect((await create(withCode, "10.0.2.1", `1000000${i}`)).status).toBe(403);
    const sixth = await create(withCode, "10.0.2.1", CODE);
    expect(sixth.status).toBe(429);
    expect(await sixth.json()).toMatchObject({ code: "create_code_limited" });
    expect((await create(withCode, "10.0.2.2", CODE)).status).toBe(201);
  });

  it("50 wrong codes across the relay pause creation for everyone", async () => {
    // 6 wrong so far in this file (10.0.1.1 once, 10.0.2.1 five times); 44 more from fresh IPs makes 50.
    for (let i = 0; i < 44; i++) await create(withCode, `10.1.${Math.floor(i / 4)}.${i % 4}`, "99999999");
    const res = await create(withCode, "10.9.9.9", CODE);
    expect(res.status).toBe(429);
  });
});
