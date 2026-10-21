// Bridges (PROTOCOL.md §4 "Bridges"): things outside Trove that add to the vault through the sealed
// inbox. The relay fetches or receives public things (a feed, GitHub stars, a Telegram message, a
// webhook post), seals each into the inbox with the vault's public key, and devices import them as
// usual. The relay never reads the vault; it only keeps each bridge's settings and status.
//
// Kinds: "webhook" (a secret "add" URL), "rss" (one feed), "github" (a user's public stars and,
// optionally, releases of their own repos), "telegram" (a bot the user made with BotFather).
// Polling kinds run on the vault's Durable Object alarm, shared with price watches.
import { b64uDecode, b64uEncode, randomToken, type InboxHeader } from "./crypto";
import { parseFeed, repoNote, repoTags, type GitHubRelease, type GitHubRepo } from "./feeds";
import { FetchRefused, linkPreview, safeFetch } from "./preview";

export const BRIDGE_KINDS = ["webhook", "rss", "github", "telegram"] as const;
export type BridgeKind = (typeof BRIDGE_KINDS)[number];

const MAX_BRIDGES = 40;
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
/** How often each polling kind runs (backing off after failures, up to a day). */
const EVERY: Partial<Record<BridgeKind, number>> = { rss: 2 * HOUR, github: 6 * HOUR };
/** External fetches per alarm run for all bridges (price watches use up to 40; the free plan allows 50). */
export const FETCH_BUDGET = 9;
const HOOK_POSTS_PER_HOUR = 120;
const PREVIEWS_PER_HOUR = 240;
const RUN_NOW_EVERY = 2 * MINUTE;
const MAX_NEW_PER_RUN = 25;
const FIRST_RUN_FEED_ENTRIES = 5;
const MAX_SEEN = 1500;
const MAX_HOOK_TEXT = 256 * 1024;
const MAX_HOOK_FILE = 20 * 1024 * 1024;
const MAX_TELEGRAM_FILE = 20 * 1024 * 1024;

export interface BridgeHost {
  sql: SqlStorage;
  storage: DurableObjectStorage;
  vaultId(): string;
  /** Overridable fetch (tests). */
  fetcher(): typeof fetch;
  /** Seals plaintext into the inbox (VaultObject.sealIntoInbox). */
  seal(header: InboxHeader, body: Uint8Array): Promise<{ id: string; cursor: number }>;
  /** Optional Worker secret that encrypts stored tokens (`BRIDGE_KEY`). */
  tokenKey?: string;
}

interface Row {
  id: string; kind: BridgeKind; enabled: number; settings: string; secret: string | null; hook: string | null;
  state: string; created_at: number; last_run_at: number | null; next_run_at: number; last_error: string | null;
  last_error_at: number | null; failures: number; items_added: number; last_added_at: number | null;
}

type Settings = Record<string, unknown>;
type State = Record<string, unknown>;

class BridgeError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const str = (v: unknown, max = 200) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const bool = (v: unknown, fallback: boolean) => (typeof v === "boolean" ? v : fallback);

/** "Feeds/Tech" → ["Feeds", "Tech"]; also accepts an array. */
export function folderHint(v: unknown): string[] {
  const parts = Array.isArray(v) ? v : typeof v === "string" ? v.split("/") : [];
  return parts.map((p) => str(p, 80)).filter(Boolean).slice(0, 5);
}

export function tagList(v: unknown): string[] {
  const raw = Array.isArray(v) ? v : typeof v === "string" ? v.split(/[,\s]+/) : [];
  return [...new Set(raw.map((t) => str(t, 40).replace(/^#/, "").toLowerCase()).filter(Boolean))].slice(0, 12);
}

export class Bridges {
  constructor(private host: BridgeHost) {
    host.sql.exec(`
      CREATE TABLE IF NOT EXISTS bridges(id TEXT PRIMARY KEY, kind TEXT, enabled INTEGER DEFAULT 1, settings TEXT DEFAULT '{}',
        secret TEXT, hook TEXT UNIQUE, state TEXT DEFAULT '{}', created_at INTEGER, last_run_at INTEGER, next_run_at INTEGER DEFAULT 0,
        last_error TEXT, last_error_at INTEGER, failures INTEGER DEFAULT 0, items_added INTEGER DEFAULT 0, last_added_at INTEGER);
      CREATE TABLE IF NOT EXISTS rate_limits(key TEXT PRIMARY KEY, window_start INTEGER, n INTEGER);
    `);
  }

  private get sql() { return this.host.sql; }
  private get fetch() { return this.host.fetcher(); }

  private row(id: string): Row | undefined {
    return this.sql.exec<Row & Record<string, SqlStorageValue>>("SELECT * FROM bridges WHERE id = ?", id).toArray()[0] as Row | undefined;
  }

  private rows(): Row[] {
    return this.sql.exec("SELECT * FROM bridges ORDER BY created_at").toArray() as unknown as Row[];
  }

  /** At most `limit` events per hour for `key`; false when over. */
  allow(key: string, limit: number, now = Date.now()): boolean {
    const r = this.sql.exec<{ window_start: number; n: number }>("SELECT window_start, n FROM rate_limits WHERE key = ?", key).toArray()[0];
    if (!r || now - r.window_start >= HOUR) {
      this.sql.exec("INSERT INTO rate_limits(key, window_start, n) VALUES(?, ?, 1) ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, n = 1", key, now);
      return true;
    }
    if (r.n >= limit) return false;
    this.sql.exec("UPDATE rate_limits SET n = n + 1 WHERE key = ?", key);
    return true;
  }

  // ---------- what devices see ----------

  view(r: Row, origin: string) {
    const settings = JSON.parse(r.settings || "{}") as Settings;
    const state = JSON.parse(r.state || "{}") as State;
    const out: Record<string, unknown> = {
      id: r.id, kind: r.kind, enabled: r.enabled === 1, settings, hasToken: Boolean(r.secret), createdAt: r.created_at,
      status: {
        lastRunAt: r.last_run_at ?? null, nextRunAt: r.enabled === 1 && EVERY[r.kind] ? r.next_run_at : null,
        lastError: r.last_error ?? null, lastErrorAt: r.last_error_at ?? null, itemsAdded: r.items_added, lastAddedAt: r.last_added_at ?? null,
      },
    };
    if (r.kind === "webhook" && r.hook) out.hookURL = `${origin}/hook/${this.host.vaultId()}/${r.hook}`;
    if (r.kind === "rss") out.title = (state.title as string | undefined) ?? null;
    if (r.kind === "telegram") {
      const bot = (state.bot as string | undefined) ?? null;
      out.telegram = { bot, linked: Boolean(state.chatId), linkURL: bot && !state.chatId ? `https://t.me/${bot}?start=${state.linkCode}` : null };
    }
    return out;
  }

  // ---------- device API: /vaults/:v/bridges ----------

  async route(request: Request, id: string | undefined, action: string | undefined): Promise<Response> {
    const origin = new URL(request.url).origin;
    const method = request.method;
    try {
      if (!id && method === "GET") return json({ bridges: this.rows().map((r) => this.view(r, origin)), kinds: BRIDGE_KINDS });
      if (!id && method === "POST") return json(this.view(await this.create(await body(request), origin), origin), 201);
      const r = id ? this.row(id) : undefined;
      if (!r) return json({ error: "no such bridge" }, 404);
      if (!action && method === "GET") return json(this.view(r, origin));
      if (!action && method === "PUT") return json(this.view(await this.change(r, await body(request), origin), origin));
      if (!action && method === "DELETE") {
        if (r.kind === "telegram" && r.secret) await this.telegram(await this.token(r), "deleteWebhook", {}).catch(() => {});
        this.sql.exec("DELETE FROM bridges WHERE id = ?", r.id);
        this.sql.exec("DELETE FROM rate_limits WHERE key LIKE ?", `%:${r.id}`);
        return new Response(null, { status: 204 });
      }
      if (action === "run" && method === "POST") {
        if (!EVERY[r.kind]) throw new BridgeError(400, "this bridge doesn't fetch anything");
        if (!this.allow(`run:${r.id}`, Math.floor(HOUR / RUN_NOW_EVERY))) throw new BridgeError(429, "wait a minute before running it again");
        await this.runOne(r, { budget: FETCH_BUDGET });
        return json(this.view(this.row(r.id)!, origin));
      }
      if (action === "regenerate" && method === "POST") {
        if (r.kind !== "webhook" && r.kind !== "telegram") throw new BridgeError(400, "this bridge has no address");
        const hook = randomToken("thk_");
        if (r.kind === "telegram") await this.setTelegramHook(await this.token(r), origin, hook);
        this.sql.exec("UPDATE bridges SET hook = ? WHERE id = ?", hook, r.id);
        return json(this.view(this.row(r.id)!, origin));
      }
      return json({ error: "not found" }, 404);
    } catch (e) {
      if (e instanceof BridgeError) return json({ error: e.message }, e.status);
      if (e instanceof FetchRefused) return json({ error: e.message }, 400);
      throw e;
    }
  }

  private async create(b: Record<string, unknown>, origin: string): Promise<Row> {
    const kind = b.kind as BridgeKind;
    if (!BRIDGE_KINDS.includes(kind)) throw new BridgeError(400, `kind must be one of ${BRIDGE_KINDS.join(", ")}`);
    const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM bridges").one().n;
    if (count >= MAX_BRIDGES) throw new BridgeError(429, "too many bridges");
    const settings = this.cleanSettings(kind, b.settings ?? {}, {});
    const id = crypto.randomUUID();
    const state: State = {};
    let hook: string | null = null, secret: string | null = null;
    if (kind === "webhook" || kind === "telegram") hook = randomToken("thk_");
    if (kind === "telegram") {
      const token = str(b.token, 100);
      if (!/^\d+:[A-Za-z0-9_-]{20,}$/.test(token)) throw new BridgeError(400, "that doesn't look like a bot token from BotFather");
      const me = await this.telegram(token, "getMe", {}) as { username?: string };
      state.bot = me.username ?? null;
      state.linkCode = b64uEncode(crypto.getRandomValues(new Uint8Array(9)));
      await this.setTelegramHook(token, origin, hook!);
      secret = await this.sealToken(token);
    } else if (kind === "github" && str(b.token, 300)) {
      secret = await this.sealToken(str(b.token, 300));
    }
    const enabled = bool(b.enabled, true);
    this.sql.exec(
      "INSERT INTO bridges(id, kind, enabled, settings, secret, hook, state, created_at, next_run_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
      id, kind, enabled ? 1 : 0, JSON.stringify(settings), secret, hook, JSON.stringify(state), Date.now(), Date.now(),
    );
    if (enabled && EVERY[kind]) await this.schedule(Date.now() + 1000);
    return this.row(id)!;
  }

  private async change(r: Row, b: Record<string, unknown>, _origin: string): Promise<Row> {
    const old = JSON.parse(r.settings || "{}") as Settings;
    const settings = b.settings === undefined ? old : this.cleanSettings(r.kind, b.settings, old);
    const enabled = bool(b.enabled, r.enabled === 1);
    let secret = r.secret;
    if (r.kind === "github" && b.token !== undefined) secret = str(b.token, 300) ? await this.sealToken(str(b.token, 300)) : null;
    // A changed feed or user starts over (with the first-run limits), and a re-enabled bridge runs soon.
    const restart = (r.kind === "rss" && settings.url !== old.url) || (r.kind === "github" && settings.username !== old.username);
    const wake = enabled && (r.enabled !== 1 || restart);
    this.sql.exec(
      "UPDATE bridges SET enabled = ?, settings = ?, secret = ?, state = ?, failures = CASE WHEN ? THEN 0 ELSE failures END, next_run_at = CASE WHEN ? THEN ? ELSE next_run_at END WHERE id = ?",
      enabled ? 1 : 0, JSON.stringify(settings), secret, restart ? "{}" : r.state, wake ? 1 : 0, wake ? 1 : 0, Date.now(), r.id,
    );
    if (wake && EVERY[r.kind]) await this.schedule(Date.now() + 1000);
    return this.row(r.id)!;
  }

  private cleanSettings(kind: BridgeKind, raw: unknown, old: Settings): Settings {
    const s = (raw && typeof raw === "object" ? raw : {}) as Settings;
    const pick = <T>(k: string, f: (v: unknown) => T, fallback: T): T => (s[k] !== undefined ? f(s[k]) : old[k] !== undefined ? (old[k] as T) : fallback);
    const folder = pick("folder", (v) => folderHint(v).join("/"), "");
    switch (kind) {
      case "webhook":
        return { name: pick("name", (v) => str(v, 60), "Webhook"), folder, tags: pick("tags", tagList, [] as string[]) };
      case "rss": {
        const url = pick("url", (v) => str(v, 2000), "");
        let parsed: URL;
        try { parsed = new URL(url); } catch { throw new BridgeError(400, "a feed address (http or https) is needed"); }
        if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new BridgeError(400, "a feed address (http or https) is needed");
        return { url: parsed.toString(), name: pick("name", (v) => str(v, 100), ""), folder: folder || "Feeds" };
      }
      case "github": {
        const username = pick("username", (v) => str(v, 39), "");
        if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/.test(username)) throw new BridgeError(400, "a GitHub username is needed");
        return { username, stars: pick("stars", (v) => bool(v, true), true), releases: pick("releases", (v) => bool(v, false), false), folder: folder || "GitHub" };
      }
      case "telegram":
        return { folder, tags: pick("tags", tagList, [] as string[]) };
    }
  }

  // ---------- tokens (encrypted at rest when BRIDGE_KEY is set) ----------

  private async tokenCipher(): Promise<CryptoKey | null> {
    if (!this.host.tokenKey) return null;
    const ikm = await crypto.subtle.importKey("raw", new TextEncoder().encode(this.host.tokenKey), "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode(this.host.vaultId()), info: new TextEncoder().encode("trove/v1/bridge-token") },
      ikm, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
    );
  }

  private async sealToken(token: string): Promise<string> {
    const key = await this.tokenCipher();
    if (!key) return "plain:" + token;
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(token)));
    const out = new Uint8Array(12 + ct.length);
    out.set(iv);
    out.set(ct, 12);
    return "v1:" + b64uEncode(out);
  }

  private async token(r: Row): Promise<string> {
    if (!r.secret) return "";
    if (r.secret.startsWith("plain:")) return r.secret.slice(6);
    const key = await this.tokenCipher();
    if (!key) throw new BridgeError(500, "BRIDGE_KEY is missing, so the stored token can't be read");
    const raw = b64uDecode(r.secret.slice(3));
    return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(0, 12) }, key, raw.subarray(12)));
  }

  // ---------- running ----------

  /** Sets the alarm for `at` unless one is already due sooner. */
  async schedule(at: number) {
    const current = await this.host.storage.getAlarm();
    if (current === null || current > at) await this.host.storage.setAlarm(at);
  }

  /** When the next polling bridge is due, or null if none is enabled. */
  nextDue(): number | null {
    const kinds = Object.keys(EVERY).map((k) => `'${k}'`).join(",");
    return this.sql.exec<{ t: number | null }>(`SELECT MIN(next_run_at) AS t FROM bridges WHERE enabled = 1 AND kind IN (${kinds})`).one().t ?? null;
  }

  /** Runs the bridges that are due, within the fetch budget. Returns how many ran. */
  async runDue(now = Date.now(), budget = FETCH_BUDGET): Promise<number> {
    const kinds = Object.keys(EVERY).map((k) => `'${k}'`).join(",");
    const due = this.sql.exec(`SELECT * FROM bridges WHERE enabled = 1 AND kind IN (${kinds}) AND next_run_at <= ? ORDER BY next_run_at LIMIT 10`, now)
      .toArray() as unknown as Row[];
    const left = { budget };
    let ran = 0;
    for (const r of due) {
      if (left.budget <= 0) break;
      await this.runOne(r, left, now);
      ran++;
    }
    return ran;
  }

  private async runOne(r: Row, left: { budget: number }, now = Date.now()) {
    const settings = JSON.parse(r.settings || "{}") as Settings;
    const state = JSON.parse(r.state || "{}") as State;
    let added = 0;
    let failure: string | null = null;
    try {
      if (r.kind === "rss") added = await this.runFeed(r, settings, state, left);
      else if (r.kind === "github") added = await this.runGitHub(r, settings, state, left);
    } catch (e) {
      failure = e instanceof Error ? e.message : String(e);
      if (/abort|timed? ?out/i.test(failure)) failure = "the site took too long to answer";
    }
    const failures = failure ? r.failures + 1 : 0;
    const every = EVERY[r.kind] ?? HOUR;
    const next = now + Math.min(every * 2 ** Math.min(failures, 4), 24 * HOUR);
    this.sql.exec(
      `UPDATE bridges SET state = ?, last_run_at = ?, next_run_at = ?, failures = ?, last_error = ?, last_error_at = CASE WHEN ? IS NULL THEN last_error_at ELSE ? END,
        items_added = items_added + ?, last_added_at = CASE WHEN ? > 0 THEN ? ELSE last_added_at END WHERE id = ?`,
      JSON.stringify(state), now, next, failures, failure, failure, now, added, added, now, r.id,
    );
  }

  private spend(left: { budget: number }) {
    if (left.budget <= 0) throw new BridgeError(503, "out of fetches for this run; it continues on the next one");
    left.budget--;
  }

  private seen(state: State, key: string): Set<string> {
    return new Set(Array.isArray(state[key]) ? (state[key] as string[]) : []);
  }
  private remember(state: State, key: string, seen: Set<string>) {
    state[key] = [...seen].slice(-MAX_SEEN);
  }

  private async seal(r: Row, header: Omit<InboxHeader, "v" | "receivedAt">, body: string | Uint8Array) {
    const bytes = typeof body === "string" ? new TextEncoder().encode(body) : body;
    await this.host.seal({ v: 1, receivedAt: new Date().toISOString(), ...header, meta: { bridge: r.id, ...(header.meta ?? {}) } } as InboxHeader, bytes);
  }

  private async runFeed(r: Row, settings: Settings, state: State, left: { budget: number }): Promise<number> {
    this.spend(left);
    const headers: Record<string, string> = {};
    if (typeof state.etag === "string") headers["if-none-match"] = state.etag;
    if (typeof state.modified === "string") headers["if-modified-since"] = state.modified;
    const res = await safeFetch(settings.url as string, this.fetch, {
      maxBytes: 3_000_000, timeoutMs: 10_000, headers,
      accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5",
    });
    if (res.status === 304) return 0;
    if (res.status >= 400) throw new Error(`the feed answered ${res.status}`);
    const feed = parseFeed(res.text, res.url);
    if (!feed) throw new Error("that address isn't an RSS or Atom feed");
    state.etag = res.headers.get("etag") ?? undefined;
    state.modified = res.headers.get("last-modified") ?? undefined;
    if (feed.title) state.title = feed.title;
    const name = (settings.name as string) || feed.title || new URL(res.url).hostname;
    const seen = this.seen(state, "seen");
    const firstRun = !state.ran;
    const fresh = feed.entries.filter((e) => !seen.has(e.id));
    const take = (firstRun ? fresh.slice(0, FIRST_RUN_FEED_ENTRIES) : fresh.slice(0, MAX_NEW_PER_RUN)).reverse(); // oldest first
    let added = 0;
    for (const e of take) {
      await this.seal(r, {
        source: "rss", title: e.title || name, mime: "text/plain", ...(e.url ? { url: e.url } : {}),
        folder: [...folderHint(settings.folder), name], meta: { feed: name, feedURL: settings.url, published: e.published, author: e.author },
      }, e.summary);
      added++;
    }
    for (const e of feed.entries) seen.add(e.id);
    this.remember(state, "seen", seen);
    state.ran = true;
    return added;
  }

  private async github<T>(path: string, token: string, left: { budget: number }, accept = "application/vnd.github+json"): Promise<T> {
    this.spend(left);
    const headers: Record<string, string> = { accept, "user-agent": "trove-relay", "x-github-api-version": "2022-11-28" };
    if (token) headers.authorization = `Bearer ${token}`;
    const res = await this.fetch(`https://api.github.com${path}`, { headers, signal: AbortSignal.timeout(10_000) });
    if (res.status === 404) throw new Error("GitHub doesn't know that user");
    if (res.status === 401) throw new Error("GitHub didn't accept the token");
    if (res.status === 403 || res.status === 429) throw new Error("GitHub's rate limit was reached; it will try again later");
    if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
    return (await res.json()) as T;
  }

  private async runGitHub(r: Row, settings: Settings, state: State, left: { budget: number }): Promise<number> {
    const user = encodeURIComponent(settings.username as string);
    const token = await this.token(r);
    const top = folderHint(settings.folder);
    let added = 0;
    if (settings.stars !== false) {
      const seen = this.seen(state, "stars");
      const pages = [1];
      const backfill = typeof state.starsPage === "number" ? state.starsPage : 2;
      if (backfill > 0 && left.budget >= 3) pages.push(backfill);
      for (const page of pages) {
        const list = await this.github<{ repo: GitHubRepo; starred_at?: string }[]>(
          `/users/${user}/starred?per_page=30&page=${page}`, token, left, "application/vnd.github.star+json");
        for (const { repo, starred_at } of list.reverse()) {
          if (!repo || seen.has(String(repo.id))) continue;
          await this.seal(r, {
            source: "github", url: repo.html_url, title: repo.full_name, mime: "text/plain", folder: [...top, "Stars"], tags: repoTags(repo),
            meta: { repo: repo.full_name, language: repo.language, topics: repo.topics ?? [], starredAt: starred_at ?? null },
          }, repoNote(repo));
          seen.add(String(repo.id));
          added++;
        }
        if (page > 1) state.starsPage = list.length < 30 || page >= 34 ? 0 : page + 1;
        this.remember(state, "stars", seen); // kept per page, so a later failure never re-adds these
      }
      this.remember(state, "stars", seen);
    }
    if (settings.releases === true && left.budget >= 2) {
      const seen = this.seen(state, "releases");
      const firstRun = !state.releasesRan;
      const repos = (await this.github<GitHubRepo[]>(`/users/${user}/repos?type=owner&sort=pushed&per_page=10`, token, left))
        .filter((repo) => !repo.fork).slice(0, Math.min(4, left.budget));
      for (const repo of repos) {
        const releases = await this.github<GitHubRelease[]>(`/repos/${repo.full_name}/releases?per_page=3`, token, left);
        for (const rel of releases.reverse()) {
          if (rel.draft || seen.has(String(rel.id))) continue;
          seen.add(String(rel.id));
          if (firstRun) continue; // only releases made after the bridge was turned on
          await this.seal(r, {
            source: "github", url: rel.html_url, title: `${repo.full_name} ${rel.name || rel.tag_name}`, mime: "text/plain",
            folder: [...top, "Releases"], tags: ["github", "release"], meta: { repo: repo.full_name, tag: rel.tag_name, published: rel.published_at ?? null },
          }, (rel.body ?? "").slice(0, 4000));
          added++;
        }
      }
      state.releasesRan = true;
      this.remember(state, "releases", seen);
    }
    return added;
  }

  // ---------- incoming: POST /hook/:vault/:secret (webhook and Telegram) ----------

  async hook(request: Request, secret: string): Promise<Response> {
    if (request.method !== "POST") return json({ error: "use POST" }, 405);
    const r = /^thk_[A-Za-z0-9_-]{20,}$/.test(secret)
      ? (this.sql.exec("SELECT * FROM bridges WHERE hook = ?", secret).toArray()[0] as unknown as Row | undefined)
      : undefined;
    if (!r) return json({ error: "not found" }, 404);
    if (r.kind === "telegram") return this.telegramUpdate(r, request, secret);
    if (r.enabled !== 1) return json({ error: "this bridge is turned off" }, 403);
    if (!this.allow(`hook:${r.id}`, HOOK_POSTS_PER_HOUR)) return json({ error: "too many posts; try again later" }, 429);
    try {
      const n = await this.webhookPost(r, request);
      this.counted(r, n);
      return json({ ok: true, added: n }, 201);
    } catch (e) {
      if (e instanceof BridgeError) return json({ error: e.message }, e.status);
      throw e;
    }
  }

  private counted(r: Row, n: number, now = Date.now()) {
    this.sql.exec("UPDATE bridges SET last_run_at = ?, items_added = items_added + ?, last_added_at = CASE WHEN ? > 0 THEN ? ELSE last_added_at END WHERE id = ?",
      now, n, n, now, r.id);
  }
  private failed(r: Row, message: string, now = Date.now()) {
    this.sql.exec("UPDATE bridges SET last_run_at = ?, last_error = ?, last_error_at = ? WHERE id = ?", now, message, now, r.id);
  }

  private async webhookPost(r: Row, request: Request): Promise<number> {
    const settings = JSON.parse(r.settings || "{}") as Settings;
    const type = (request.headers.get("content-type") ?? "").toLowerCase();
    const length = Number(request.headers.get("content-length") ?? 0);
    let fields: Record<string, unknown> = {};
    let file: File | null = null;
    if (type.includes("multipart/form-data") || type.includes("application/x-www-form-urlencoded")) {
      if (length > MAX_HOOK_FILE + 64 * 1024) throw new BridgeError(413, "that's too big (20 MB at most)");
      const form = await request.formData();
      for (const [k, v] of form.entries()) {
        if (typeof v === "string") fields[k] = k === "tags" && fields.tags ? `${fields.tags},${v}` : v;
        else if (!file) file = v as unknown as File;
      }
    } else {
      if (length > MAX_HOOK_TEXT) throw new BridgeError(413, "that's too big");
      const raw = (await request.text()).slice(0, MAX_HOOK_TEXT);
      if (type.includes("json") || /^\s*\{/.test(raw)) {
        try { fields = JSON.parse(raw) as Record<string, unknown>; } catch { throw new BridgeError(400, "that JSON couldn't be read"); }
        if (!fields || typeof fields !== "object" || Array.isArray(fields)) throw new BridgeError(400, "send a JSON object");
      } else {
        fields = { text: raw };
      }
    }
    let url = str(fields.url, 4000);
    let text = typeof fields.text === "string" ? fields.text.slice(0, MAX_HOOK_TEXT) : "";
    if (!url && /^\s*https?:\/\/\S+\s*$/.test(text)) { url = text.trim(); text = ""; }
    if (url) {
      try {
        const u = new URL(url);
        if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error();
        url = u.toString();
      } catch { throw new BridgeError(400, "url must be an http or https link"); }
    }
    const title = str(fields.title, 300) || undefined;
    const folder = folderHint(fields.folder).length ? folderHint(fields.folder) : folderHint(settings.folder);
    const tags = [...new Set([...tagList(settings.tags), ...tagList(fields.tags)])];
    const common = { source: "webhook" as const, ...(folder.length ? { folder } : {}), ...(tags.length ? { tags } : {}) };
    let n = 0;
    if (file && file.size > 0) {
      if (file.size > MAX_HOOK_FILE) throw new BridgeError(413, "that file is too big (20 MB at most)");
      await this.seal(r, { ...common, name: str(file.name, 200) || "file", mime: file.type || "application/octet-stream", title }, new Uint8Array(await file.arrayBuffer()));
      n++;
      if (!url && !text) return n;
    }
    if (!url && !text.trim()) {
      if (n) return n;
      throw new BridgeError(400, "send a url, some text or a file");
    }
    await this.seal(r, { ...common, mime: "text/plain", ...(url ? { url } : {}), ...(title ? { title } : {}) }, text);
    return n + 1;
  }

  // ---------- Telegram ----------

  private async telegram(token: string, method: string, params: Record<string, unknown>): Promise<unknown> {
    const res = await this.fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(params), signal: AbortSignal.timeout(10_000),
    });
    const body = (await res.json().catch(() => ({}))) as { ok?: boolean; result?: unknown; description?: string };
    if (!body.ok) {
      if (res.status === 401 || res.status === 404) throw new BridgeError(400, "Telegram didn't accept that bot token");
      throw new BridgeError(502, `Telegram said: ${body.description ?? res.status}`);
    }
    return body.result;
  }

  private async setTelegramHook(token: string, origin: string, hook: string) {
    await this.telegram(token, "setWebhook", {
      url: `${origin}/hook/${this.host.vaultId()}/${hook}`, secret_token: hook.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 256),
      allowed_updates: ["message", "channel_post"], drop_pending_updates: true,
    });
  }

  /** Telegram retries anything but 200, so problems are recorded on the bridge and answered with 200. */
  private async telegramUpdate(r: Row, request: Request, hook: string): Promise<Response> {
    if (request.headers.get("x-telegram-bot-api-secret-token") !== hook) return json({ error: "not found" }, 404);
    const ok = () => json({ ok: true });
    const update = (await request.json().catch(() => null)) as TelegramUpdate | null;
    const msg = update?.message ?? update?.channel_post;
    if (!msg?.chat || r.enabled !== 1) return ok();
    const state = JSON.parse(r.state || "{}") as State;
    const settings = JSON.parse(r.settings || "{}") as Settings;
    const token = await this.token(r);
    const chatId = String(msg.chat.id);
    const reply = (text: string) => this.telegram(token, "sendMessage", { chat_id: msg.chat.id, text, reply_to_message_id: msg.message_id }).catch(() => {});
    const text = msg.text ?? msg.caption ?? "";
    if (!state.chatId) {
      if (text.trim() === `/start ${state.linkCode}`) {
        state.chatId = chatId;
        this.sql.exec("UPDATE bridges SET state = ? WHERE id = ?", JSON.stringify(state), r.id);
        await reply("Connected to your Trove. Send me links, notes, photos or files and they'll be saved.");
      }
      return ok();
    }
    if (state.chatId !== chatId) return ok(); // only the linked chat can add
    if (/^\/start\b/.test(text.trim())) {
      await reply("Send me links, notes, photos or files and they'll be saved to Trove.");
      return ok();
    }
    if (!this.allow(`hook:${r.id}`, HOOK_POSTS_PER_HOUR)) {
      await reply("That's a lot at once. Try again in a while.");
      return ok();
    }
    try {
      const n = await this.telegramMessage(r, msg, token, settings);
      this.counted(r, n);
      if (n) await reply("Saved to Trove.");
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      this.failed(r, message);
      await reply(`Couldn't save that: ${message}`);
    }
    return ok();
  }

  private async telegramMessage(r: Row, msg: TelegramMessage, token: string, settings: Settings): Promise<number> {
    const folder = folderHint(settings.folder);
    const tags = tagList(settings.tags);
    const common = {
      source: "telegram" as const, ...(folder.length ? { folder } : {}), ...(tags.length ? { tags } : {}),
      meta: { chat: msg.chat.title ?? msg.chat.username ?? null, messageId: msg.message_id, date: msg.date ? new Date(msg.date * 1000).toISOString() : null },
    };
    const caption = msg.caption?.trim() || undefined;
    const photo = msg.photo?.length ? msg.photo.reduce((a, b) => ((b.file_size ?? b.width * b.height) > (a.file_size ?? a.width * a.height) ? b : a)) : null;
    const doc = msg.document ?? msg.video ?? msg.audio ?? msg.voice ?? null;
    if (photo || doc) {
      const fileId = photo ? photo.file_id : doc!.file_id;
      const size = photo ? photo.file_size : doc!.file_size;
      if (size && size > MAX_TELEGRAM_FILE) throw new Error("Telegram only hands bots files up to 20 MB");
      const info = (await this.telegram(token, "getFile", { file_id: fileId })) as { file_path?: string };
      if (!info.file_path) throw new Error("Telegram didn't hand over the file");
      const res = await this.fetch(`https://api.telegram.org/file/bot${token}/${info.file_path}`, { signal: AbortSignal.timeout(20_000) });
      if (!res.ok) throw new Error(`Telegram answered ${res.status} for the file`);
      const bytes = new Uint8Array(await res.arrayBuffer());
      const name = photo ? `telegram-${msg.message_id}.jpg` : doc!.file_name ?? info.file_path.split("/").pop() ?? "file";
      const mime = photo ? "image/jpeg" : doc!.mime_type ?? "application/octet-stream";
      await this.seal(r, { ...common, name, mime, ...(caption ? { title: caption.split("\n")[0]!.slice(0, 200) } : {}) }, bytes);
      return 1;
    }
    const body = msg.text ?? "";
    if (!body.trim()) return 0;
    const urls = telegramURLs(body, msg.entities ?? []);
    const url = urls[0];
    const onlyURL = Boolean(url) && /^\S+$/.test(body.trim());
    await this.seal(r, { ...common, mime: "text/plain", ...(url ? { url } : {}) }, onlyURL ? "" : body);
    return 1;
  }

  // ---------- link previews: POST /vaults/:v/preview ----------

  async preview(request: Request): Promise<Response> {
    const b = await body(request);
    const url = str(b.url, 4000);
    if (!url) return json({ error: "url required" }, 400);
    if (!this.allow("preview", PREVIEWS_PER_HOUR)) return json({ error: "too many previews; try again later" }, 429);
    try {
      return json(await linkPreview(url, this.fetch));
    } catch (e) {
      if (e instanceof FetchRefused) return json({ error: e.message }, 400);
      const message = e instanceof Error ? e.message : String(e);
      return json({ error: /abort|time/i.test(message) ? "the site took too long to answer" : `couldn't fetch it: ${message}` }, 502);
    }
  }
}

async function body(request: Request): Promise<Record<string, unknown>> {
  const b = await request.json().catch(() => ({}));
  return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : {};
}

interface TelegramEntity { type: string; offset: number; length: number; url?: string }
interface TelegramFile { file_id: string; file_size?: number; file_name?: string; mime_type?: string }
interface TelegramMessage {
  message_id: number; date?: number; chat: { id: number; title?: string; username?: string };
  text?: string; caption?: string; entities?: TelegramEntity[];
  photo?: (TelegramFile & { width: number; height: number })[]; document?: TelegramFile; video?: TelegramFile; audio?: TelegramFile; voice?: TelegramFile;
}
interface TelegramUpdate { update_id: number; message?: TelegramMessage; channel_post?: TelegramMessage }

/** Links in a Telegram message: `url` entities (offsets in UTF-16 units, like JS strings) and `text_link`s. */
export function telegramURLs(text: string, entities: TelegramEntity[]): string[] {
  const out: string[] = [];
  for (const e of entities) {
    let u = e.type === "text_link" ? e.url ?? "" : e.type === "url" ? text.substr(e.offset, e.length) : "";
    if (u && !/^https?:\/\//i.test(u)) u = "https://" + u;
    try { const parsed = new URL(u); if (parsed.protocol === "http:" || parsed.protocol === "https:") out.push(parsed.toString()); } catch { /* not a link */ }
  }
  if (!out.length) {
    const m = /https?:\/\/[^\s<>"]+/i.exec(text);
    if (m) out.push(m[0].replace(/[).,;!?]+$/, ""));
  }
  return out;
}

