import { describe, expect, it } from "vitest";
import { auth, call, createVault } from "./helpers";

// Checkpoints (PROTOCOL.md §3 "Checkpoints", §4): opaque encrypted blobs the relay only stores.
describe("checkpoints", () => {
  const put = (vaultId: string, token: string, id: string, body: Uint8Array) =>
    call(`/v1/vaults/${vaultId}/checkpoints/${id}`, { method: "PUT", headers: auth(token, { "content-length": String(body.length) }), body });

  it("stores, lists newest first, serves the same bytes and keeps only the newest three", async () => {
    const v = await createVault();
    const list = async () =>
      ((await (await call(`/v1/vaults/${v.vaultId}/checkpoints`, { headers: auth(v.deviceToken) })).json()) as { checkpoints: { id: string; device: string; size: number; createdAt: number }[] }).checkpoints;
    expect(await list()).toEqual([]);
    const bodies = [1, 2, 3, 4].map((n) => new Uint8Array(100 + n).fill(n));
    for (const [n, body] of bodies.entries()) expect((await put(v.vaultId, v.deviceToken, `checkpoint-${n}`, body)).status).toBe(201);
    // The same id again is a no-op.
    expect((await put(v.vaultId, v.deviceToken, "checkpoint-3", bodies[3]!)).status).toBe(200);
    const listed = await list();
    expect(listed.map((c) => c.id)).toEqual(["checkpoint-3", "checkpoint-2", "checkpoint-1"]);
    expect(listed[0]).toMatchObject({ device: v.deviceId, size: 104 });
    const got = await call(`/v1/vaults/${v.vaultId}/checkpoints/checkpoint-3`, { headers: auth(v.deviceToken) });
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(bodies[3]!);
    expect((await call(`/v1/vaults/${v.vaultId}/checkpoints/checkpoint-0`, { headers: auth(v.deviceToken) })).status).toBe(404);
  });

  it("needs a device token and a sane id", async () => {
    const v = await createVault();
    const body = new Uint8Array(10);
    expect((await put(v.vaultId, v.inboxToken, "checkpoint-x", body)).status).toBe(403);
    expect((await call(`/v1/vaults/${v.vaultId}/checkpoints`)).status).toBe(401);
    expect((await put(v.vaultId, v.deviceToken, "bad.id", body)).status).toBe(400);
  });
});
