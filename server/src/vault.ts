import { DurableObject } from "cloudflare:workers";
import { envelopePrefix, randomId, randomToken, seal, sealedLength, sealStream, sha256Hex, b64uDecode, b64uEncode, type InboxHeader } from "./crypto";
import { handleDav } from "./webdav";
import { aiAction, aiAsk, aiConfigured, aiEmbed, aiEnrich, aiTranscribe, DEFAULT_MONTHLY_TOKENS, modelOf } from "./ai";
import { checkPrice, type Price } from "./price";
import { publishedPage } from "./publish";
import { Bridges, FETCH_BUDGET } from "./bridges";

export interface Env {
  VAULT: DurableObjectNamespace<VaultObject>;
  BLOBS: R2Bucket;
  AI?: Ai;
  ANTHROPIC_API_KEY?: string;
  CLAUDE_MODEL: string;
  EMAIL_VAULT_ID: string;
  /** "false" closes POST /v1/vaults once your own vault exists, so nobody else can use this relay. */
  ALLOW_NEW_VAULTS?: string;
  /** Monthly allowance of Claude tokens (input + output) per vault; unset means DEFAULT_MONTHLY_TOKENS. */
  AI_MONTHLY_LIMIT?: string;
  /** Optional secret that encrypts bridge tokens (Telegram bot, GitHub) at rest (PROTOCOL.md §4 "Bridges"). */
  BRIDGE_KEY?: string;
}

export type Caller = { kind: "device"; deviceId: string } | { kind: "inbox" };

const MAX_SEGMENT_BYTES = 1024 * 1024;
/** Checkpoints (PROTOCOL.md §3): the newest few per vault, up to just under the Workers request limit. */
const MAX_CHECKPOINT_BYTES = 95 * 1024 * 1024;
const CHECKPOINTS_KEPT = 3;
const PAIRING_TTL_MS = 10 * 60 * 1000;
const RECOVERY_TTL_MS = 5 * 60 * 1000;
const MAX_OPEN_RECOVERIES = 10;
const PRICE_CHECK_EVERY_MS = 12 * 60 * 60 * 1000;
const PRICE_CHECKS_PER_RUN = 40; // stays under the free plan's subrequest limit
const MAX_WATCHES = 200;
const MAX_PUBLISHED_BYTES = 256 * 1024;
/** "Something new" pings for segments wait for a quiet moment, so one push of many segments is one ping. */
const SEGMENT_PING_QUIET_MS = 300;
const SEGMENT_PING_MAX_WAIT_MS = 1500;

interface SegmentPing { type: "segment"; cursor: number; device: string; first: number; last: number; count: number }

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
export function error(status: number, message: string): Response {
  return json({ error: message }, status);
}

/** One Durable Object per vault: devices, journals, inbox index, WebDAV listing, live sockets. */
export class VaultObject extends DurableObject<Env> {
  private sql: SqlStorage;
  /** Bridges (bridges.ts): feeds, GitHub, Telegram and webhooks that seal into the inbox. */
  readonly bridges: Bridges;
  private segmentPings = new Map<string, SegmentPing>();
  private segmentPingTimer: ReturnType<typeof setTimeout> | null = null;
  private segmentPingSince = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT, kind TEXT, token_hash TEXT UNIQUE,
        created_at INTEGER, last_seen_at INTEGER, revoked INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS inbox_tokens(token_hash TEXT PRIMARY KEY, label TEXT, created_at INTEGER, revoked INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS pairings(code_hash TEXT PRIMARY KEY, expires_at INTEGER, used INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS recoveries(id TEXT PRIMARY KEY, answer_hash TEXT, expires_at INTEGER);
      CREATE TABLE IF NOT EXISTS segments(cursor INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT, first INTEGER, last INTEGER,
        size INTEGER, digest TEXT, body BLOB, created_at INTEGER, UNIQUE(device, first));
      CREATE TABLE IF NOT EXISTS inbox(cursor INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE, size INTEGER, source TEXT,
        dav_path TEXT, r2_key TEXT, created_at INTEGER, acked INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS dav(path TEXT PRIMARY KEY, size INTEGER, etag TEXT, updated_at INTEGER, is_dir INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY, size INTEGER, created_at INTEGER);
      CREATE TABLE IF NOT EXISTS watches(id TEXT PRIMARY KEY, url TEXT, item_id TEXT, created_at INTEGER, checked_at INTEGER DEFAULT 0,
        error TEXT, price REAL, currency TEXT, lowest REAL, history TEXT DEFAULT '[]', dropped_at INTEGER);
      CREATE TABLE IF NOT EXISTS published(slug TEXT PRIMARY KEY, title TEXT, markdown TEXT, updated_at INTEGER);
      CREATE TABLE IF NOT EXISTS checkpoints(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE, device TEXT, size INTEGER, created_at INTEGER);
    `);
    this.bridges = new Bridges({
      sql: this.sql, storage: ctx.storage, vaultId: () => this.vaultId, fetcher: () => this.fetchPage, tokenKey: env.BRIDGE_KEY,
      seal: (header, body) => this.sealIntoInbox(header, body, body.length, null),
    });
    // Keep-alive pings never wake the object (free-tier friendly).
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  // ---------- meta ----------

  private meta(k: string): string | undefined {
    const row = this.sql.exec<{ v: string }>("SELECT v FROM meta WHERE k = ?", k).toArray()[0];
    return row?.v;
  }
  private setMeta(k: string, v: string) {
    this.sql.exec("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v);
  }
  get vaultId(): string {
    return this.meta("vaultId") ?? "";
  }
  get publicKey(): Uint8Array {
    return b64uDecode(this.meta("publicKey") ?? "");
  }

  // ---------- auth ----------

  private async authenticate(request: Request): Promise<Caller | undefined> {
    const header = request.headers.get("authorization") ?? "";
    let token = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!token) token = new URL(request.url).searchParams.get("token") ?? "";
    if (!token && header.startsWith("Basic ")) {
      // WebDAV: username = vault id, password = inbox token.
      const [user, pass] = atob(header.slice(6)).split(":");
      if (user === this.vaultId) token = pass ?? "";
    }
    if (!token) return undefined;
    const hash = await sha256Hex(token);
    const device = this.sql
      .exec<{ id: string }>("SELECT id FROM devices WHERE token_hash = ? AND revoked = 0", hash)
      .toArray()[0];
    if (device) {
      this.sql.exec("UPDATE devices SET last_seen_at = ? WHERE id = ?", Date.now(), device.id);
      return { kind: "device", deviceId: device.id };
    }
    const inbox = this.sql.exec("SELECT 1 FROM inbox_tokens WHERE token_hash = ? AND revoked = 0", hash).toArray()[0];
    return inbox ? { kind: "inbox" } : undefined;
  }

  /** `proposedId` lets a device keep the journal id it already uses in an iCloud-only vault. */
  private async addDevice(name: string, kind: string, proposedId?: string) {
    const wanted = proposedId?.toUpperCase();
    const free = wanted && /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(wanted) &&
      !this.sql.exec("SELECT 1 FROM devices WHERE id = ?", wanted).toArray()[0];
    const deviceId = free ? wanted : crypto.randomUUID().toUpperCase();
    const deviceToken = randomToken("tdv_");
    this.sql.exec(
      "INSERT INTO devices(id, name, kind, token_hash, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?)",
      deviceId, name.slice(0, 80), kind.slice(0, 20), await sha256Hex(deviceToken), Date.now(), Date.now(),
    );
    return { deviceId, deviceToken };
  }

  private async addInboxToken(label: string) {
    const inboxToken = randomToken("tin_");
    this.sql.exec("INSERT INTO inbox_tokens(token_hash, label, created_at) VALUES(?, ?, ?)", await sha256Hex(inboxToken), label, Date.now());
    return inboxToken;
  }

  // ---------- entry point ----------

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      if (path === "/internal/init") return await this.init(request);
      if (!this.vaultId) return error(404, "vault not found");
      if (path === "/internal/inbox") return await this.ingest(request);
      if (path.startsWith("/public/") && request.method === "GET") return this.publicPage(path.slice(8));
      if (path.startsWith("/hook/")) return await this.bridges.hook(request, path.slice(6));
      if (path === "/api/devices" && request.method === "POST") return await this.pairDevice(request);
      if (path === "/api/recovery" && request.method === "POST") return await this.recoveryChallenge();

      const caller = await this.authenticate(request);
      if (!caller) return error(401, "unauthorized");
      if (path.startsWith("/dav")) return await handleDav(this, request, path.slice(4) || "/");
      if (path === "/api/inbox" && request.method === "POST") return await this.postInbox(request);
      if (caller.kind !== "device") return error(403, "inbox tokens can only add to the inbox");
      return await this.deviceRoute(request, url, caller.deviceId);
    } catch (e) {
      if (e instanceof HttpError) return error(e.status, e.message);
      console.error(e);
      return error(500, "internal error");
    }
  }

  private async init(request: Request): Promise<Response> {
    if (this.vaultId) return error(409, "vault already exists");
    const body = (await request.json()) as { vaultId: string; vaultPublicKey: string; deviceName: string; deviceKind?: string; deviceId?: string };
    if (b64uDecode(body.vaultPublicKey).length !== 32) return error(400, "vaultPublicKey must be a raw X25519 key (32 bytes, b64u)");
    this.setMeta("vaultId", body.vaultId);
    this.setMeta("publicKey", body.vaultPublicKey);
    this.setMeta("createdAt", new Date().toISOString());
    this.setMeta("aiEnabled", "false");
    const device = await this.addDevice(body.deviceName || "First device", body.deviceKind ?? "unknown", body.deviceId);
    const inboxToken = await this.addInboxToken("default");
    return json({ vaultId: body.vaultId, ...device, inboxToken }, 201);
  }

  /**
   * Recovery (PROTOCOL.md §4): a random answer sealed to the vault public key. Only someone holding
   * the vault private key (the recovery code) can open it and use the answer to add a device.
   */
  private async recoveryChallenge(): Promise<Response> {
    const now = Date.now();
    this.sql.exec("DELETE FROM recoveries WHERE expires_at < ?", now);
    const open = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM recoveries").one().n;
    if (open >= MAX_OPEN_RECOVERIES) return error(429, "too many recovery attempts, try again in a few minutes");
    const answer = crypto.getRandomValues(new Uint8Array(32));
    const id = randomId();
    const box = await seal(answer, { recipientPublicKey: b64uDecode(this.meta("publicKey") ?? "") });
    this.sql.exec("INSERT INTO recoveries(id, answer_hash, expires_at) VALUES(?, ?, ?)", id, await sha256Hex(answer), now + RECOVERY_TTL_MS);
    return json({ challengeId: id, box: b64uEncode(box) }, 201);
  }

  private async pairDevice(request: Request): Promise<Response> {
    const body = (await request.json()) as {
      pairingCode?: string; recoveryChallenge?: string; recoveryAnswer?: string; deviceName?: string; deviceKind?: string; deviceId?: string;
    };
    if (body.recoveryChallenge) {
      const row = this.sql
        .exec<{ answer_hash: string; expires_at: number }>("SELECT answer_hash, expires_at FROM recoveries WHERE id = ?", body.recoveryChallenge)
        .toArray()[0];
      this.sql.exec("DELETE FROM recoveries WHERE id = ?", body.recoveryChallenge);
      const answer = b64uDecode(body.recoveryAnswer ?? "");
      if (!row || row.expires_at < Date.now() || answer.length !== 32 || (await sha256Hex(answer)) !== row.answer_hash) {
        return error(403, "recovery failed");
      }
      return json(await this.addDevice(body.deviceName ?? "Recovered device", body.deviceKind ?? "unknown", body.deviceId), 201);
    }
    const hash = await sha256Hex(body.pairingCode ?? "");
    const row = this.sql
      .exec<{ expires_at: number }>("SELECT expires_at FROM pairings WHERE code_hash = ? AND used = 0", hash)
      .toArray()[0];
    if (!row || row.expires_at < Date.now()) return error(403, "pairing code invalid or expired");
    this.sql.exec("UPDATE pairings SET used = 1 WHERE code_hash = ?", hash);
    return json(await this.addDevice(body.deviceName ?? "New device", body.deviceKind ?? "unknown", body.deviceId), 201);
  }

  private async deviceRoute(request: Request, url: URL, deviceId: string): Promise<Response> {
    const parts = url.pathname.split("/").filter(Boolean).slice(1); // drop "api"
    const method = request.method;
    const [section, a, b, c] = parts;

    switch (section) {
      case "info":
        return json({ vaultId: this.vaultId, vaultPublicKey: this.meta("publicKey"), createdAt: this.meta("createdAt"), aiEnabled: this.meta("aiEnabled") === "true", deviceId });
      case "settings":
        if (method === "PUT") {
          const body = (await request.json()) as { aiEnabled?: boolean };
          if (typeof body.aiEnabled === "boolean") this.setMeta("aiEnabled", String(body.aiEnabled));
        }
        return json({ aiEnabled: this.meta("aiEnabled") === "true" });
      case "pairings": {
        if (method !== "POST") break;
        const pairingCode = randomToken("tpc_");
        const expiresAt = Date.now() + PAIRING_TTL_MS;
        this.sql.exec("INSERT INTO pairings(code_hash, expires_at) VALUES(?, ?)", await sha256Hex(pairingCode), expiresAt);
        return json({ pairingCode, expiresAt: new Date(expiresAt).toISOString() }, 201);
      }
      case "devices":
        if (!a && method === "GET") {
          const devices = this.sql
            .exec("SELECT id, name, kind, created_at, last_seen_at, revoked FROM devices ORDER BY created_at")
            .toArray()
            .map((r) => ({ deviceId: r.id, name: r.name, kind: r.kind, createdAt: r.created_at, lastSeenAt: r.last_seen_at, revoked: r.revoked === 1 }));
          return json({ devices });
        }
        if (a && method === "DELETE") {
          this.sql.exec("UPDATE devices SET revoked = 1 WHERE id = ?", a);
          for (const ws of this.ctx.getWebSockets(a)) ws.close(4001, "revoked");
          return new Response(null, { status: 204 });
        }
        break;
      case "inbox-tokens":
        if (method === "POST") return json({ inboxToken: await this.addInboxToken("extra") }, 201);
        break;
      case "segments":
        if (!a && method === "GET") return this.listSegments(url);
        if (a && b && c && method === "PUT") return this.putSegment(request, deviceId, a, Number(b), Number(c));
        if (a && b && c && method === "GET") return this.getSegment(a, Number(b), Number(c));
        break;
      case "checkpoints":
        if (!a && method === "GET") return this.listCheckpoints();
        if (a && !b && method === "PUT") return this.putCheckpoint(request, deviceId, a);
        if (a && !b && method === "GET") return this.getCheckpoint(a);
        break;
      case "blobs":
        if (a && method === "PUT") return this.putBlob(request, a);
        if (a && method === "GET") return this.getBlob(a);
        break;
      case "inbox":
        if (!a && method === "GET") return this.listInbox(url);
        if (a && method === "GET") return this.getInbox(a);
        if (a && method === "DELETE") return this.ackInbox(a);
        break;
      case "live":
        return this.live(request, deviceId);
      case "watches":
        if (!a && method === "GET") return this.listWatches();
        if (a && method === "PUT") return this.putWatch(a, await request.json());
        if (a && method === "DELETE") return this.deleteWatch(a);
        break;
      case "bridges":
        return this.bridges.route(request, a, b);
      case "preview":
        if (!a && method === "POST") return this.bridges.preview(request);
        break;
      case "published":
        if (!a && method === "GET") {
          return json({ pages: this.sql.exec("SELECT slug, title, updated_at FROM published ORDER BY updated_at DESC").toArray()
            .map((r) => ({ slug: r.slug, title: r.title, updatedAt: r.updated_at, path: `/p/${this.vaultId}/${r.slug}` })) });
        }
        if (a && method === "PUT") return this.publish(a, await request.json());
        if (a && method === "DELETE") {
          this.sql.exec("DELETE FROM published WHERE slug = ?", a);
          return new Response(null, { status: 204 });
        }
        break;
      case "ai": {
        if (a === "status" && method === "GET") return json(this.aiStatus());
        if (method !== "POST") break;
        if (this.meta("aiEnabled") !== "true") { await request.arrayBuffer().catch(() => null); return error(403, "AI is disabled for this vault"); }
        if (a === "enrich" || a === "ask" || a === "action") {
          const status = this.aiStatus();
          if (status.used >= status.limit) {
            await request.arrayBuffer().catch(() => null);
            return json({ error: `This month's cloud AI allowance is used up. It starts again on ${status.resetsAt.slice(0, 10)}.`, ...status }, 429);
          }
          const body = await request.json().catch(() => null);
          if (!body || typeof body !== "object") return error(400, "a JSON body is required");
          try {
            const result = a === "enrich" ? await aiEnrich(this.env, body) : a === "ask" ? await aiAsk(this.env, body as never) : await aiAction(this.env, body);
            this.addAiUsage(result.tokens);
            return json({ ...result, usage: this.aiStatus() });
          } catch (e) {
            if (e instanceof HttpError && e.tokens) this.addAiUsage(e.tokens);
            throw e;
          }
        }
        if (a === "transcribe") return json(await aiTranscribe(this.env, new Uint8Array(await request.arrayBuffer())));
        if (a === "embed") return json(await aiEmbed(this.env, await request.json()));
        break;
      }
    }
    return error(404, "not found");
  }

  // ---------- AI allowance (ROADMAP §4 A1) ----------

  /** Claude use this calendar month (UTC), in tokens as the API reported them, against AI_MONTHLY_LIMIT. */
  aiStatus() {
    const now = new Date();
    const month = now.toISOString().slice(0, 7);
    const limit = Math.max(0, Math.floor(Number(this.env.AI_MONTHLY_LIMIT ?? "") || DEFAULT_MONTHLY_TOKENS));
    const resetsAt = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString();
    const vaultEnabled = this.meta("aiEnabled") === "true";
    const configured = aiConfigured(this.env);
    return {
      enabled: vaultEnabled && configured,
      vaultEnabled,
      configured,
      model: modelOf(this.env),
      month,
      used: Number(this.meta(`aiUsed:${month}`) ?? 0),
      limit,
      unit: "tokens",
      resetsAt,
    };
  }

  private addAiUsage(tokens: number) {
    if (!(tokens > 0)) return;
    const key = `aiUsed:${new Date().toISOString().slice(0, 7)}`;
    this.setMeta(key, String(Number(this.meta(key) ?? 0) + Math.round(tokens)));
  }

  // ---------- journal segments ----------

  private async putSegment(request: Request, caller: string, device: string, first: number, last: number) {
    if (device !== caller) return error(403, "devices may only upload their own journal");
    if (!Number.isInteger(first) || !Number.isInteger(last) || first < 1 || last < first) return error(400, "bad sequence range");
    const body = new Uint8Array(await request.arrayBuffer());
    if (body.length > MAX_SEGMENT_BYTES) return error(413, "segment too large");
    const digest = await sha256Hex(body);
    const existing = this.sql
      .exec<{ cursor: number; digest: string }>("SELECT cursor, digest FROM segments WHERE device = ? AND first = ?", device, first)
      .toArray()[0];
    if (existing) {
      if (existing.digest === digest) return json({ cursor: existing.cursor });
      return error(409, "a different segment with this start already exists");
    }
    const row = this.sql
      .exec<{ cursor: number }>(
        "INSERT INTO segments(device, first, last, size, digest, body, created_at) VALUES(?, ?, ?, ?, ?, ?, ?) RETURNING cursor",
        device, first, last, body.length, digest, body, Date.now(),
      )
      .one();
    this.queueSegmentPing(row.cursor, device, first, last);
    return json({ cursor: row.cursor }, 201);
  }

  private listSegments(url: URL) {
    const after = Number(url.searchParams.get("after") ?? 0);
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 200), 500);
    const rows = this.sql
      .exec("SELECT cursor, device, first, last, size FROM segments WHERE cursor > ? ORDER BY cursor LIMIT ?", after, limit + 1)
      .toArray();
    return json({ segments: rows.slice(0, limit), more: rows.length > limit });
  }

  private getSegment(device: string, first: number, last: number) {
    const row = this.sql
      .exec<{ body: ArrayBuffer }>("SELECT body FROM segments WHERE device = ? AND first = ? AND last = ?", device, first, last)
      .toArray()[0];
    if (!row) return error(404, "no such segment");
    return new Response(row.body, { headers: { "content-type": "application/octet-stream" } });
  }

  // ---------- checkpoints (PROTOCOL.md §3 "Checkpoints"): opaque TRV1 blobs in R2 ----------

  private async putCheckpoint(request: Request, device: string, id: string) {
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(id)) return error(400, "bad checkpoint id");
    if (this.sql.exec("SELECT 1 FROM checkpoints WHERE id = ?", id).toArray()[0]) return json({ id }, 200);
    const length = Number(request.headers.get("content-length"));
    if (!request.body || !Number.isFinite(length) || length <= 0) return error(411, "content-length required");
    if (length > MAX_CHECKPOINT_BYTES) return error(413, "checkpoint too large");
    await this.env.BLOBS.put(this.r2Key("c", id), fixedLength(request.body, length));
    this.sql.exec("INSERT INTO checkpoints(id, device, size, created_at) VALUES(?, ?, ?, ?)", id, device, length, Date.now());
    // Only the newest few are kept: each one holds everything before it.
    const old = this.sql
      .exec<{ id: string }>("SELECT id FROM checkpoints ORDER BY seq DESC LIMIT -1 OFFSET ?", CHECKPOINTS_KEPT)
      .toArray();
    for (const row of old) {
      await this.env.BLOBS.delete(this.r2Key("c", row.id));
      this.sql.exec("DELETE FROM checkpoints WHERE id = ?", row.id);
    }
    return json({ id }, 201);
  }

  private listCheckpoints() {
    const checkpoints = this.sql
      .exec<{ id: string; device: string; size: number; created_at: number }>("SELECT id, device, size, created_at FROM checkpoints ORDER BY seq DESC")
      .toArray()
      .map((r) => ({ id: r.id, device: r.device, size: r.size, createdAt: r.created_at }));
    return json({ checkpoints });
  }

  private async getCheckpoint(id: string) {
    if (!this.sql.exec("SELECT 1 FROM checkpoints WHERE id = ?", id).toArray()[0]) return error(404, "no such checkpoint");
    const obj = await this.env.BLOBS.get(this.r2Key("c", id));
    if (!obj) return error(404, "no such checkpoint");
    return new Response(obj.body, { headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) } });
  }

  // ---------- blobs ----------

  private r2Key(kind: "b" | "i" | "c", id: string) {
    return `v/${this.vaultId}/${kind}/${id}`;
  }

  private async putBlob(request: Request, id: string) {
    if (!/^[0-9a-f]{64}$/.test(id)) return error(400, "blob id must be 64 hex chars");
    if (this.sql.exec("SELECT 1 FROM blobs WHERE id = ?", id).toArray()[0]) return json({ id }, 200);
    const length = Number(request.headers.get("content-length"));
    if (!request.body || !Number.isFinite(length) || length <= 0) return error(411, "content-length required");
    await this.env.BLOBS.put(this.r2Key("b", id), fixedLength(request.body, length));
    this.sql.exec("INSERT OR IGNORE INTO blobs(id, size, created_at) VALUES(?, ?, ?)", id, length, Date.now());
    return json({ id }, 201);
  }

  private async getBlob(id: string) {
    const obj = await this.env.BLOBS.get(this.r2Key("b", id));
    if (!obj) return error(404, "no such blob");
    return new Response(obj.body, { headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) } });
  }

  // ---------- sealed inbox ----------

  /** Already-sealed upload from an extension, the iOS share sheet, etc. */
  private async postInbox(request: Request) {
    const length = Number(request.headers.get("content-length"));
    if (!request.body || !Number.isFinite(length) || length < 49) return error(411, "content-length required");
    const id = randomId();
    await this.env.BLOBS.put(this.r2Key("i", id), fixedLength(request.body, length));
    const source = (request.headers.get("x-trove-source") ?? "other").slice(0, 20);
    return json(this.recordInbox(id, length, source, null), 201);
  }

  /** Plaintext from a trusted path inside this Worker (email handler, WebDAV PUT): seal it here. */
  async sealIntoInbox(header: InboxHeader, body: ReadableStream<Uint8Array> | Uint8Array, bodyLength: number, davPath: string | null) {
    const prefix = envelopePrefix(header);
    const total = prefix.length + bodyLength;
    const id = randomId();
    const sealer = sealStream({ recipientPublicKey: this.publicKey });
    const fixed = new FixedLengthStream(sealedLength(total));
    const pump = (async () => {
      const writer = sealer.writable.getWriter();
      await writer.write(prefix);
      if (body instanceof Uint8Array) {
        await writer.write(body);
      } else {
        const reader = body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          await writer.write(value);
        }
      }
      await writer.close();
    })();
    const piping = sealer.readable.pipeTo(fixed.writable);
    await Promise.all([this.env.BLOBS.put(this.r2Key("i", id), fixed.readable), pump, piping]);
    return this.recordInbox(id, sealedLength(total), header.source, davPath);
  }

  private recordInbox(id: string, size: number, source: string, davPath: string | null) {
    const row = this.sql
      .exec<{ cursor: number }>(
        "INSERT INTO inbox(id, size, source, dav_path, r2_key, created_at) VALUES(?, ?, ?, ?, ?, ?) RETURNING cursor",
        id, size, source, davPath, this.r2Key("i", id), Date.now(),
      )
      .one();
    this.broadcast({ type: "inbox", cursor: row.cursor, id });
    return { id, cursor: row.cursor };
  }

  private async ingest(request: Request) {
    const header = JSON.parse(request.headers.get("x-trove-envelope") ?? "{}") as InboxHeader;
    const body = new Uint8Array(await request.arrayBuffer());
    return json(await this.sealIntoInbox(header, body, body.length, null), 201);
  }

  private listInbox(url: URL) {
    const after = Number(url.searchParams.get("after") ?? 0);
    const rows = this.sql
      .exec("SELECT cursor, id, size, source, dav_path, created_at FROM inbox WHERE cursor > ? AND acked = 0 ORDER BY cursor LIMIT 201", after)
      .toArray();
    const entries = rows.slice(0, 200).map((r) => ({
      cursor: r.cursor, id: r.id, size: r.size, source: r.source,
      ...(r.dav_path ? { davPath: r.dav_path } : {}),
      createdAt: new Date(r.created_at as number).toISOString(),
    }));
    return json({ entries, more: rows.length > 200 });
  }

  private async getInbox(id: string) {
    const obj = await this.env.BLOBS.get(this.r2Key("i", id));
    if (!obj) return error(404, "no such inbox entry");
    return new Response(obj.body, { headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) } });
  }

  private async ackInbox(id: string) {
    await this.env.BLOBS.delete(this.r2Key("i", id));
    this.sql.exec("UPDATE inbox SET acked = 1 WHERE id = ?", id);
    return new Response(null, { status: 204 });
  }

  // ---------- WebDAV listing (used by webdav.ts) ----------

  davList(prefix: string) {
    return this.sql
      .exec<{ path: string; size: number; etag: string; updated_at: number; is_dir: number }>(
        "SELECT path, size, etag, updated_at, is_dir FROM dav WHERE path = ? OR path LIKE ? ORDER BY path",
        prefix, `${prefix.replace(/\/$/, "")}/%`,
      )
      .toArray();
  }
  davGet(path: string) {
    return this.sql
      .exec<{ path: string; size: number; etag: string; updated_at: number; is_dir: number }>("SELECT * FROM dav WHERE path = ?", path)
      .toArray()[0];
  }
  davPut(path: string, size: number, isDir: boolean) {
    const etag = randomId();
    this.sql.exec(
      "INSERT INTO dav(path, size, etag, updated_at, is_dir) VALUES(?, ?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET size = excluded.size, etag = excluded.etag, updated_at = excluded.updated_at, is_dir = excluded.is_dir",
      path, size, etag, Date.now(), isDir ? 1 : 0,
    );
    return etag;
  }
  davDelete(path: string) {
    this.sql.exec("DELETE FROM dav WHERE path = ? OR path LIKE ?", path, `${path.replace(/\/$/, "")}/%`);
  }
  davMove(from: string, to: string) {
    const item = this.davGet(from);
    if (!item) return false;
    this.davDelete(to);
    this.sql.exec("UPDATE dav SET path = ? WHERE path = ?", to, from);
    this.sql.exec("UPDATE inbox SET dav_path = ? WHERE dav_path = ?", to, from);
    return true;
  }

  // ---------- price watches (PROTOCOL.md §5) ----------

  /** Overridable in tests. */
  fetchPage: typeof fetch = (input, init) => fetch(input, init);

  private watchRow(r: Record<string, SqlStorageValue>) {
    return {
      id: r.id, url: r.url, itemId: r.item_id, createdAt: r.created_at, checkedAt: r.checked_at || null,
      error: r.error ?? null, price: r.price ?? null, currency: r.currency ?? null, lowest: r.lowest ?? null,
      history: JSON.parse((r.history as string) || "[]"), droppedAt: r.dropped_at ?? null,
    };
  }

  private listWatches() {
    return json({ watches: this.sql.exec("SELECT * FROM watches ORDER BY created_at").toArray().map((r) => this.watchRow(r)) });
  }

  private async putWatch(id: string, body: { url?: string; itemId?: string }) {
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(id)) return error(400, "bad watch id");
    let url: URL;
    try { url = new URL(body.url ?? ""); } catch { return error(400, "url required"); }
    if (url.protocol !== "https:" && url.protocol !== "http:") return error(400, "http(s) urls only");
    const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM watches").one().n;
    const exists = this.sql.exec("SELECT 1 FROM watches WHERE id = ?", id).toArray()[0];
    if (!exists && count >= MAX_WATCHES) return error(429, "too many watches");
    this.sql.exec(
      "INSERT INTO watches(id, url, item_id, created_at) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET url = excluded.url, item_id = excluded.item_id",
      id, url.toString(), body.itemId ?? null, Date.now(),
    );
    // Check right away (in the alarm) and keep a 12h cadence afterwards.
    await this.ctx.storage.setAlarm(Date.now() + 1000);
    return json(this.watchRow(this.sql.exec("SELECT * FROM watches WHERE id = ?", id).one()), exists ? 200 : 201);
  }

  private async deleteWatch(id: string) {
    this.sql.exec("DELETE FROM watches WHERE id = ?", id);
    return new Response(null, { status: 204 });
  }

  /** Re-checks the stalest watches; pings devices about any price drop. */
  async checkWatches(now = Date.now()) {
    const due = this.sql
      .exec("SELECT * FROM watches WHERE checked_at < ? ORDER BY checked_at LIMIT ?", now - PRICE_CHECK_EVERY_MS + 60_000, PRICE_CHECKS_PER_RUN)
      .toArray();
    for (const row of due) {
      const result = await checkPrice(row.url as string, this.fetchPage);
      if ("error" in result) {
        this.sql.exec("UPDATE watches SET checked_at = ?, error = ? WHERE id = ?", now, result.error, row.id);
        continue;
      }
      const price: Price = result;
      const previous = row.price as number | null;
      const history = (JSON.parse((row.history as string) || "[]") as { at: number; price: number }[]);
      if (previous === null || price.amount !== previous) history.push({ at: now, price: price.amount });
      const lowest = Math.min(price.amount, (row.lowest as number | null) ?? Infinity);
      const dropped = previous !== null && price.amount < previous;
      this.sql.exec(
        "UPDATE watches SET checked_at = ?, error = NULL, price = ?, currency = ?, lowest = ?, history = ?, dropped_at = COALESCE(?, dropped_at) WHERE id = ?",
        now, price.amount, price.currency ?? row.currency ?? null, lowest, JSON.stringify(history.slice(-60)), dropped ? now : null, row.id,
      );
      if (dropped) this.broadcast({ type: "price", id: row.id, itemId: row.item_id, price: price.amount, previous, currency: price.currency });
    }
    return due.length;
  }

  async alarm() {
    // Bridges first, within their own small fetch budget; price checks keep theirs (bridges.ts).
    await this.bridges.runDue(Date.now(), FETCH_BUDGET);
    await this.checkWatches();
    const times: number[] = [];
    const remaining = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM watches").one().n;
    if (remaining > 0) {
      const next = this.sql.exec<{ c: number }>("SELECT MIN(checked_at) AS c FROM watches").one().c ?? 0;
      times.push(next + PRICE_CHECK_EVERY_MS);
    }
    const bridgeNext = this.bridges.nextDue();
    if (bridgeNext !== null) times.push(bridgeNext);
    if (times.length) await this.ctx.storage.setAlarm(Math.max(Date.now() + 60_000, Math.min(...times)));
  }

  // ---------- publish to link (PROTOCOL.md §6) ----------

  private publish(slug: string, body: { title?: string; markdown?: string }) {
    if (!/^[A-Za-z0-9_-]{6,64}$/.test(slug)) return error(400, "bad slug");
    const title = String(body.title ?? "Untitled").slice(0, 200);
    const markdown = String(body.markdown ?? "");
    if (new TextEncoder().encode(markdown).length > MAX_PUBLISHED_BYTES) return error(413, "page too large");
    this.sql.exec(
      "INSERT INTO published(slug, title, markdown, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(slug) DO UPDATE SET title = excluded.title, markdown = excluded.markdown, updated_at = excluded.updated_at",
      slug, title, markdown, Date.now(),
    );
    return json({ slug, path: `/p/${this.vaultId}/${slug}` }, 201);
  }

  private publicPage(slug: string) {
    const row = this.sql.exec<{ title: string; markdown: string; updated_at: number }>("SELECT title, markdown, updated_at FROM published WHERE slug = ?", slug).toArray()[0];
    if (!row) return new Response("Not found", { status: 404, headers: { "content-type": "text/plain" } });
    return publishedPage(row.title, row.markdown, row.updated_at);
  }

  // ---------- live sockets ----------

  private live(request: Request, deviceId: string) {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return error(426, "expected websocket");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [deviceId]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** Merges segment pings per device until uploads pause (or 1.5 s pass), then sends one each. */
  private queueSegmentPing(cursor: number, device: string, first: number, last: number) {
    const now = Date.now();
    const pending = this.segmentPings.get(device);
    if (pending) {
      pending.cursor = Math.max(pending.cursor, cursor);
      pending.first = Math.min(pending.first, first);
      pending.last = Math.max(pending.last, last);
      pending.count++;
    } else {
      this.segmentPings.set(device, { type: "segment", cursor, device, first, last, count: 1 });
    }
    if (this.segmentPingTimer === null) this.segmentPingSince = now;
    else clearTimeout(this.segmentPingTimer);
    const wait = Math.max(0, Math.min(SEGMENT_PING_QUIET_MS, this.segmentPingSince + SEGMENT_PING_MAX_WAIT_MS - now));
    this.segmentPingTimer = setTimeout(() => this.flushSegmentPings(), wait);
  }

  private flushSegmentPings() {
    this.segmentPingTimer = null;
    const pings = [...this.segmentPings.values()];
    this.segmentPings.clear();
    for (const ping of pings) this.broadcast(ping);
  }

  private broadcast(message: unknown) {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(text);
      } catch {
        // socket already closing
      }
    }
  }

  async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer) {
    // Clients only listen; "ping" is answered by the auto-response without waking us.
  }

  async webSocketClose(ws: WebSocket, code: number) {
    try {
      ws.close(code, "closing");
    } catch {
      // already closed
    }
  }
}

/** R2 needs a stream of known length; this also rejects bodies that lie about Content-Length. */
function fixedLength(body: ReadableStream<Uint8Array>, length: number): ReadableStream<Uint8Array> {
  const fixed = new FixedLengthStream(length);
  void body.pipeTo(fixed.writable).catch(() => {});
  return fixed.readable;
}

export class HttpError extends Error {
  /** `tokens`: what a failed Claude call still cost, so the monthly allowance counts it. */
  constructor(public status: number, message: string, public tokens = 0) {
    super(message);
  }
}
