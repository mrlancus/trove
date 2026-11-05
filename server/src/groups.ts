// Study groups (docs/PROTOCOL.md §4 "Study groups", study-with-friends prompt §2–3). Friends practise the same
// catalogue questions as a challenge and see each other's work after submitting.
//
// - The relay holds only ciphertext for group data: names, challenges, answers and marks are TRV1 under the
//   group key, which the relay never gets (invite links carry it in the fragment; new keys are sealed to members).
// - No vault id is stored in a group: a member is a random id, a public key and a hashed token.
// - Friends only: people join through an invite a member made (7 days, ≤ 20 uses, ≤ 10 open); 30 members at most.
// - No peeking: another member's submission or marks for a challenge are served only after you've submitted to it.
// One Durable Object per group (name = group id); the one named "limits" counts new groups per vault per day.
import { DurableObject } from "cloudflare:workers";
import { b64uDecode, b64uEncode, randomId, randomToken, sha256Hex } from "./crypto";
import { error, json, type Env } from "./vault";

export const GROUP_MAX_MEMBERS = 30;
export const GROUP_MAX_ENTRIES = 2000;
export const GROUP_ENTRY_MAX_BYTES = 64 * 1024;
export const GROUP_MEMBER_DAILY_ENTRIES = 100;
export const GROUPS_PER_VAULT_DAILY = 5;
export const INVITE_MAX_OPEN = 10;
export const INVITE_MAX_USES = 20;
export const INVITE_DAYS = 7;
const KINDS = new Set(["profile", "about", "challenge", "start", "submission", "mark"]);
const NEEDS_CHALLENGE = new Set(["start", "submission", "mark"]);
const GROUP_ID = /^[A-Za-z0-9_-]{16,64}$/;
const SMALL_ID = /^[A-Za-z0-9_-]{1,64}$/;
const PAGE = 200;

interface Meta { groupId: string; epoch: number; rotate: boolean; creator: string; cursor: number; entries: number; createdAt: number }
interface Member { memberId: string; memberKey: string; tokenHash: string; creator: boolean; joinedAt: number }
interface Invite { id: string; by: string; secretHash: string; uses: number; maxUses: number; expiresAt: number }
interface Entry { id: string; cursor: number; kind: string; member: string; epoch: number; body: string; challenge?: string; about?: string; createdAt: number }

const day = (now: number) => new Date(now).toISOString().slice(0, 10);
const entryKey = (cursor: number) => `entry:${String(cursor).padStart(12, "0")}`;

export class GroupObject extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Date.now();
    const parts = url.pathname.split("/").filter(Boolean);
    const method = request.method;
    const s = this.ctx.storage;

    // The "limits" object: new groups per vault per day.
    if (parts[0] === "limit") {
      const key = `day:${url.searchParams.get("who")}:${day(now)}`;
      const n = (await s.get<number>(key)) ?? 0;
      if (n >= GROUPS_PER_VAULT_DAILY) return json({ allowed: false });
      await s.put(key, n + 1);
      await s.setAlarm(now + 2 * 86_400_000);
      return json({ allowed: true });
    }

    if (parts[0] === "create" && method === "POST") {
      if (await s.get("meta")) return error(409, "exists");
      const body = (await request.json().catch(() => ({}))) as { groupId?: string; memberKey?: string };
      if (!body.groupId || !validKey(body.memberKey)) return error(400, "memberKey (32-byte X25519, b64u) required");
      const member = await this.newMember(body.memberKey!, true, now);
      await s.put({ meta: { groupId: body.groupId, epoch: 1, rotate: false, creator: member.memberId, cursor: 0, entries: 0, createdAt: now } satisfies Meta });
      return json({ groupId: body.groupId, memberId: member.memberId, memberToken: member.token, epoch: 1 }, 201);
    }

    const meta = await s.get<Meta>("meta");
    if (!meta) return error(404, "no such group");

    // Joining needs an invite, not a member token.
    if (parts[0] === "members" && parts.length === 1 && method === "POST") {
      const body = (await request.json().catch(() => ({}))) as { invite?: string; memberKey?: string };
      if (!validKey(body.memberKey)) return error(400, "memberKey (32-byte X25519, b64u) required");
      const hash = await sha256Hex(String(body.invite ?? ""));
      const invites = await this.invites(now);
      const invite = invites.find((i) => i.secretHash === hash);
      if (!invite || invite.uses >= invite.maxUses) return error(403, "this invite doesn't work any more; ask for a new link");
      if ((await this.members()).length >= GROUP_MAX_MEMBERS) return error(409, `a group has at most ${GROUP_MAX_MEMBERS} members`);
      invite.uses++;
      await s.put(`invite:${invite.id}`, invite);
      const member = await this.newMember(body.memberKey!, false, now);
      this.broadcast({ type: "members" });
      return json({ memberId: member.memberId, memberToken: member.token, epoch: meta.epoch }, 201);
    }

    const me = await this.caller(request, url);
    if (!me) return error(403, "not a member of this group");

    if (parts[0] === "live") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return error(426, "expected websocket");
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], [me.memberId]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    if (parts.length === 0) {
      if (method === "GET") {
        const members = (await this.members()).map(({ memberId, memberKey, creator, joinedAt }) => ({ memberId, memberKey, creator, joinedAt }));
        const invites = (await this.invites(now)).map(({ id, by, uses, maxUses, expiresAt }) => ({ id, by, uses, maxUses, expiresAt }));
        return json({ groupId: meta.groupId, epoch: meta.epoch, rotate: meta.rotate, members, invites });
      }
      if (method === "DELETE") {
        if (!me.creator) return error(403, "only the group's creator can delete it");
        for (const ws of this.ctx.getWebSockets()) ws.close(4001, "group deleted");
        await s.deleteAll();
        return new Response(null, { status: 204 });
      }
    }

    if (parts[0] === "invites") {
      if (parts.length === 1 && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as { maxUses?: number };
        const maxUses = Math.min(INVITE_MAX_USES, Math.max(1, Math.floor(Number(body.maxUses ?? INVITE_MAX_USES)) || INVITE_MAX_USES));
        if ((await this.invites(now)).length >= INVITE_MAX_OPEN) return error(429, `at most ${INVITE_MAX_OPEN} invites can be open at once`);
        const secret = randomToken("inv_");
        const invite: Invite = { id: randomId().slice(0, 16), by: me.memberId, secretHash: await sha256Hex(secret), uses: 0, maxUses, expiresAt: now + INVITE_DAYS * 86_400_000 };
        await s.put(`invite:${invite.id}`, invite);
        return json({ id: invite.id, secret, expiresAt: invite.expiresAt }, 201);
      }
      if (parts.length === 2 && method === "DELETE") {
        const invite = await s.get<Invite>(`invite:${parts[1]}`);
        if (!invite) return error(404, "no such invite");
        if (invite.by !== me.memberId && !me.creator) return error(403, "only its maker or the creator can revoke an invite");
        await s.delete(`invite:${invite.id}`);
        return new Response(null, { status: 204 });
      }
    }

    if (parts[0] === "members" && parts.length === 2 && method === "DELETE") {
      const target = parts[1]!;
      if (target !== me.memberId && !me.creator) return error(403, "only the creator can remove someone");
      if (target === meta.creator) return error(400, "the creator leaves by deleting the group");
      const member = await s.get<Member>(`member:${target}`);
      if (!member) return error(404, "no such member");
      await s.delete(`member:${target}`);
      for (const [key, e] of await s.list<Entry>({ prefix: "entry:" })) if (e.member === target) { await s.delete(key); meta.entries--; }
      for (const key of (await s.list({ prefix: `box:${target}:` })).keys()) await s.delete(key);
      // Every open invite carries the key the removed member knows.
      for (const key of (await s.list({ prefix: "invite:" })).keys()) await s.delete(key);
      meta.rotate = true;
      await s.put("meta", meta);
      for (const ws of this.ctx.getWebSockets(target)) ws.close(4001, "removed");
      this.broadcast({ type: "members" });
      return new Response(null, { status: 204 });
    }

    if (parts[0] === "keys" && parts.length === 1) {
      if (method === "GET") {
        const boxes = [...(await s.list<string>({ prefix: `box:${me.memberId}:` }))].map(([key, box]) => ({ epoch: Number(key.split(":")[2]), box }));
        return json({ boxes: boxes.sort((a, b) => a.epoch - b.epoch) });
      }
      if (method === "POST") {
        if (!me.creator) return error(403, "only the creator changes the group key");
        const body = (await request.json().catch(() => ({}))) as { epoch?: number; boxes?: { memberId?: string; box?: string }[] };
        if (body.epoch !== meta.epoch + 1) return error(409, `epoch must be ${meta.epoch + 1}`);
        const members = await this.members();
        const boxes = new Map((body.boxes ?? []).filter((b) => typeof b.box === "string" && b.box.length <= 512).map((b) => [b.memberId, b.box!]));
        if (members.some((m) => !boxes.has(m.memberId))) return error(400, "a box for every member is needed");
        for (const m of members) await s.put(`box:${m.memberId}:${body.epoch}`, boxes.get(m.memberId)!);
        meta.epoch = body.epoch;
        meta.rotate = false;
        await s.put("meta", meta);
        this.broadcast({ type: "members" });
        return json({ epoch: meta.epoch });
      }
    }

    if (parts[0] === "entries") {
      if (parts.length === 1 && method === "POST") return this.addEntry(request, meta, me, now);
      if (parts.length === 1 && method === "GET") return this.listEntries(url, me);
      if (parts.length === 2 && method === "DELETE") {
        for (const [key, e] of await s.list<Entry>({ prefix: "entry:" })) {
          if (e.id !== parts[1]) continue;
          if (e.member !== me.memberId) return error(403, "you can delete only your own entries");
          await s.delete(key);
          meta.entries--;
          await s.put("meta", meta);
          return new Response(null, { status: 204 });
        }
        return error(404, "no such entry");
      }
    }
    return error(404, "not found");
  }

  private async addEntry(request: Request, meta: Meta, me: Member, now: number): Promise<Response> {
    const s = this.ctx.storage;
    const body = (await request.json().catch(() => ({}))) as { kind?: string; epoch?: number; body?: string; challenge?: string; about?: string };
    if (!body.kind || !KINDS.has(body.kind)) return error(400, "unknown kind");
    if (NEEDS_CHALLENGE.has(body.kind) && !(body.challenge && SMALL_ID.test(body.challenge))) return error(400, "challenge is required");
    if (body.kind === "mark" && !(body.about && SMALL_ID.test(body.about))) return error(400, "about is required for a mark");
    if (body.kind === "about" && !me.creator) return error(403, "only the creator names the group");
    if (typeof body.epoch !== "number" || body.epoch < 1 || body.epoch > meta.epoch) return error(400, "unknown epoch");
    if (typeof body.body !== "string") return error(400, "body is required");
    let bytes: Uint8Array;
    try { bytes = b64uDecode(body.body); } catch { return error(400, "body must be b64u"); }
    if (bytes.length > GROUP_ENTRY_MAX_BYTES) return error(413, "an entry is at most 64 KiB");
    if (bytes.length < 17 || new TextDecoder().decode(bytes.slice(0, 4)) !== "TRV1") return error(400, "body must be TRV1");
    if (meta.entries >= GROUP_MAX_ENTRIES) return error(429, "this group is full; delete old challenges");
    const dayKey = `day:${me.memberId}:${day(now)}`;
    const today = (await s.get<number>(dayKey)) ?? 0;
    if (today >= GROUP_MEMBER_DAILY_ENTRIES) return error(429, "that's enough for today");
    meta.cursor++;
    meta.entries++;
    const entry: Entry = { id: randomId().slice(0, 16), cursor: meta.cursor, kind: body.kind, member: me.memberId, epoch: body.epoch, body: b64uEncode(bytes), createdAt: now };
    if (body.challenge) entry.challenge = body.challenge;
    if (body.about) entry.about = body.about;
    await s.put({ meta, [entryKey(entry.cursor)]: entry, [dayKey]: today + 1 });
    await s.setAlarm(now + 2 * 86_400_000);
    this.broadcast({ type: "entry", cursor: entry.cursor, kind: entry.kind, member: entry.member, ...(entry.challenge ? { challenge: entry.challenge } : {}) });
    return json({ id: entry.id, cursor: entry.cursor }, 201);
  }

  /** No peeking: others' submissions, and marks about others, wait until you've submitted to that challenge. */
  private async listEntries(url: URL, me: Member): Promise<Response> {
    const after = Math.max(0, Number(url.searchParams.get("after") ?? 0) || 0);
    const all = [...(await this.ctx.storage.list<Entry>({ prefix: "entry:" })).values()];
    const submitted = new Set(all.filter((e) => e.kind === "submission" && e.member === me.memberId).map((e) => e.challenge));
    const hidden = (e: Entry) =>
      !submitted.has(e.challenge) && ((e.kind === "submission" && e.member !== me.memberId) || (e.kind === "mark" && e.about !== me.memberId));
    const visible = all.filter((e) => e.cursor > after && !hidden(e));
    const waiting = new Map<string, number>();
    for (const e of all) if (e.kind === "submission" && !submitted.has(e.challenge)) waiting.set(e.challenge!, (waiting.get(e.challenge!) ?? 0) + 1);
    return json({
      entries: visible.slice(0, PAGE),
      waiting: [...waiting].map(([challenge, n]) => ({ challenge, submitted: n })),
      more: visible.length > PAGE,
    });
  }

  private async newMember(memberKey: string, creator: boolean, now: number) {
    const token = randomToken("mem_");
    const member: Member = { memberId: randomId().slice(0, 16), memberKey, tokenHash: await sha256Hex(token), creator, joinedAt: now };
    await this.ctx.storage.put(`member:${member.memberId}`, member);
    return { ...member, token };
  }

  private async members(): Promise<Member[]> {
    return [...(await this.ctx.storage.list<Member>({ prefix: "member:" })).values()].sort((a, b) => a.joinedAt - b.joinedAt);
  }

  /** Open invites; expired and used-up ones are dropped. */
  private async invites(now: number): Promise<Invite[]> {
    const out: Invite[] = [];
    for (const [key, i] of await this.ctx.storage.list<Invite>({ prefix: "invite:" })) {
      if (i.expiresAt <= now || i.uses >= i.maxUses) await this.ctx.storage.delete(key);
      else out.push(i);
    }
    return out;
  }

  private async caller(request: Request, url: URL): Promise<Member | null> {
    const token = request.headers.get("x-trove-member") ?? url.searchParams.get("member") ?? "";
    if (!token) return null;
    const hash = await sha256Hex(token);
    return (await this.members()).find((m) => m.tokenHash === hash) ?? null;
  }

  private broadcast(message: unknown) {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(text); } catch { /* closing */ }
    }
  }

  async webSocketMessage() {}

  async webSocketClose(ws: WebSocket, code: number) {
    try { ws.close(code, "closing"); } catch { /* closed */ }
  }

  /** Old day counters go. */
  async alarm(): Promise<void> {
    const today = day(Date.now());
    for (const key of (await this.ctx.storage.list({ prefix: "day:" })).keys()) if (!key.endsWith(today)) await this.ctx.storage.delete(key);
  }
}

function validKey(k: unknown): boolean {
  if (typeof k !== "string") return false;
  try { return b64uDecode(k).length === 32; } catch { return false; }
}

/** `/v1/vaults/:v/groups/…`: a device of a vault on this relay, then the group's own object. */
export async function groupsRoute(request: Request, env: Env, vaultId: string, rest: string[], vaultStub: DurableObjectStub): Promise<Response> {
  if (!env.GROUP) return error(404, "not found");
  const url = new URL(request.url);
  const auth = request.headers.get("authorization") ?? (url.searchParams.get("token") ? `Bearer ${url.searchParams.get("token")}` : "");
  const who = await vaultStub.fetch(new Request("https://vault/api/info", { headers: { authorization: auth } }));
  if (who.status !== 200) return error(who.status === 403 ? 403 : 401, "a device of a vault on this relay is needed");
  if (rest.length === 0) {
    if (request.method !== "POST") return error(404, "not found");
    const limits = env.GROUP.get(env.GROUP.idFromName("limits"));
    const who = await sha256Hex(vaultId);
    const ok = (await (await limits.fetch(`https://group/limit?who=${who}`)).json()) as { allowed: boolean };
    if (!ok.allowed) return error(429, `at most ${GROUPS_PER_VAULT_DAILY} new groups a day`);
    const groupId = randomId();
    const body = (await request.json().catch(() => ({}))) as { memberKey?: string };
    return env.GROUP.get(env.GROUP.idFromName(groupId)).fetch(
      new Request("https://group/create", { method: "POST", body: JSON.stringify({ groupId, memberKey: body.memberKey }) }),
    );
  }
  const [groupId, ...more] = rest;
  if (!groupId || !GROUP_ID.test(groupId) || groupId === "limits") return error(404, "no such group");
  const target = new URL(`https://group/${more.join("/")}`);
  const member = url.searchParams.get("member");
  if (member) target.searchParams.set("member", member);
  if (url.searchParams.get("after")) target.searchParams.set("after", url.searchParams.get("after")!);
  return env.GROUP.get(env.GROUP.idFromName(groupId)).fetch(new Request(target.toString(), request));
}
