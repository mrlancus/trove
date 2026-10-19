// The web app's vault: joins the relay as a "web" device, keeps a local copy of every op, pulls and
// pushes encrypted journal segments (docs/PROTOCOL.md §3–4) and edits records the same way the apps do.
import { b64uDecode, b64uEncode, fromUtf8, hex, utf8 } from "./bytes.js";
import { decodeSegment, encodeSegment, Journal, RecordStore } from "./records.js";
import { cleanURL, dedupeKey, Field, hashtags, itemView } from "./items.js";
import { generateVaultSecrets, importInboxKey, importVaultKeys } from "./keys.js";
import { ClipField, clipView, hashImageHex, hashText } from "./clips.js";
import { decrypt, encrypt, isTRV1, parseEnvelope, unseal } from "./trv1.js";

/** Parses a setup or recovery code (or a `trove://pair?d=` link): the apps' `PairingPayload`. */
export function parsePayload(text) {
  let code = text.trim();
  const m = /[?&]d=([A-Za-z0-9_-]+)/.exec(code);
  if (m) code = m[1];
  let payload;
  try { payload = JSON.parse(fromUtf8.decode(b64uDecode(code.replace(/\s+/g, "")))); } catch { throw new Error("That doesn't look like a Trove setup code."); }
  if (!payload?.keys?.vaultKey || !payload.vaultId) throw new Error("That code is missing the vault keys.");
  return payload;
}

/** A setup code from "Add a device": a payload with a single-use relay pairing code. */
export function parseSetupCode(text) {
  const payload = parsePayload(text);
  if (!payload.pairingCode) throw new Error("This code has no relay pairing code. If it's your recovery code, use “Recover my vault” instead.");
  return payload;
}

const encodePayload = (payload) => b64uEncode(utf8.encode(JSON.stringify(payload)));

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
    this.store.apply(pending); // edits saved before the full op cache caught up
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
    return Vault.finishJoin(storage, payload, base, relayVaultId, joined, keys, deviceName, options);
  }

  /** Saves a newly joined device; keeps the inbox key when the code carried the private key. */
  static async finishJoin(storage, payload, base, relayVaultId, joined, keys, deviceName, options) {
    const config = { v: 1, base, vaultId: relayVaultId, deviceId: joined.deviceId, token: joined.deviceToken, encrypted: payload.encrypted !== false, deviceName,
      inboxToken: joined.inboxToken ?? payload.inboxToken ?? null };
    const vault = new Vault(storage, config, keys, { device: joined.deviceId }, [], [], [], 0, options);
    const info = await vault.api("GET", "info");
    config.vaultPublicKey = info.vaultPublicKey;
    if (payload.keys.privateKey) {
      const inbox = await importInboxKey(payload.keys.privateKey);
      if (inbox.publicKey !== info.vaultPublicKey) {
        await vault.forget();
        throw new Error("That code is for a different vault.");
      }
      keys.inbox = inbox.privateKey;
    }
    if (!config.inboxToken) config.inboxToken = (await vault.api("POST", "inbox-tokens", { expect: [201] })).inboxToken;
    await storage.set("config", config);
    await storage.set("keys", keys);
    await vault.save();
    return vault;
  }

  /**
   * Creates a brand-new vault on this relay with this browser as its first device. Returns the
   * recovery code: the only copy of the vault keys outside this browser's locked key store.
   */
  static async create(storage, { origin, deviceName = "Web browser", ...options } = {}) {
    const secrets = await generateVaultSecrets();
    const doFetch = options.fetch ?? ((...a) => fetch(...a));
    const res = await doFetch(`${origin}/v1/vaults`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ vaultPublicKey: secrets.publicKey, deviceName, deviceKind: "web", deviceId: crypto.randomUUID().toUpperCase() }),
    });
    if (res.status === 403) throw new Error("This relay isn't accepting new vaults.");
    if (!res.ok) throw new Error(`The relay said ${res.status}: ${await res.text()}`);
    const created = await res.json();
    const payload = { v: 1, vaultId: created.vaultId, keys: secrets.exported, encrypted: true, relayURL: origin, relayVaultId: created.vaultId };
    const vault = await Vault.finishJoin(storage, payload, origin, created.vaultId, created, await importVaultKeys(secrets.exported), deviceName, options);
    return { vault, recoveryCode: encodePayload(payload) };
  }

  /** Adds this browser to a vault using only the recovery code (proves it holds the private key). */
  static async recover(storage, recoveryCode, { origin, deviceName = "Web browser", ...options } = {}) {
    const payload = parsePayload(recoveryCode);
    if (!payload.keys.privateKey) throw new Error("That code has no private key, so it can't recover a vault.");
    const relayVaultId = payload.relayVaultId ?? payload.vaultId;
    const base = origin ?? payload.relayURL;
    const doFetch = options.fetch ?? ((...a) => fetch(...a));
    const challengeRes = await doFetch(`${base}/v1/vaults/${relayVaultId}/recovery`, { method: "POST" });
    if (challengeRes.status === 404) throw new Error("This relay doesn't have that vault.");
    if (!challengeRes.ok) throw new Error(`The relay said ${challengeRes.status}: ${await challengeRes.text()}`);
    const challenge = await challengeRes.json();
    const inbox = await importInboxKey(payload.keys.privateKey);
    let answer;
    try { answer = await unseal(b64uDecode(challenge.box), inbox.privateKey, b64uDecode(inbox.publicKey)); } catch { throw new Error("That recovery code is for a different vault."); }
    const res = await doFetch(`${base}/v1/vaults/${relayVaultId}/devices`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ recoveryChallenge: challenge.challengeId, recoveryAnswer: b64uEncode(answer), deviceName, deviceKind: "web", deviceId: crypto.randomUUID().toUpperCase() }),
    });
    if (!res.ok) throw new Error("The relay didn't accept the recovery code.");
    return Vault.finishJoin(storage, payload, base, relayVaultId, await res.json(), await importVaultKeys(payload.keys), deviceName, options);
  }

  /** A single-use setup code for another device. Needs the recovery code, since keys here are locked. */
  async setupCodeForNewDevice(recoveryCode) {
    const payload = parsePayload(recoveryCode);
    const { publicKey } = await importInboxKey(payload.keys.privateKey ?? "");
    if (publicKey !== this.config.vaultPublicKey) throw new Error("That recovery code is for a different vault.");
    const { pairingCode } = await this.api("POST", "pairings", { expect: [201] });
    return encodePayload({ ...payload, relayURL: this.config.base, relayVaultId: this.config.vaultId, pairingCode, inboxToken: this.config.inboxToken });
  }

  /** The browser extension's setup code: public key + inbox token only, so it can add but not read. */
  browserExtensionCode() {
    if (!this.config.inboxToken || !this.config.vaultPublicKey) return null;
    return encodePayload({ v: 1, relayURL: this.config.base, vaultId: this.config.vaultId, inboxToken: this.config.inboxToken, vaultPublicKey: this.config.vaultPublicKey });
  }

  get canReadInbox() { return Boolean(this.keys.inbox); }

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

  /**
   * Local edits: the journal of unsent ops is written straight away (it's small, and it's what must
   * survive a reload); the full op cache follows a moment later. Sync uploads them.
   */
  edited() {
    this.changed();
    const journal = { state: { ...this.journal.state }, pending: [...this.journal.pending] };
    this.writes = (this.writes ?? Promise.resolve()).then(() => this.storage.set("journal", journal)).catch(() => {});
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.save().catch(() => {}), 1000);
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

  addNote({ title = "", body = "", source = "web", tags: extra = [] } = {}) {
    const id = crypto.randomUUID().toLowerCase();
    const fields = { ...this.baseFields("note", title), [Field.source]: source, [Field.category]: "note" };
    const tags = [...new Set([...extra.map((t) => t.toLowerCase()), ...hashtags(body)])].sort();
    if (tags.length) fields[Field.tags] = tags;
    this.set(fields, id, "item");
    if (body) this.editText(Field.body, body, id, "item");
    return id;
  }

  /** Adds a link (the apps fetch its title and preview when they next enrich). */
  addLink(url, { title = "", note = "", source = "web" } = {}) {
    const cleaned = cleanURL(url);
    const key = dedupeKey(cleaned.toString());
    const existing = this.items().find((i) => i.url && dedupeKey(i.url.toString()) === key);
    if (existing) return { id: existing.id, isNew: false };
    const id = crypto.randomUUID().toLowerCase();
    this.set({ ...this.baseFields("link", title), [Field.source]: source, [Field.url]: cleaned.toString() }, id, "item");
    if (note) this.editText(Field.body, note, id, "item");
    return { id, isNew: true };
  }

  /** Adds imported items (importer.js), skipping ones already imported (like Library.importItems). */
  importItems(imported) {
    const existing = new Set(this.items().map((i) => i.record.fields.origin?.externalId).filter(Boolean));
    let added = 0;
    for (const entry of imported) {
      if (entry.externalId && existing.has(entry.externalId)) continue;
      const id = crypto.randomUUID().toLowerCase();
      const fields = { ...this.baseFields(entry.kind, entry.title), [Field.source]: entry.source };
      if (entry.createdAt) fields[Field.createdAt] = entry.createdAt;
      if (entry.url) fields[Field.url] = entry.url;
      if (entry.tags.length) fields[Field.tags] = entry.tags;
      if (entry.author) fields.author = entry.author;
      if (entry.kind === "highlight") fields[Field.category] = "quote";
      if (entry.externalId) { fields.origin = { externalId: entry.externalId }; existing.add(entry.externalId); }
      if (entry.collection) fields[Field.collections] = [this.createCollection(entry.collection)];
      this.set(fields, id, "item");
      if (entry.body) this.editText(Field.body, entry.body, id, "item");
      added++;
    }
    return added;
  }

  /** The collection with this name, made if needed (Library.createCollection). */
  createCollection(name, { symbol = "folder", color = "blue" } = {}) {
    const existing = this.collections().find((c) => c.name.localeCompare(name, undefined, { sensitivity: "accent" }) === 0);
    if (existing) return existing.id;
    const id = crypto.randomUUID().toLowerCase();
    this.set({ name, symbol, color, [Field.createdAt]: this.now() }, id, "collection");
    return id;
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

  // ---------- clipboard history (PROTOCOL.md §8) ----------

  clips() {
    return this.store.visible.filter((r) => r.kind === "clip").map(clipView).sort((a, b) => b.sortDate - a.sortDate);
  }

  clip(id) {
    const r = this.store.records.get(id);
    return r && r.kind === "clip" && r.fields._deleted !== true ? clipView(r) : null;
  }

  /** Adds copied text, or moves the same text's clip back to the top. Callers skip sensitive text. */
  addClip(text, { sourceApp = null } = {}) {
    if (!text.trim() || utf8.encode(text).length > 256 * 1024) return null;
    return this.upsertClip(hashText(text), { [ClipField.text]: text }, sourceApp);
  }

  async addImageClip(bytes, mime = "image/png") {
    if (!bytes.length || bytes.length > 20 * 1024 * 1024) return null;
    const hash = hashImageHex(hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))));
    const existing = this.clips().find((c) => c.hash === hash);
    if (existing) { this.markClipUsed(existing.id); return existing.id; }
    const ext = mime === "image/jpeg" ? "jpg" : mime.split("/")[1] ?? "png";
    const attachment = await this.storeBlob(bytes, `Image.${ext}`, mime);
    return this.upsertClip(hash, { [ClipField.image]: attachment }, null);
  }

  upsertClip(hash, fields, sourceApp) {
    const at = this.now();
    const existing = this.clips().find((c) => c.hash === hash);
    if (existing) {
      this.set({ [ClipField.lastUsedAt]: at, ...(sourceApp ? { [ClipField.sourceApp]: sourceApp } : {}) }, existing.id, "clip");
      return existing.id;
    }
    const id = crypto.randomUUID().toLowerCase();
    const all = { ...fields, [ClipField.hash]: hash, [ClipField.createdAt]: at, [ClipField.lastUsedAt]: at, [ClipField.device]: this.journal.device,
      [ClipField.sourceDevice]: this.config.deviceName ?? "Web browser" };
    if (sourceApp) all[ClipField.sourceApp] = sourceApp;
    this.set(all, id, "clip");
    return id;
  }

  markClipUsed(id) { this.set({ [ClipField.lastUsedAt]: this.now() }, id, "clip"); }
  setClipPinned(id, pinned) { this.set({ [ClipField.pinned]: pinned }, id, "clip"); }
  deleteClip(id) { this.set({ _deleted: true }, id, "clip"); }

  /** Turns a clip into a library item (link, note or file) and links the two. */
  async saveClipToLibrary(id) {
    const clip = this.clip(id);
    if (!clip) return null;
    if (clip.savedItem && this.item(clip.savedItem)) return clip.savedItem;
    let itemId;
    if (clip.image) itemId = await this.addFile(await this.attachment(clip.image.id), clip.image.name, clip.image.mime);
    else if (clip.kind === "link") itemId = this.addLink(clip.text.trim()).id;
    else itemId = this.addNote({ body: clip.text });
    this.set({ [ClipField.savedItem]: itemId }, id, "clip");
    return itemId;
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
    // Sealed inbox (browser extension, email, GoodNotes): import, then ack once uploaded.
    const imported = await this.importInbox(report);
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
    if (!this.journal.pending.length) {
      for (const id of imported) {
        try { await this.api("DELETE", `inbox/${id}`, { expect: [204] }); } catch (e) { report.errors.push(`ack ${id}: ${e.message}`); }
      }
    }
    report.imported = imported.length;
    if (report.pulled || imported.length) this.changed();
    return report;
  }

  async importInbox(report) {
    if (!this.keys.inbox || !this.config.vaultPublicKey) return [];
    const done = [];
    let entries;
    try { entries = (await this.api("GET", "inbox")).entries; } catch (e) { report.errors.push(`inbox: ${e.message}`); return done; }
    const vaultPublic = b64uDecode(this.config.vaultPublicKey);
    for (const entry of entries) {
      try {
        const box = await this.api("GET", `inbox/${entry.id}`, { raw: true });
        const { header, body } = parseEnvelope(await unseal(box, this.keys.inbox, vaultPublic));
        await this.importEnvelope(header, body, entry);
        done.push(entry.id);
      } catch (e) {
        report.errors.push(`inbox ${entry.id}: ${e.message}`);
      }
    }
    return done;
  }

  /** Turns an inbox envelope into an item, like Library.importInbox in Swift. */
  async importEnvelope(h, body, entry = {}) {
    const text = () => fromUtf8.decode(body);
    if (h.source === "webdav") {
      const path = h.meta?.davPath ?? entry.davPath ?? h.name ?? "notebook.pdf";
      const attachment = await this.storeBlob(body, h.name ?? "notebook.pdf", h.mime ?? "application/pdf");
      const existing = this.items().find((i) => i.record.fields.origin?.davPath === path);
      if (existing) {
        this.update(existing.id, { attachments: [attachment], needsEnrichment: true, ocrText: null, enrichment: null });
        return existing.id;
      }
      const id = crypto.randomUUID().toLowerCase();
      this.set({ ...this.baseFields("pdf", titleFromFileName(h.name ?? "Notebook")), source: "goodnotes", attachments: [attachment], origin: { davPath: path } }, id, "item");
      return id;
    }
    if (h.source === "email") {
      if (h.mime === "text/html" || h.mime === "text/plain") {
        const id = crypto.randomUUID().toLowerCase();
        const origin = {};
        if (h.groupId) origin.emailGroup = h.groupId;
        if (h.meta?.from) origin.from = h.meta.from;
        this.set({ ...this.baseFields("email", h.title ?? "Email"), source: "email", origin }, id, "item");
        this.editText(Field.body, h.mime === "text/html" ? htmlToText(text()) : text(), id, "item");
        return id;
      }
      const attachment = await this.storeBlob(body, h.name ?? "attachment", h.mime ?? "application/octet-stream");
      const parent = h.groupId && this.items().find((i) => i.record.fields.origin?.emailGroup === h.groupId);
      if (parent) {
        this.update(parent.id, { attachments: [...parent.attachments, attachment] });
        return parent.id;
      }
      return this.addFile(body, attachment.name, attachment.mime, { source: "email" });
    }
    const source = h.source === "web" ? "web" : "share";
    if (h.url) {
      const note = h.mime?.startsWith("text/") ? text() : "";
      const { id, isNew } = this.addLink(h.url, { title: h.title ?? "", note, source });
      const item = this.item(id);
      if (!isNew && note && item) this.setBody(id, item.body ? `${item.body}\n\n${note}` : note);
      return id;
    }
    if (h.mime && !h.mime.startsWith("text/")) return this.addFile(body, h.name ?? "file", h.mime, { source, title: h.title });
    return this.addNote({ title: h.title ?? "", body: text(), source });
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

  /** Encrypts and uploads attachment bytes; returns the attachment JSON for an item. */
  async storeBlob(bytes, name, mime) {
    const id = hex(new Uint8Array(await crypto.subtle.sign("HMAC", this.keys.blobId, bytes)));
    const stored = this.config.encrypted ? await encrypt(bytes, this.keys.blob) : bytes;
    await this.api("PUT", `blobs/${id}`, { body: stored, expect: [200, 201, 204] });
    return { id, name, mime, size: bytes.length };
  }

  /** Uploads a file as an encrypted blob and adds an item for it (like Library.addFile). */
  async addFile(bytes, name, mime, { source = "web", title } = {}) {
    const attachment = await this.storeBlob(bytes, name, mime);
    const kind = mime.startsWith("image/") ? "image" : mime === "application/pdf" ? "pdf" : mime.startsWith("audio/") ? "audio" : mime.startsWith("video/") ? "video" : "file";
    const itemId = crypto.randomUUID().toLowerCase();
    this.set({ ...this.baseFields(kind, title ?? titleFromFileName(name)), [Field.source]: source, [Field.attachments]: [attachment] }, itemId, "item");
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


function titleFromFileName(name) {
  return name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").trim();
}

/** Readable text from an HTML email. */
export function htmlToText(html) {
  if (typeof DOMParser !== "undefined") {
    const doc = new DOMParser().parseFromString(html, "text/html");
    doc.querySelectorAll("script, style, head").forEach((n) => n.remove());
    doc.querySelectorAll("br").forEach((n) => n.replaceWith("\n"));
    doc.querySelectorAll("p, div, li, tr, h1, h2, h3, h4").forEach((n) => n.append("\n"));
    return (doc.body?.textContent ?? "").replace(/[ \t\u00a0]+/g, " ").replace(/\n\s*\n\s*\n+/g, "\n\n").trim();
  }
  return html.replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|tr|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/[ \t]+/g, " ").replace(/\n\s*\n\s*\n+/g, "\n\n").trim();
}
