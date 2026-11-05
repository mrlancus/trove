// Study groups (src/groups.ts, PROTOCOL.md §4 "Study groups", study-with-friends prompt §2–3).
import { describe, expect, it } from "vitest";
import { b64uEncode } from "../src/crypto";
import { auth, call, createVault, type TestVault } from "./helpers";

const key = () => b64uEncode(crypto.getRandomValues(new Uint8Array(32)));
/** Stands in for a TRV1 body: the relay only checks the magic and the size, it can't read it. */
const sealed = (n = 64) => {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b.subarray(0, Math.min(n, 65536)));
  b.set(new TextEncoder().encode("TRV1"), 0);
  return b64uEncode(b);
};
interface Who { v: TestVault; memberId: string; memberToken: string }
const g = (w: Who, groupId: string, path = "", init: RequestInit = {}) =>
  call(`/v1/vaults/${w.v.vaultId}/groups/${groupId}${path}`, {
    ...init,
    headers: { ...auth(w.v.deviceToken), "x-trove-member": w.memberToken, ...(init.headers as Record<string, string> | undefined) },
  });
const post = (w: Who, groupId: string, path: string, body: unknown) => g(w, groupId, path, { method: "POST", body: JSON.stringify(body) });

async function newGroup(): Promise<{ groupId: string; owner: Who }> {
  const v = await createVault();
  const res = await call(`/v1/vaults/${v.vaultId}/groups`, { method: "POST", headers: auth(v.deviceToken), body: JSON.stringify({ memberKey: key() }) });
  expect(res.status).toBe(201);
  const b = (await res.json()) as { groupId: string; memberId: string; memberToken: string; epoch: number };
  expect(b.epoch).toBe(1);
  return { groupId: b.groupId, owner: { v, memberId: b.memberId, memberToken: b.memberToken } };
}

async function invite(w: Who, groupId: string, maxUses?: number): Promise<string> {
  const res = await post(w, groupId, "/invites", maxUses ? { maxUses } : {});
  expect(res.status).toBe(201);
  return ((await res.json()) as { secret: string }).secret;
}

async function join(groupId: string, secret: string, name = "Friend's iPad"): Promise<Who> {
  const v = await createVault(name);
  const res = await call(`/v1/vaults/${v.vaultId}/groups/${groupId}/members`, { method: "POST", headers: auth(v.deviceToken), body: JSON.stringify({ invite: secret, memberKey: key() }) });
  expect(res.status).toBe(201);
  const b = (await res.json()) as { memberId: string; memberToken: string };
  return { v, ...b };
}

const entries = async (w: Who, groupId: string) =>
  (await (await g(w, groupId, "/entries?after=0")).json()) as { entries: { id: string; kind: string; member: string; body: string; challenge?: string; about?: string }[]; waiting: { challenge: string; submitted: number }[] };

describe("study groups", () => {
  it("needs a device of a vault on this relay, and a member token for the group", async () => {
    const { groupId, owner } = await newGroup();
    expect((await call(`/v1/vaults/${owner.v.vaultId}/groups`, { method: "POST", body: JSON.stringify({ memberKey: key() }) })).status).toBe(401);
    expect((await call(`/v1/vaults/${owner.v.vaultId}/groups`, { method: "POST", headers: auth(owner.v.inboxToken), body: JSON.stringify({ memberKey: key() }) })).status).toBe(403);
    expect((await call(`/v1/vaults/${owner.v.vaultId}/groups/${groupId}`, { headers: auth(owner.v.deviceToken) })).status).toBe(403);
    const stranger = await createVault("Stranger");
    expect((await call(`/v1/vaults/${stranger.vaultId}/groups/${groupId}`, { headers: { ...auth(stranger.deviceToken), "x-trove-member": "mem_guess" } })).status).toBe(403);
    expect((await g(owner, groupId)).status).toBe(200);
    expect((await call(`/v1/vaults/${owner.v.vaultId}/groups`, { method: "POST", headers: auth(owner.v.deviceToken), body: JSON.stringify({ memberKey: "short" }) })).status).toBe(400);
  });

  it("joins only through an invite, which runs out, can be revoked, and has limits", async () => {
    const { groupId, owner } = await newGroup();
    const secret = await invite(owner, groupId, 1);
    const stranger = await createVault("Stranger");
    const tryJoin = (s: string) => call(`/v1/vaults/${stranger.vaultId}/groups/${groupId}/members`, { method: "POST", headers: auth(stranger.deviceToken), body: JSON.stringify({ invite: s, memberKey: key() }) });
    expect((await tryJoin("inv_wrong")).status).toBe(403);
    const friend = await join(groupId, secret);
    expect((await tryJoin(secret)).status).toBe(403); // used up
    // The friend can invite too; the creator can revoke it.
    const res = await post(friend, groupId, "/invites", {});
    const { id, secret: second } = (await res.json()) as { id: string; secret: string };
    expect((await g(owner, groupId, `/invites/${id}`, { method: "DELETE" })).status).toBe(204);
    expect((await tryJoin(second)).status).toBe(403);
    for (let i = 0; i < 10; i++) await invite(owner, groupId);
    expect((await post(owner, groupId, "/invites", {})).status).toBe(429);
    const info = (await (await g(owner, groupId)).json()) as { members: { memberId: string; creator: boolean }[]; invites: unknown[] };
    expect(info.members.map((m) => m.memberId)).toEqual([owner.memberId, friend.memberId]);
    expect(info.members[0]!.creator).toBe(true);
    expect(info.invites.length).toBe(10);
  });

  it("holds 30 members at most", async () => {
    const { groupId, owner } = await newGroup();
    const secret = await invite(owner, groupId, 20);
    const secret2 = await invite(owner, groupId, 20);
    for (let i = 0; i < 29; i++) await join(groupId, i < 20 ? secret : secret2);
    const late = await createVault("Late");
    const res = await call(`/v1/vaults/${late.vaultId}/groups/${groupId}/members`, { method: "POST", headers: auth(late.deviceToken), body: JSON.stringify({ invite: secret2, memberKey: key() }) });
    expect(res.status).toBe(409);
  });

  it("no peeking: others' submissions and marks show only after you've submitted", async () => {
    const { groupId, owner } = await newGroup();
    const friend = await join(groupId, await invite(owner, groupId));
    const challenge = "ch1";
    expect((await post(owner, groupId, "/entries", { kind: "challenge", epoch: 1, body: sealed(), challenge })).status).toBe(201);
    const mine = sealed(80);
    expect((await post(owner, groupId, "/entries", { kind: "submission", epoch: 1, body: mine, challenge })).status).toBe(201);
    // The friend sees the challenge and that one person has submitted, not the answers.
    let seen = await entries(friend, groupId);
    expect(seen.entries.map((e) => e.kind)).toEqual(["challenge"]);
    expect(seen.waiting).toEqual([{ challenge, submitted: 1 }]);
    // The owner sees their own submission.
    expect((await entries(owner, groupId)).entries.map((e) => e.kind)).toEqual(["challenge", "submission"]);
    // The friend submits; now both submissions show, and the stored body is exactly the ciphertext sent.
    expect((await post(friend, groupId, "/entries", { kind: "submission", epoch: 1, body: sealed(), challenge })).status).toBe(201);
    seen = await entries(friend, groupId);
    expect(seen.entries.filter((e) => e.kind === "submission").length).toBe(2);
    expect(seen.entries.find((e) => e.member === owner.memberId && e.kind === "submission")!.body).toBe(mine);
    expect(seen.waiting).toEqual([]);
    // Peer marking: the owner marks the friend's answer; a third member who hasn't submitted can't see it.
    const third = await join(groupId, await invite(owner, groupId));
    expect((await post(owner, groupId, "/entries", { kind: "mark", epoch: 1, body: sealed(), challenge, about: friend.memberId })).status).toBe(201);
    expect((await entries(friend, groupId)).entries.some((e) => e.kind === "mark" && e.about === friend.memberId)).toBe(true);
    expect((await entries(third, groupId)).entries.some((e) => e.kind === "mark" || e.kind === "submission")).toBe(false);
  });

  it("refuses bad entries and enforces sizes", async () => {
    const { groupId, owner } = await newGroup();
    const friend = await join(groupId, await invite(owner, groupId));
    const bad = async (b: unknown, who = owner) => (await post(who, groupId, "/entries", b)).status;
    expect(await bad({ kind: "gossip", epoch: 1, body: sealed() })).toBe(400);
    expect(await bad({ kind: "submission", epoch: 1, body: sealed() })).toBe(400); // no challenge
    expect(await bad({ kind: "mark", epoch: 1, body: sealed(), challenge: "c" })).toBe(400); // no about
    expect(await bad({ kind: "profile", epoch: 2, body: sealed() })).toBe(400); // future epoch
    expect(await bad({ kind: "profile", epoch: 1, body: b64uEncode(new TextEncoder().encode("plain text, not TRV1")) })).toBe(400);
    expect(await bad({ kind: "profile", epoch: 1, body: sealed(64 * 1024 + 1) })).toBe(413);
    expect(await bad({ kind: "about", epoch: 1, body: sealed() }, friend)).toBe(403); // only the creator names it
    expect(await bad({ kind: "profile", epoch: 1, body: sealed() }, friend)).toBe(201);
  });

  it("limits entries per member per day", async () => {
    const { groupId, owner } = await newGroup();
    for (let i = 0; i < 100; i++) expect((await post(owner, groupId, "/entries", { kind: "profile", epoch: 1, body: sealed(20) })).status).toBe(201);
    expect((await post(owner, groupId, "/entries", { kind: "profile", epoch: 1, body: sealed(20) })).status).toBe(429);
  });

  it("removing a member stops their token, deletes their entries, revokes invites and asks for a new key", async () => {
    const { groupId, owner } = await newGroup();
    const friend = await join(groupId, await invite(owner, groupId));
    const other = await join(groupId, await invite(owner, groupId));
    await invite(owner, groupId);
    await post(friend, groupId, "/entries", { kind: "profile", epoch: 1, body: sealed() });
    // Only the creator removes others.
    expect((await g(other, groupId, `/members/${friend.memberId}`, { method: "DELETE" })).status).toBe(403);
    expect((await g(owner, groupId, `/members/${friend.memberId}`, { method: "DELETE" })).status).toBe(204);
    expect((await g(friend, groupId)).status).toBe(403);
    let info = (await (await g(owner, groupId)).json()) as { epoch: number; rotate: boolean; members: { memberId: string }[]; invites: unknown[] };
    expect(info.rotate).toBe(true);
    expect(info.invites).toEqual([]);
    expect(info.members.length).toBe(2);
    expect((await entries(owner, groupId)).entries.some((e) => e.member === friend.memberId)).toBe(false);
    // The creator seals a new key to everyone left; a missing box or a wrong epoch is refused.
    expect((await post(owner, groupId, "/keys", { epoch: 2, boxes: [{ memberId: owner.memberId, box: sealed() }] })).status).toBe(400);
    expect((await post(owner, groupId, "/keys", { epoch: 3, boxes: [] })).status).toBe(409);
    expect((await post(other, groupId, "/keys", { epoch: 2, boxes: [] })).status).toBe(403);
    const box = sealed(81);
    expect((await post(owner, groupId, "/keys", { epoch: 2, boxes: [{ memberId: owner.memberId, box: sealed(81) }, { memberId: other.memberId, box }] })).status).toBe(200);
    expect(((await (await g(other, groupId, "/keys")).json()) as { boxes: { epoch: number; box: string }[] }).boxes).toEqual([{ epoch: 2, box }]);
    info = (await (await g(owner, groupId)).json()) as typeof info;
    expect(info.epoch).toBe(2);
    expect(info.rotate).toBe(false);
    // Leaving yourself works the same way; the creator can't leave, only delete the group.
    expect((await g(other, groupId, `/members/${other.memberId}`, { method: "DELETE" })).status).toBe(204);
    expect((await g(owner, groupId, `/members/${owner.memberId}`, { method: "DELETE" })).status).toBe(400);
  });

  it("deletes your own entries, and the creator deletes the group", async () => {
    const { groupId, owner } = await newGroup();
    const friend = await join(groupId, await invite(owner, groupId));
    const { id } = (await (await post(friend, groupId, "/entries", { kind: "profile", epoch: 1, body: sealed() })).json()) as { id: string };
    expect((await g(owner, groupId, `/entries/${id}`, { method: "DELETE" })).status).toBe(403);
    expect((await g(friend, groupId, `/entries/${id}`, { method: "DELETE" })).status).toBe(204);
    expect((await g(friend, groupId, "", { method: "DELETE" })).status).toBe(403);
    expect((await g(owner, groupId, "", { method: "DELETE" })).status).toBe(204);
    expect((await g(owner, groupId)).status).toBe(404);
  });

  it("limits new groups per vault per day", async () => {
    const v = await createVault();
    const make = () => call(`/v1/vaults/${v.vaultId}/groups`, { method: "POST", headers: auth(v.deviceToken), body: JSON.stringify({ memberKey: key() }) });
    for (let i = 0; i < 5; i++) expect((await make()).status).toBe(201);
    expect((await make()).status).toBe(429);
  });

  it("tells members' open sockets about new entries, without their bodies", async () => {
    const { groupId, owner } = await newGroup();
    const friend = await join(groupId, await invite(owner, groupId));
    const res = await call(`/v1/vaults/${friend.v.vaultId}/groups/${groupId}/live?token=${friend.v.deviceToken}&member=${friend.memberToken}`, { headers: { upgrade: "websocket" } });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    const message = new Promise<string>((resolve) => ws.addEventListener("message", (e) => resolve(e.data as string)));
    await post(owner, groupId, "/entries", { kind: "start", epoch: 1, body: sealed(), challenge: "live1" });
    const m = JSON.parse(await message);
    expect(m).toMatchObject({ type: "entry", kind: "start", challenge: "live1", member: owner.memberId });
    expect(m.body).toBeUndefined();
    ws.close();
  });
});
