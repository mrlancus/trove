// The web app's vault: joins the relay as a "web" device, keeps a local copy of every op, pulls and
// pushes encrypted journal segments (docs/PROTOCOL.md §3–4) and edits records the same way the apps do.
import { b64uDecode, fromUtf8, hex } from "./bytes.js";
import { decodeSegment, encodeSegment, Journal, RecordStore } from "./records.js";
import { cleanURL, dedupeKey, Field, hashtags, itemView } from "./items.js";
import { importVaultKeys } from "./keys.js";
import { decrypt, encrypt, isTRV1 } from "./trv1.js";

/** Parses the setup code (or `trove://pair?d=` link) the apps show under "Add device". */
export function parseSetupCode(text) {
  let code = text.trim();
  const m = /[?&]d=([A-Za-z0-9_-]+)/.exec(code);
  if (m) code = m[1];
  let payload;
  try { payload = JSON.parse(fromUtf8.decode(b64uDecode(code))); } catch { throw new Error("That doesn't look like a Trove setup code."); }
  if (!payload?.keys?.vaultKey || !payload.vaultId) throw new Error("That setup code is missing the vault keys.");
  if (!payload.pairingCode) throw new Error("This setup code has no relay pairing code. Connect the relay in the app first.");
  return payload;
}

export class RelayError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export class Vault {
  /**
   * @param storage {get(key), set(key, value), clear()} – IndexedDB in the browser, a Map in tests.
   * @param options {origin, fetch, now}
   */
  constructor(storage, config, keys, journalState, pending, ops, applied, cursor, options = {}) {
    this.storage = storage;
    this.config = config;
    this.keys = keys;
    this.fetch = options.fetch ?? ((...a) => fetch(...a));
    this.now = options.now ?? (() => Date.now());
    this.journal = new Journal(journalState, pending, this.now);
    this.store = new RecordStore();
    this.store.apply(ops);
    this.applied = new Set(applied);
    this.cursor = cursor;
    this.listeners = new Set();
  }

  /** Joins the vault with a setup code and saves everything this browser needs. */
  static async join(storage, setupCode, { origin, deviceName = "Web browser", ...options } = {}) {
    const payload = parseSetupCode(setupCode);
    const relayVaultId = payload.relayVaultId ?? payload.vaultId;
    const base = origin ?? payload.relayURL;
    const keys = await importVaultKeys(payload.keys);
    const proposed = crypto.randomUUID().toUpperCase();
    const doFetch = options.fetch ?? ((...a) => fetch(...a));
    const res = await doFetch(`${base}/v1/vaults/${relayVaultId}/devices`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ pairingCode: payload.pairingCode, deviceName, deviceKind: "web", deviceId: proposed }),
    });
    if (res.status === 403 || res.status === 404) throw new Error("That setup code has expired or was already used. Make a new one in the app.");
    if (!res.ok) throw new Error(`The relay said ${res.status}: ${await res.text()}`);
    const joined = await res.json();
    const config = { v: 1, base, vaultId: relayVaultId, deviceId: joined.deviceId, token: joined.deviceToken, encrypted: payload.encrypted !== false, deviceName };
    await storage.set("config", config);
    await storage.set("keys", keys);
    const vault = new Vault(storage, config, keys, { device: joined.deviceId }, [], [], [], 0, options);
    await vault.save();
    return vault;
  }

  /** Opens the vault saved in this browser, or returns null. */
  static async open(storage, options = {}) {
    const config = await storage.get("config");
    const keys = await storage.get("keys");
    if (!config || !keys) return null;
    const journal = (await storage.get("journal")) ?? { state: { device: config.deviceId }, pending: [] };
    return new Vault(storage, config, keys, journal.state, journal.pending, (await storage.get("ops")) ?? [],
      (await storage.get("applied")) ?? [], (await storage.get("cursor")) ?? 0, options);
  }

  async save() {
    await this.storage.set("journal", { state: this.journal.state, pending: this.journal.pending });
    await this.storage.set("ops", this.store.ops);
    await this.storage.set("applied", [...this.applied]);
    await this.storage.set("cursor", this.cursor);
  }

  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  changed() { for (const fn of this.listeners) fn(); }

  // ---------- reading ----------

  items() {
    return this.store.visible.filter((r) => r.kind === "item").map(itemView).sort((a, b) => b.createdAt - a.createdAt);
  }

  item(id) {
    const r = this.store.records.get(id);
    return r && r.kind === "item" && r.fields._deleted !== true ? itemView(r) : null;
  }

  collections() {
    return this.store.visible.filter((r) => r.kind === "collection")
      .map((r) => ({ id: r.id, name: r.fields.name ?? "Untitled", symbol: r.fields.symbol, color: r.fields.color }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  // ---------- editing (same ops the Swift Library writes) ----------

  set(fields, record, kind) {
    const op = this.journal.set(fields, record, kind);
    this.store.apply([op]);
    this.edited();
    return op;
  }

  /** Local edits are saved straight away (sync uploads them later). */
  edited() {
    this.changed();
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.save().catch(() => {}), 250);
  }

  editText(field, value, record, kind) {
    const previous = this.store.records.get(record)?.texts[field] ?? "";
    if (previous === value) return null;
    const op = this.journal.text(field, value, previous, record, kind);
    this.store.apply([op]);
    this.edited();
    return op;
  }

  baseFields(kind, title) {
    return {
      [Field.kind]: kind, [Field.source]: "web", [Field.title]: title, [Field.createdAt]: this.now(),
      [Field.capturedOn]: this.journal.device, [Field.needsEnrichment]: true,
    };
  }

  addNote({ title = "", body = "" } = {}) {
    const id = crypto.randomUUID().toLowerCase();
    const fields = { ...this.baseFields("note", title), [Field.category]: "note" };
    const tags = [...new Set(hashtags(body))].sort();
    if (tags.length) fields[Field.tags] = tags;
    this.set(fields, id, "item");
    if (body) this.editText(Field.body, body, id, "item");
    return id;
  }

  /** Adds a link (the apps fetch its title and preview when they next enrich). */
  addLink(url, { title = "", note = "" } = {}) {
    const cleaned = cleanURL(url);
    const key = dedupeKey(cleaned.toString());
    const existing = this.items().find((i) => i.url && dedupeKey(i.url.toString()) === key);
    if (existing) return { id: existing.id, isNew: false };
    const id = crypto.randomUUID().toLowerCase();
    this.set({ ...this.baseFields("link", title), [Field.url]: cleaned.toString() }, id, "item");
    if (note) this.editText(Field.body, note, id, "item");
    return { id, isNew: true };
  }

  update(id, fields) { this.set(fields, id, "item"); }

  setBody(id, text) {
    this.editText(Field.body, text, id, "item");
    const tags = hashtags(text), item = this.item(id);
    if (item && tags.length && !tags.every((t) => item.tags.includes(t))) {
      this.update(id, { [Field.tags]: [...new Set([...item.tags, ...tags])].sort() });
    }
  }

  setPinned(id, pinned) { this.update(id, { [Field.pinned]: pinned }); }
  markRead(id, read = true) { this.update(id, { [Field.readAt]: read ? this.now() : null }); }
  delete(id) { this.set({ _deleted: true }, id); }

  resolveConflicts(id, keeping) {
    this.editText(Field.body, keeping, id, "item");
    const seen = this.store.records.get(id)?.conflicts.body?.length ?? 0;
    this.update(id, { [Field.resolvedConflicts]: seen });
  }

  toggleCollection(itemId, collectionId) {
    const item = this.item(itemId);
    if (!item) return;
    const next = item.collections.includes(collectionId) ? item.collections.filter((c) => c !== collectionId) : [...item.collections, collectionId];
    this.update(itemId, { [Field.collections]: next });
  }

  // ---------- relay ----------

  async api(method, path, { body, raw = false, expect = [200] } = {}) {
    const headers = { authorization: `Bearer ${this.config.token}` };
    if (body !== undefined && !(body instanceof Uint8Array)) headers["content-type"] = "application/json";
    const res = await this.fetch(`${this.config.base}/v1/vaults/${this.config.vaultId}/${path}`, {
      method, headers, body: body === undefined ? undefined : body instanceof Uint8Array ? body : JSON.stringify(body),
    });
    if (!expect.includes(res.status)) throw new RelayError(res.status, `${method} ${path}: ${res.status} ${(await res.text()).slice(0, 200)}`);
    if (raw) return new Uint8Array(await res.arrayBuffer());
    return res.status === 204 ? null : res.json();
  }

  async encodeOps(ops) {
    const plain = encodeSegment(ops);
    return this.config.encrypted ? encrypt(plain, this.keys.segment) : plain;
  }

  async decodeOps(data, device) {
    return decodeSegment(isTRV1(data) ? await decrypt(data, this.keys.segment) : data, device);
  }

  /** Pull everyone's new segments, then push ours. */
  async sync() {
    const report = { pulled: 0, pushed: 0, errors: [] };
    // Pull.
    let after = this.cursor, more = true, ok = true;
    while (more) {
      const page = await this.api("GET", `segments?after=${after}&limit=500`);
      for (const s of page.segments) {
        const key = `${s.device}/${s.first}`;
        if (!this.applied.has(key)) {
          try {
            const ops = await this.decodeOps(await this.api("GET", `segments/${s.device}/${s.first}/${s.last}`, { raw: true }), s.device);
            if (s.device === this.journal.device) this.makeRoomAfter(s.last);
            for (const op of ops) this.journal.observe(op.h);
            this.store.apply(ops);
            this.applied.add(key);
            report.pulled++;
          } catch (e) {
            ok = false;
            report.errors.push(`${key}: ${e.message}`);
          }
        }
        after = s.cursor;
      }
      more = page.more;
    }
    if (ok) this.cursor = after;
    // Push.
    for (const batch of this.journal.segments()) {
      const first = batch[0].s, last = batch[batch.length - 1].s;
      try {
        await this.api("PUT", `segments/${this.journal.device}/${first}/${last}`, { body: await this.encodeOps(batch), expect: [200, 201] });
        this.applied.add(`${this.journal.device}/${first}`);
        this.journal.pending = this.journal.pending.filter((op) => op.s > last);
        report.pushed++;
      } catch (e) {
        report.errors.push(`push ${first}: ${e.message}`);
        break;
      }
    }
    await this.save();
    if (report.pulled) this.changed();
    return report;
  }

  /** Our own journal on the relay already reaches `last` (another tab, or lost local state): move pending ops past it. */
  makeRoomAfter(last) {
    if (!this.journal.pending.length || this.journal.pending[0].s > last) {
      this.journal.state.nextSeq = Math.max(this.journal.state.nextSeq, last + 1);
      return;
    }
    const pendingIds = new Set(this.journal.pending.map((op) => `${op.d}:${op.s}`));
    const kept = this.store.ops.filter((op) => !pendingIds.has(`${op.d}:${op.s}`));
    this.journal.renumberFrom(last + 1);
    this.store = new RecordStore();
    this.store.apply([...kept, ...this.journal.pending]);
  }

  /** Decrypted bytes of an attachment. */
  async attachment(id) {
    const data = await this.api("GET", `blobs/${id}`, { raw: true });
    return isTRV1(data) ? decrypt(data, this.keys.blob) : data;
  }

  /** Uploads a file as an encrypted blob and adds an item for it (like Library.addFile). */
  async addFile(bytes, name, mime) {
    const id = hex(new Uint8Array(await crypto.subtle.sign("HMAC", this.keys.blobId, bytes)));
    const stored = this.config.encrypted ? await encrypt(bytes, this.keys.blob) : bytes;
    await this.api("PUT", `blobs/${id}`, { body: stored, expect: [200, 201, 204] });
    const kind = mime.startsWith("image/") ? "image" : mime === "application/pdf" ? "pdf" : mime.startsWith("audio/") ? "audio" : mime.startsWith("video/") ? "video" : "file";
    const title = name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").trim();
    const itemId = crypto.randomUUID().toLowerCase();
    this.set({ ...this.baseFields(kind, title), [Field.attachments]: [{ id, name, mime, size: bytes.length }] }, itemId, "item");
    return itemId;
  }

  get liveURL() {
    const u = new URL(`${this.config.base}/v1/vaults/${this.config.vaultId}/live`);
    u.protocol = u.protocol === "http:" ? "ws:" : "wss:";
    u.searchParams.set("token", this.config.token);
    return u.toString();
  }

  /** Removes this browser from the vault (revokes its token) and forgets everything stored here. */
  async forget() {
    try { await this.api("DELETE", `devices/${this.config.deviceId}`, { expect: [204] }); } catch { /* already revoked or offline */ }
    await this.storage.clear();
  }
}

