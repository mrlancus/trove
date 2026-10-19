import { describe, expect, it } from "vitest";
import { open, parseEnvelope, seal } from "../src/crypto";
import { auth, call, createVault } from "./helpers";

const enc = new TextEncoder();

describe("vaults and devices", () => {
  it("health check", async () => {
    const res = await call("/health");
    expect(await res.json()).toMatchObject({ ok: true });
  });

  it("rejects bad public keys and unknown vaults", async () => {
    expect((await call("/v1/vaults", { method: "POST", body: JSON.stringify({ vaultPublicKey: "abc" }) })).status).toBe(400);
    expect((await call("/v1/vaults/AAAAAAAAAAAAAAAAAAAAAA/info", { headers: auth("tdv_x") })).status).toBe(404);
  });

  it("creates a vault, pairs a second device once, lists and revokes", async () => {
    const v = await createVault();
    expect((await call(`/v1/vaults/${v.vaultId}/info`)).status).toBe(401);
    const info = await (await call(`/v1/vaults/${v.vaultId}/info`, { headers: auth(v.deviceToken) })).json();
    expect(info).toMatchObject({ vaultId: v.vaultId, deviceId: v.deviceId, aiEnabled: false });

    const pairing = (await (await call(`/v1/vaults/${v.vaultId}/pairings`, { method: "POST", headers: auth(v.deviceToken) })).json()) as {
      pairingCode: string;
    };
    const joined = await call(`/v1/vaults/${v.vaultId}/devices`, {
      method: "POST",
      body: JSON.stringify({ pairingCode: pairing.pairingCode, deviceName: "iPhone", deviceKind: "ios" }),
    });
    expect(joined.status).toBe(201);
    const phone = (await joined.json()) as { deviceId: string; deviceToken: string };
    const reuse = await call(`/v1/vaults/${v.vaultId}/devices`, { method: "POST", body: JSON.stringify({ pairingCode: pairing.pairingCode }) });
    expect(reuse.status).toBe(403);

    const list = (await (await call(`/v1/vaults/${v.vaultId}/devices`, { headers: auth(v.deviceToken) })).json()) as { devices: unknown[] };
    expect(list.devices).toHaveLength(2);

    expect((await call(`/v1/vaults/${v.vaultId}/devices/${phone.deviceId}`, { method: "DELETE", headers: auth(v.deviceToken) })).status).toBe(204);
    expect((await call(`/v1/vaults/${v.vaultId}/info`, { headers: auth(phone.deviceToken) })).status).toBe(401);
  });

  it("keeps a proposed device id when it is a free UUID", async () => {
    const v = await createVault();
    const pairing = (await (await call(`/v1/vaults/${v.vaultId}/pairings`, { method: "POST", headers: auth(v.deviceToken) })).json()) as { pairingCode: string };
    const id = "0A1B2C3D-0000-4000-8000-00000000ABCD";
    const joined = (await (await call(`/v1/vaults/${v.vaultId}/devices`, {
      method: "POST",
      body: JSON.stringify({ pairingCode: pairing.pairingCode, deviceName: "iPad", deviceId: id.toLowerCase() }),
    })).json()) as { deviceId: string };
    expect(joined.deviceId).toBe(id);
  });

  it("inbox tokens cannot read anything", async () => {
    const v = await createVault();
    expect((await call(`/v1/vaults/${v.vaultId}/segments`, { headers: auth(v.inboxToken) })).status).toBe(403);
    expect((await call(`/v1/vaults/${v.vaultId}/info`, { headers: auth(v.inboxToken) })).status).toBe(403);
  });
});

describe("journal segments", () => {
  it("stores, lists by cursor, is idempotent and protects other devices' journals", async () => {
    const v = await createVault();
    const body = enc.encode("TRV1-fake-ciphertext-1");
    const put = (dev: string, first: number, last: number, data: Uint8Array) =>
      call(`/v1/vaults/${v.vaultId}/segments/${dev}/${first}/${last}`, { method: "PUT", headers: auth(v.deviceToken), body: data });

    const first = await put(v.deviceId, 1, 5, body);
    expect(first.status).toBe(201);
    const { cursor } = (await first.json()) as { cursor: number };
    const again = await put(v.deviceId, 1, 5, body);
    expect(again.status).toBe(200);
    expect(((await again.json()) as { cursor: number }).cursor).toBe(cursor);
    expect((await put(v.deviceId, 1, 5, enc.encode("different"))).status).toBe(409);
    expect((await put("SOMEONE-ELSE", 1, 1, body)).status).toBe(403);
    expect((await put(v.deviceId, 0, 1, body)).status).toBe(400);
    await put(v.deviceId, 6, 9, enc.encode("second"));

    const list = (await (await call(`/v1/vaults/${v.vaultId}/segments?after=0`, { headers: auth(v.deviceToken) })).json()) as {
      segments: { cursor: number; first: number; last: number }[];
    };
    expect(list.segments.map((s) => [s.first, s.last])).toEqual([[1, 5], [6, 9]]);
    const after = (await (await call(`/v1/vaults/${v.vaultId}/segments?after=${cursor}`, { headers: auth(v.deviceToken) })).json()) as {
      segments: unknown[];
    };
    expect(after.segments).toHaveLength(1);

    const got = await call(`/v1/vaults/${v.vaultId}/segments/${v.deviceId}/1/5`, { headers: auth(v.deviceToken) });
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(body);
  });
});

describe("blobs", () => {
  it("puts once, gets back, validates ids", async () => {
    const v = await createVault();
    const id = "a".repeat(64);
    const data = enc.encode("encrypted attachment bytes");
    const put = () => call(`/v1/vaults/${v.vaultId}/blobs/${id}`, { method: "PUT", headers: auth(v.deviceToken), body: data });
    expect((await put()).status).toBe(201);
    expect((await put()).status).toBe(200);
    const got = await call(`/v1/vaults/${v.vaultId}/blobs/${id}`, { headers: auth(v.deviceToken) });
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(data);
    expect((await call(`/v1/vaults/${v.vaultId}/blobs/nothex`, { method: "PUT", headers: auth(v.deviceToken), body: data })).status).toBe(400);
  });
});

describe("sealed inbox", () => {
  it("accepts client-sealed uploads with an inbox token; devices list, fetch, decrypt and ack", async () => {
    const v = await createVault();
    const sealed = await seal(enc.encode("hello from the browser"), { recipientPublicKey: v.publicKey });
    const posted = await call(`/v1/vaults/${v.vaultId}/inbox`, {
      method: "POST",
      headers: auth(v.inboxToken, { "x-trove-source": "web" }),
      body: sealed,
    });
    expect(posted.status).toBe(201);
    const { id } = (await posted.json()) as { id: string };

    const list = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as {
      entries: { id: string; source: string }[];
    };
    expect(list.entries).toEqual([expect.objectContaining({ id, source: "web" })]);

    const got = new Uint8Array(await (await call(`/v1/vaults/${v.vaultId}/inbox/${id}`, { headers: auth(v.deviceToken) })).arrayBuffer());
    const plain = await open(got, { recipientPrivateKey: v.keys.privateKey, recipientPublicKey: v.publicKey });
    expect(new TextDecoder().decode(plain)).toBe("hello from the browser");

    expect((await call(`/v1/vaults/${v.vaultId}/inbox/${id}`, { method: "DELETE", headers: auth(v.deviceToken) })).status).toBe(204);
    const after = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as { entries: unknown[] };
    expect(after.entries).toHaveLength(0);
  });

  it("server-side sealing (email path) produces an envelope only the vault can open", async () => {
    const v = await createVault();
    const { env } = await import("cloudflare:workers");
    const stub = (env as unknown as { VAULT: DurableObjectNamespace }).VAULT.get(
      (env as unknown as { VAULT: DurableObjectNamespace }).VAULT.idFromName(v.vaultId),
    );
    const res = await stub.fetch(
      new Request("https://vault/internal/inbox", {
        method: "POST",
        headers: { "x-trove-envelope": JSON.stringify({ v: 1, source: "email", receivedAt: "2026-10-19T00:00:00Z", title: "Receipt" }) },
        body: enc.encode("<p>Thanks for your order</p>"),
      }),
    );
    expect(res.status).toBe(201);
    const { id } = (await res.json()) as { id: string };
    const got = new Uint8Array(await (await call(`/v1/vaults/${v.vaultId}/inbox/${id}`, { headers: auth(v.deviceToken) })).arrayBuffer());
    const { header, body } = parseEnvelope(await open(got, { recipientPrivateKey: v.keys.privateKey, recipientPublicKey: v.publicKey }));
    expect(header).toMatchObject({ source: "email", title: "Receipt" });
    expect(new TextDecoder().decode(body)).toBe("<p>Thanks for your order</p>");
  });
});

describe("AI routes", () => {
  it("are off by default and need configuration when enabled", async () => {
    const v = await createVault();
    const enrich = () =>
      call(`/v1/vaults/${v.vaultId}/ai/enrich`, { method: "POST", headers: auth(v.deviceToken), body: JSON.stringify({ text: "x" }) });
    expect((await enrich()).status).toBe(403);
    await call(`/v1/vaults/${v.vaultId}/settings`, { method: "PUT", headers: auth(v.deviceToken), body: JSON.stringify({ aiEnabled: true }) });
    // No ANTHROPIC_API_KEY in tests → clear 503 rather than a crash.
    expect((await enrich()).status).toBe(503);
  });
});

describe("live websocket", () => {
  it("pushes a notification when another device uploads a segment", async () => {
    const v = await createVault();
    const res = await call(`/v1/vaults/${v.vaultId}/live?token=${v.deviceToken}`, { headers: { upgrade: "websocket" } });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    const message = new Promise<string>((resolve) => ws.addEventListener("message", (e) => resolve(e.data as string)));
    await call(`/v1/vaults/${v.vaultId}/segments/${v.deviceId}/1/1`, { method: "PUT", headers: auth(v.deviceToken), body: enc.encode("x") });
    expect(JSON.parse(await message)).toMatchObject({ type: "segment", device: v.deviceId, first: 1, last: 1 });
    ws.close();
  });
});
