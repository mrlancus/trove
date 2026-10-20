// The web app's vault: joins the relay as a "web" device, keeps a local copy of every op, pulls and
// pushes encrypted journal segments (docs/PROTOCOL.md §3–4) and edits records the same way the apps do.
import { b64uDecode, b64uEncode, fromUtf8, hex, utf8 } from "./bytes.js";
import { decodeSegment, encodeSegment, isStrayItem, Journal, RecordStore } from "./records.js";
import { cleanURL, dedupeKey, Field, hashtags, itemView } from "./items.js";
import { generateVaultSecrets, importInboxKey, importVaultKeys } from "./keys.js";
import { CLIP_KEEP_STANDARD, ClipField, cleanTagName, cleanTags, clipView, customTagList, hashImageHex, hashText, insightFields, insights, isSensitive as isSensitiveText, ruleTags, TAG_COLORS, TAG_SETTINGS_ID } from "./clips.js";
import { decrypt, encrypt, isTRV1, parseEnvelope, unseal } from "./trv1.js";
import { cleanName, folderId, folderPath, folderPathOf } from "./organize.js";
import { clipEventView } from "./clipmap.js";
import { unwrap as unwrapPaste } from "./pasteimport.js";
import { parseHLC } from "./records.js";
import { elementView, encodePoints, erase, InkField, moveBy, pageListOf, strokeView, transformPoint, transformRect, validSize, widthScale } from "./ink.js";

const MAX_FILE_VERSIONS = 50;
const CLIP_SETTINGS_ID = "settings.clipboard";
/** Pages as the `pageList` field (InkPage.json: no null paper or colour). */
const pageJSON = (pages) => pages.map((p) => ({ id: p.id, ...(p.paper ? { paper: p.paper } : {}), ...(p.color ? { color: p.color } : {}), ...(p.size ? { size: p.size } : {}) }));
const newId = () => crypto.randomUUID().toLowerCase();
/** The item id for a relay inbox entry, the same on every device (Library.inboxItemId). */
export const inboxItemId = (entryId) => `inbox-${String(entryId).toLowerCase()}`;

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
    return this.store.visible.filter((r) => r.kind === "item" && !isStrayItem(r)).map(itemView).sort((a, b) => b.createdAt - a.createdAt);
  }

  item(id) {
    const r = this.store.records.get(id);
    return r && r.kind === "item" && r.fields._deleted !== true && !isStrayItem(r) ? itemView(r) : null;
  }

  // ---------- folders (PROTOCOL.md §9, Library+Folders.swift) ----------

  folders() {
    return this.store.visible.filter((r) => r.kind === "folder")
      .map((r) => ({ id: r.id, name: typeof r.fields.name === "string" ? r.fields.name : "Untitled", parent: typeof r.fields.parent === "string" ? r.fields.parent : null,
        isAuto: r.fields.auto === true, color: r.fields.color ?? null }));
  }

  /** The fields that file a new item where the organiser says (making folders as needed). */
  filing(where) {
    const id = this.ensureFolder(folderPath(where));
    return id ? { [Field.folder]: id, [Field.folderAuto]: true } : {};
  }

  /** The folder at this path, made if missing; existing folders match by name under the same parent. */
  ensureFolder(path, auto = true) {
    let parent = null;
    for (const raw of path) {
      const name = cleanName(raw);
      if (!name) continue;
      const existing = this.folders().find((f) => f.parent === parent && f.name.localeCompare(name, undefined, { sensitivity: "accent" }) === 0);
      if (existing) { parent = existing.id; continue; }
      parent = this.makeFolder(name, parent, auto);
    }
    return parent;
  }

  makeFolder(name, parent, auto) {
    let id = folderId(parent, name);
    const taken = this.store.records.get(id);
    if (taken && taken.fields._deleted !== true) id += `~${newId().slice(0, 6)}`;
    this.set({ name, parent, auto, [Field.createdAt]: this.now(), _deleted: false }, id, "folder");
    return id;
  }

  createFolder(name, parent = null) {
    const clean = cleanName(name) || "Untitled";
    const existing = this.folders().find((f) => f.parent === parent && f.name.localeCompare(clean, undefined, { sensitivity: "accent" }) === 0);
    return existing ? existing.id : this.makeFolder(clean, parent, false);
  }

  renameFolder(id, name) {
    const clean = cleanName(name);
    if (clean) this.set({ name: clean, auto: false }, id, "folder");
  }

  /** Moves a folder inside another (null = top level); never into itself. */
  moveFolder(id, parent) {
    if (parent && folderPathOf(parent, this.folders()).some((f) => f.id === id)) return false;
    this.set({ parent }, id, "folder");
    return true;
  }

  /** Deletes a folder; what was inside moves up to its parent. */
  deleteFolder(id) {
    const folder = this.folders().find((f) => f.id === id);
    if (!folder) return;
    for (const child of this.folders()) if (child.parent === id) this.set({ parent: folder.parent }, child.id, "folder");
    for (const item of this.items()) if (item.folder === id) this.update(item.id, { [Field.folder]: folder.parent });
    this.set({ _deleted: true }, id, "folder");
  }

  /** Moves an item by hand (null = no folder); the organiser leaves it alone after that. */
  moveItem(itemId, folder) { this.update(itemId, { [Field.folder]: folder, [Field.folderAuto]: false }); }

  /** Files every item without a (live) folder. Returns how many it filed. */
  tidyUp() {
    const live = new Set(this.folders().map((f) => f.id));
    let moved = 0;
    for (const item of this.items()) {
      if (item.folder && live.has(item.folder)) continue;
      const fields = this.filing({ kind: item.kind, category: item.record.fields.category ?? null, source: item.source, fileName: item.attachments[0]?.name });
      if (Object.keys(fields).length) { this.update(item.id, fields); moved++; }
    }
    return moved;
  }

  // ---------- versions ----------

  versionsAdding(old, item) {
    const entry = { attachment: old, at: this.now(), by: this.journal.device };
    return [entry, ...item.fileVersions.filter((v) => v.attachment.id !== old.id)].slice(0, MAX_FILE_VERSIONS);
  }

  /** Saves an edited file as current; the previous file becomes a version. */
  async replaceFile(itemId, bytes, { name, mime } = {}) {
    const item = this.item(itemId), current = item?.attachments[0];
    if (!current) return;
    const next = await this.storeBlob(bytes, name ?? current.name, mime ?? current.mime);
    if (next.id === current.id) return;
    this.update(itemId, { [Field.attachments]: [next, ...item.attachments.slice(1)], [Field.fileVersions]: this.versionsAdding(current, item), [Field.thumbnail]: null });
  }

  /** Makes an earlier file current again; the current one is kept as a version. */
  restoreFileVersion(itemId, version) {
    const item = this.item(itemId), current = item?.attachments[0];
    if (!current || current.id === version.attachment.id) return;
    const list = [{ attachment: current, at: this.now(), by: this.journal.device }, ...item.fileVersions.filter((v) => v.attachment.id !== version.attachment.id)];
    this.update(itemId, { [Field.attachments]: [version.attachment, ...item.attachments.slice(1)], [Field.fileVersions]: list.slice(0, MAX_FILE_VERSIONS), [Field.thumbnail]: null });
  }

  /** Earlier states of a text field, newest first; one per editing session (same device, < gap apart). */
  textVersions(itemId, field = Field.body, gapMs = 120_000) {
    const out = [];
    for (const op of this.store.ops) {
      if (op.r !== itemId || op.t !== "text" || op.x?.field !== field) continue;
      const at = parseHLC(op.h)?.millis ?? 0, last = out.at(-1);
      if (last && last.device === op.d && at - last.at < gapMs) out[out.length - 1] = { text: op.x.value, at, device: op.d };
      else out.push({ text: op.x.value, at, device: op.d });
    }
    return out.reverse();
  }

  /** Stores a small preview image for an item (shared with every device). */
  async setThumbnail(itemId, bytes, mime = "image/jpeg") {
    const thumb = await this.storeBlob(bytes, "thumbnail.jpg", mime);
    this.update(itemId, { [Field.thumbnail]: thumb });
    return thumb;
  }

  // ---------- connections ----------

  connect(a, b) {
    const item = this.item(a);
    if (a === b || !item || item.links.includes(b)) return;
    this.update(a, { [Field.links]: [...item.links, b] });
  }

  disconnect(a, b) {
    for (const [x, y] of [[a, b], [b, a]]) {
      const item = this.item(x);
      if (item?.links.includes(y)) this.update(x, { [Field.links]: item.links.filter((l) => l !== y) });
    }
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

  addNote({ title = "", body = "", source = "web", tags: extra = [], id = newId(), folder = [] } = {}) {
    const fields = { ...this.baseFields("note", title), [Field.source]: source, [Field.category]: "note", ...this.filing({ kind: "note", source, importPath: folder }) };
    const tags = [...new Set([...extra.map((t) => t.toLowerCase()), ...hashtags(body)])].sort();
    if (tags.length) fields[Field.tags] = tags;
    this.set(fields, id, "item");
    if (body) this.editText(Field.body, body, id, "item");
    return id;
  }

  /** Adds a link (the apps fetch its title and preview when they next enrich). */
  addLink(url, { title = "", note = "", source = "web", id: givenId } = {}) {
    const cleaned = cleanURL(url);
    const key = dedupeKey(cleaned.toString());
    const existing = this.items().find((i) => i.url && dedupeKey(i.url.toString()) === key);
    if (existing) { this.noteSource(source, existing); return { id: existing.id, isNew: false }; }
    const id = givenId ?? newId();
    this.set({ ...this.baseFields("link", title), [Field.source]: source, [Field.url]: cleaned.toString(), ...this.filing({ kind: "link", source }) }, id, "item");
    if (note) this.editText(Field.body, note, id, "item");
    return { id, isNew: true };
  }

  /** The same thing arrived again from somewhere else: list it under that source too (Library.noteSource). */
  noteSource(source, item) {
    if (item.sources.includes(source) || source === "app") return;
    this.update(item.id, { alsoFrom: [...item.sources.slice(1), source] });
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
      Object.assign(fields, this.filing({ kind: entry.kind, category: entry.kind === "highlight" ? "quote" : null, source: entry.source, collection: entry.collection }));
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

  /** Changes an item's fields; an id with no item behind it is left alone (it would show as an empty 1970 "Untitled"). */
  update(id, fields) { if (this.store.records.get(id)?.kind === "item") this.set(fields, id, "item"); }

  setBody(id, text) {
    if (this.store.records.get(id)?.kind !== "item") return;
    this.editText(Field.body, text, id, "item");
    const tags = hashtags(text), item = this.item(id);
    if (item && tags.length && !tags.every((t) => item.tags.includes(t))) {
      this.update(id, { [Field.tags]: [...new Set([...item.tags, ...tags])].sort() });
    }
  }

  setPinned(id, pinned) { this.update(id, { [Field.pinned]: pinned }); }
  markRead(id, read = true) { this.update(id, { [Field.readAt]: read ? this.now() : null }); }
  delete(id) { this.set({ _deleted: true }, id, this.store.records.get(id)?.kind); }

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

  // ---------- drawing (PROTOCOL.md §10) ----------

  /** Strokes on an item (a sketch's own pages, or `layer` = a file's attachment id), oldest first.
   * `page` is a file's page number, or a sketch page's id (string). */
  strokes(on, layer = "", page = null) {
    return this.store.visible.filter((r) => r.kind === "stroke").map(strokeView)
      .filter((s) => s.on === on && s.layer === layer && (page === null || (typeof page === "string" ? s.pageKey === page : s.page === page)))
      .sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
  }

  /** Which items have ink, and on which layers: Map(itemId → Set(layer)). */
  inkedLayers() {
    const out = new Map();
    for (const r of this.store.visible) if (r.kind === "stroke") { const s = strokeView(r); if (!out.has(s.on)) out.set(s.on, new Set()); out.get(s.on).add(s.layer); }
    return out;
  }

  /** A later time than anything drawn on the item, so new ink draws on top (Library.nextInkTime). */
  nextInkTime(on) {
    const latest = Math.max(0, ...this.store.visible.filter((r) => (r.kind === "stroke" || r.kind === "element") && r.fields.on === on)
      .map((r) => r.fields.createdAt).filter((t) => typeof t === "number"));
    return Math.max(this.now(), latest + 1);
  }

  /** `page`: a file's page number or a sketch page's id. `createdAt` keeps an erased stroke's pieces in its place. */
  addStroke({ on, layer = "", page, tool, color, width, points, shape = null, createdAt = null }) {
    if (!points.length) return null;
    const id = newId();
    const fields = { [InkField.on]: on, [InkField.layer]: layer, [InkField.page]: page, [InkField.tool]: tool, [InkField.color]: color, [InkField.width]: width,
      [InkField.points]: encodePoints(points), [InkField.createdAt]: createdAt ?? this.nextInkTime(on), [InkField.device]: this.journal.device };
    if (shape) fields[InkField.shape] = shape;
    this.set(fields, id, "stroke");
    return id;
  }

  deleteStrokes(ids) { for (const id of ids) this.set({ _deleted: true }, id, "stroke"); }

  /** Moves, resizes (`t` = {sx, sy, ox, oy, dx, dy}) or recolours strokes: the lasso (Library.transformStrokes). */
  transformStrokes(ids, { t = null, color = null } = {}) {
    for (const id of ids) {
      const r = this.store.records.get(id);
      if (!r || r.kind !== "stroke" || r.fields._deleted === true) continue;
      const s = strokeView(r), fields = {};
      if (t) {
        fields[InkField.points] = encodePoints(s.points.map((p) => transformPoint(t, p)));
        if (widthScale(t) !== 1) fields[InkField.width] = s.width * widthScale(t);
      }
      if (color) fields[InkField.color] = color;
      if (Object.keys(fields).length) this.set(fields, id, "stroke");
    }
  }

  /** The partial eraser: crossed strokes become what's left of them, in the same place (Library.eraseStrokes). */
  eraseStrokes({ on, layer = "", page, path, radius, only = null }) {
    const added = [];
    for (const s of this.strokes(on, layer, page)) {
      if (only && !only.includes(s.tool)) continue;
      const pieces = erase(s.points, path, radius + s.width / 2);
      if (!pieces) continue;
      this.deleteStrokes([s.id]);
      for (const piece of pieces) added.push(this.addStroke({ on, layer, page, tool: s.tool, color: s.color, width: s.width, points: piece, createdAt: s.createdAt }));
    }
    return added;
  }

  /** Copies of strokes and elements (duplicate, paste), moved by `t`. */
  duplicateInk({ strokes = [], elements = [], on, layer = "", page, t = moveBy(20, 20) }) {
    const out = [];
    for (const id of strokes) {
      const r = this.store.records.get(id);
      if (!r || r.kind !== "stroke" || r.fields._deleted === true) continue;
      const s = strokeView(r);
      out.push(this.addStroke({ on, layer, page, tool: s.tool, color: s.color, width: s.width * widthScale(t), points: s.points.map((p) => transformPoint(t, p)), shape: s.shape }));
    }
    for (const id of elements) {
      const e = this.element(id);
      if (!e) continue;
      out.push(this.addElement({ on, layer, page, type: e.type, frame: transformRect(t, e), text: e.text, size: e.size * widthScale(t), color: e.color, image: e.image }));
    }
    return out;
  }

  // Text boxes and pictures (`element` records).

  element(id) {
    const r = this.store.records.get(id);
    return r && r.kind === "element" && r.fields._deleted !== true ? elementView(r) : null;
  }

  elements(on, layer = "", page = null) {
    return this.store.visible.filter((r) => r.kind === "element").map(elementView)
      .filter((e) => e.on === on && e.layer === layer && (page === null || e.pageKey === String(page)))
      .sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
  }

  addElement({ on, layer = "", page, type, frame, text = "", size = 20, color = "#000000", image = null }) {
    const id = newId();
    const fields = { on, layer, page, type, x: frame.x, y: frame.y, w: frame.w, h: frame.h, createdAt: this.nextInkTime(on), device: this.journal.device };
    if (type === "text") Object.assign(fields, { text, size, color });
    if (image) fields.image = image;
    this.set(fields, id, "element");
    if (type === "text") this.refreshSketchText(on);
    return id;
  }

  /** Picture bytes become an encrypted blob placed at `frame`. */
  async addPicture(bytes, mime, { on, layer = "", page, frame }) {
    const ext = mime === "image/jpeg" ? "jpg" : mime.split("/")[1] ?? "png";
    const image = await this.storeBlob(bytes, `Picture.${ext}`, mime);
    return this.addElement({ on, layer, page, type: "image", frame, image });
  }

  updateElement(id, { frame = null, text = null, size = null, color = null } = {}) {
    const e = this.element(id);
    if (!e) return;
    const fields = {};
    if (frame) Object.assign(fields, { x: frame.x, y: frame.y, w: frame.w, h: frame.h });
    if (text !== null) fields.text = text;
    if (size !== null) fields.size = size;
    if (color) fields.color = color;
    if (!Object.keys(fields).length) return;
    this.set(fields, id, "element");
    if (text !== null) this.refreshSketchText(e.on);
  }

  transformElements(ids, t) {
    for (const id of ids) {
      const e = this.element(id);
      if (e) this.updateElement(id, { frame: transformRect(t, e), size: e.type === "text" && widthScale(t) !== 1 ? e.size * widthScale(t) : null });
    }
  }

  deleteElements(ids) {
    const items = new Set();
    for (const id of ids) { const e = this.element(id); if (e) items.add(e.on); this.set({ _deleted: true }, id, "element"); }
    for (const on of items) this.refreshSketchText(on);
  }

  /** The item's `sketchText`: every text box's words, for search. */
  refreshSketchText(on) {
    const text = this.store.visible.filter((r) => r.kind === "element").map(elementView).filter((e) => e.on === on && e.type === "text")
      .sort((a, b) => a.createdAt - b.createdAt).map((e) => e.text).filter(Boolean).join("\n");
    if ((this.item(on)?.sketchText ?? "") !== text) this.update(on, { sketchText: text });
  }

  /** A new, empty sketch (Library.addSketch). */
  addSketch({ title = "", paper = "blank", folder = [], infinite = false } = {}) {
    const id = newId();
    this.set({ ...this.baseFields("sketch", title), paper, pages: 1, ...(infinite ? { canvas: "infinite" } : {}),
      ...this.filing({ kind: "sketch", source: "web", importPath: folder }) }, id, "item");
    return id;
  }

  setSketch(id, { paper, pages } = {}) {
    const fields = {};
    if (paper) fields.paper = paper;
    if (pages) {
      const item = this.item(id);
      if (item && Array.isArray(item.record.fields.pageList)) {
        const list = pageListOf(item.record.fields);
        while (list.length < Math.max(1, pages)) list.push({ id: newId().slice(0, 8), paper: list.at(-1)?.paper ?? null, color: list.at(-1)?.color ?? null });
        fields.pageList = pageJSON(list.slice(0, Math.max(1, pages)));
      }
      fields.pages = Math.max(1, pages);
    }
    if (Object.keys(fields).length) this.update(id, fields);
  }

  // Pages (Library+InkPages: addPage, duplicatePage, movePage, deletePage, setPage).

  setPages(id, pages) { this.update(id, { pageList: pageJSON(pages), pages: pages.length }); }

  addPage(sketch, after = null) {
    const item = this.item(sketch);
    if (!item) return null;
    const pages = [...item.pageList];
    const at = after !== null && pages.some((p) => p.id === after) ? pages.findIndex((p) => p.id === after) + 1 : pages.length;
    const like = pages[Math.max(0, Math.min(pages.length - 1, at - 1))];
    const page = { id: newId().slice(0, 8), paper: like.paper, color: like.color, size: like.size ?? null };
    pages.splice(at, 0, page);
    this.setPages(sketch, pages);
    return page.id;
  }

  duplicatePage(sketch, page) {
    const item = this.item(sketch);
    const at = item?.pageList.findIndex((p) => p.id === page) ?? -1;
    if (at < 0) return null;
    const pages = [...item.pageList];
    const copy = { ...pages[at], id: newId().slice(0, 8) };
    pages.splice(at + 1, 0, copy);
    this.setPages(sketch, pages);
    this.duplicateInk({ strokes: this.strokes(sketch, "", page).map((s) => s.id), elements: this.elements(sketch, "", page).map((e) => e.id),
      on: sketch, page: copy.id, t: moveBy(0, 0) });
    return copy.id;
  }

  movePage(sketch, page, index) {
    const item = this.item(sketch);
    const from = item?.pageList.findIndex((p) => p.id === page) ?? -1;
    if (from < 0) return;
    const pages = [...item.pageList];
    const [moved] = pages.splice(from, 1);
    pages.splice(Math.max(0, Math.min(pages.length, index)), 0, moved);
    this.setPages(sketch, pages);
  }

  deletePage(sketch, page) {
    const item = this.item(sketch);
    if (!item || item.pageList.length <= 1) return;
    this.setPages(sketch, item.pageList.filter((p) => p.id !== page));
    this.deleteStrokes(this.strokes(sketch, "", page).map((s) => s.id));
    this.deleteElements(this.elements(sketch, "", page).map((e) => e.id));
  }

  /** One page's paper, colour ("" = white) or size ([w, h]). */
  setPage(sketch, page, { paper = null, color = null, size = null } = {}) {
    const item = this.item(sketch);
    if (!item) return;
    this.setPages(sketch, item.pageList.map((p) => (p.id !== page ? p
      : { ...p, ...(paper ? { paper } : {}), ...(color !== null ? { color: color || null } : {}), ...(validSize(size) ? { size: validSize(size) } : {}) })));
  }

  /** Every page's paper, colour or size at once (the sketch's own `paper` and `pageSize` too). */
  setAllPages(sketch, { paper = null, color = null, size = null } = {}) {
    const item = this.item(sketch);
    if (!item) return;
    const fields = { pageList: pageJSON(item.pageList.map((p) => ({ ...p, ...(paper ? { paper } : {}), ...(color !== null ? { color: color || null } : {}),
      ...(validSize(size) ? { size: validSize(size) } : {}) }))), pages: item.pageList.length };
    if (paper) fields.paper = paper;
    if (validSize(size)) fields.pageSize = validSize(size);
    this.update(sketch, fields);
  }

  setSketchCanvas(sketch, infinite) { this.update(sketch, { canvas: infinite ? "infinite" : "pages" }); }

  // ---------- clipboard history (PROTOCOL.md §8) ----------

  clips() {
    return this.store.visible.filter((r) => r.kind === "clip").map(clipView).sort((a, b) => b.sortDate - a.sortDate);
  }

  clip(id) {
    const r = this.store.records.get(id);
    return r && r.kind === "clip" && r.fields._deleted !== true ? clipView(r) : null;
  }

  /** Adds copied text, or moves the same text's clip back to the top. Callers skip sensitive text. */
  addClip(text, { sourceApp = null, sourceURL = null, sourceTitle = null } = {}) {
    if (!text.trim() || utf8.encode(text).length > 256 * 1024) return null;
    const tags = ruleTags(text);
    return this.upsertClip(hashText(text), { [ClipField.text]: text, ...insightFields(insights(text)), ...(tags.length ? { [ClipField.tags]: tags } : {}) },
      sourceApp, { sourceURL, sourceTitle });
  }

  async addImageClip(bytes, mime = "image/png") {
    if (!bytes.length || bytes.length > 20 * 1024 * 1024) return null;
    const hash = hashImageHex(hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))));
    const existing = this.clips().find((c) => c.hash === hash);
    if (existing) { this.markClipUsed(existing.id); return existing.id; }
    const ext = mime === "image/jpeg" ? "jpg" : mime.split("/")[1] ?? "png";
    const attachment = await this.storeBlob(bytes, `Image.${ext}`, mime);
    return this.upsertClip(hash, { [ClipField.image]: attachment, [ClipField.autoTitle]: "Image" }, null);
  }

  upsertClip(hash, fields, sourceApp, { sourceURL = null, sourceTitle = null } = {}) {
    const at = this.now();
    const source = {};
    if (sourceURL) source[ClipField.sourceURL] = sourceURL;
    if (sourceTitle) source[ClipField.sourceTitle] = sourceTitle;
    const existing = this.clips().find((c) => c.hash === hash);
    if (existing) {
      this.set({ [ClipField.lastUsedAt]: at, [ClipField.uses]: existing.uses + 1, ...(sourceApp ? { [ClipField.sourceApp]: sourceApp } : {}), ...source },
        existing.id, "clip");
      return existing.id;
    }
    const id = crypto.randomUUID().toLowerCase();
    const all = { ...fields, [ClipField.hash]: hash, [ClipField.createdAt]: at, [ClipField.lastUsedAt]: at, [ClipField.device]: this.journal.device,
      [ClipField.sourceDevice]: this.config.deviceName ?? "Web browser", [ClipField.needsEnrichment]: true, ...source };
    if (sourceApp) all[ClipField.sourceApp] = sourceApp;
    this.set(all, id, "clip");
    return id;
  }

  markClipUsed(id) { this.set({ [ClipField.lastUsedAt]: this.now(), [ClipField.uses]: (this.clip(id)?.uses ?? 0) + 1 }, id, "clip"); }

  /** Your own name for a clip ("" goes back to the automatic one). */
  renameClip(id, title) { this.set({ [ClipField.title]: title.trim() }, id, "clip"); }

  /** Changes a text clip's text; insights are worked out again and AI looks at it again (Library.editClip). */
  editClip(id, text) {
    const clip = this.clip(id);
    if (!clip || clip.image || clip.text === text || !text) return;
    this.set({ [ClipField.text]: text, [ClipField.hash]: hashText(text), [ClipField.editedAt]: this.now(), [ClipField.needsEnrichment]: true,
      [ClipField.aiTitle]: null, [ClipField.summary]: null, ...insightFields(insights(text)), [ClipField.tags]: cleanTags([...clip.tags, ...ruleTags(text)]) },
    id, "clip");
  }

  /** Kinds of copy saved into the library as soon as they're copied (synced; Library.clipAutoSaveKinds). */
  clipAutoSaveKinds() {
    const r = this.store.records.get(CLIP_SETTINGS_ID);
    return r && r.fields._deleted !== true && Array.isArray(r.fields.autoSave) ? r.fields.autoSave.filter((k) => typeof k === "string") : [];
  }

  setClipAutoSave(kinds) { this.set({ autoSave: [...new Set(kinds)].sort() }, CLIP_SETTINGS_ID, "setting"); }

  /** How much history to keep, synced: {days, count}, 0 = no limit (Library.clipKeep). */
  clipKeep() {
    const f = this.store.records.get(CLIP_SETTINGS_ID)?.fields ?? {};
    const n = (v, fallback) => (typeof v === "number" && v >= 0 ? Math.floor(v) : fallback);
    return f._deleted === true ? { ...CLIP_KEEP_STANDARD } : { days: n(f.keepDays, CLIP_KEEP_STANDARD.days), count: n(f.keepCount, CLIP_KEEP_STANDARD.count) };
  }

  /** Changes how much history is kept, then prunes to it. */
  setClipKeep({ days, count }) {
    this.set({ keepDays: Math.max(0, days), keepCount: Math.max(0, count) }, CLIP_SETTINGS_ID, "setting");
    return this.pruneClips();
  }

  /** Deletes unpinned clips older than the setting allows, and the oldest past its count (Library.pruneClips). */
  pruneClips() {
    const { days, count } = this.clipKeep();
    const cutoff = days > 0 ? this.now() - days * 86_400_000 : -Infinity;
    let removed = 0;
    this.clips().forEach((clip, index) => {
      if (!clip.isPinned && (clip.sortDate < cutoff || (count > 0 && index >= count))) { this.deleteClip(clip.id); removed++; }
    });
    return removed;
  }

  /** Saves a new clip into the library if its kind is set to save automatically. */
  async autoSaveClip(id) {
    const clip = id && this.clip(id);
    if (clip && !clip.savedItem && this.clipAutoSaveKinds().includes(clip.kind)) await this.saveClipToLibrary(id);
  }

  setClipTags(id, tags) { this.set({ [ClipField.tags]: cleanTags(tags) }, id, "clip"); }

  /** Adds or removes one tag on a clip. */
  toggleClipTag(id, tag) {
    const clip = this.clip(id), name = cleanTagName(tag);
    if (!clip || !name) return;
    this.setClipTags(id, clip.tags.includes(name) ? clip.tags.filter((t) => t !== name) : [...clip.tags, name]);
  }

  /** Your own tags, each with a colour (Library.customTags). */
  customTags() {
    const r = this.store.records.get(TAG_SETTINGS_ID);
    return r && r.fields._deleted !== true ? customTagList(r.fields) : [];
  }

  /** Makes a tag or changes its colour; returns the stored name (null if it was empty). */
  setTagColor(name, color) {
    const tag = cleanTagName(name);
    if (!tag || tag.startsWith("_")) return null;
    this.set({ [tag]: TAG_COLORS.includes(color) ? color : "gray" }, TAG_SETTINGS_ID, "setting");
    return tag;
  }

  /** Removes a tag: its colour, and the tag from every clip and item that has it. */
  deleteTag(name) {
    const tag = cleanTagName(name);
    if (!tag || tag.startsWith("_")) return;
    this.set({ [tag]: null }, TAG_SETTINGS_ID, "setting");
    for (const clip of this.clips()) if (clip.tags.includes(tag)) this.setClipTags(clip.id, clip.tags.filter((t) => t !== tag));
    for (const item of this.items()) if (item.tags.some((t) => t.toLowerCase() === tag)) this.update(item.id, { [Field.tags]: item.tags.filter((t) => t.toLowerCase() !== tag) });
  }
  setClipNote(id, note) { this.set({ [ClipField.note]: note }, id, "clip"); }
  setClipPinned(id, pinned) { this.set({ [ClipField.pinned]: pinned }, id, "clip"); }
  /** Deletes a clip and where and when it was copied and pasted. */
  deleteClip(id) {
    this.set({ _deleted: true }, id, "clip");
    for (const e of this.clipEvents(id)) this.set({ _deleted: true }, e.id, "clipEvent");
  }

  /** A setting every device follows (`settings.app`, Library.sharedSettings); `standard` when unset. */
  appSetting(name, standard = true) {
    const r = this.store.records.get("settings.app");
    const v = r && r.fields._deleted !== true ? r.fields[name] : undefined;
    return typeof v === "boolean" ? v : standard;
  }

  setAppSetting(name, value) { this.set({ [name]: Boolean(value) }, "settings.app", "setting"); }

  // ---------- where and when clips were copied and pasted (PROTOCOL.md §8, core/clipmap.js) ----------

  /** Every copy and paste event, or one clip's, oldest first. */
  clipEvents(clip = null) {
    return this.store.visible.filter((r) => r.kind === "clipEvent").map((r) => ({ ...clipEventView(r), hlc: r.createdHLC }))
      .filter((e) => e.clip && (!clip || e.clip === clip)).sort((a, b) => a.at - b.at || (a.hlc < b.hlc ? -1 : a.hlc > b.hlc ? 1 : 0));
  }

  /**
   * Records a copy (`type` "copy"), a paste into somewhere ("paste") or a copy back from the
   * history ("use"): app, page, window and place (`{lat, lon, accuracy, name?, city?}`) when known.
   */
  recordClipEvent(clip, type, { app = null, bundle = null, url = null, title = null, window = null, place = null, at = this.now() } = {}) {
    if (!clip) return null;
    const id = crypto.randomUUID().toLowerCase();
    const fields = { clip, type, at, device: this.journal.device, deviceName: this.config.deviceName ?? "Web browser" };
    for (const [k, v] of Object.entries({ app, bundle, url, title, window })) if (typeof v === "string" && v) fields[k] = v;
    if (place && Number.isFinite(place.lat) && Number.isFinite(place.lon)) {
      fields.place = { lat: Math.round(place.lat * 1e5) / 1e5, lon: Math.round(place.lon * 1e5) / 1e5,
        ...(Number.isFinite(place.accuracy) ? { accuracy: Math.round(place.accuracy) } : {}), ...(place.name ? { name: place.name } : {}), ...(place.city ? { city: place.city } : {}) };
    }
    this.set(fields, id, "clipEvent");
    return id;
  }

  /**
   * Clips from another clipboard app (pasteimport.js entries): the original times, app and
   * pinboards (as tags) are kept. Ones already here (same text or image) just gain the tags.
   * Returns {added, merged}.
   */
  /**
   * Clips brought in by an older importer with Paste's JSON wrapper still on get their plain text
   * back; one that's now the same as another clip folds into it (Library.repairWrappedClips).
   */
  repairWrappedClips() {
    const all = this.clips();
    const wrapped = all.filter((c) => !c.image && c.text.startsWith("{")).map((c) => [c, unwrapPaste(c.text)]).filter(([c, w]) => w?.text && w.text !== c.text);
    if (!wrapped.length) return 0;
    const byHash = new Map(all.map((c) => [c.hash, c]));
    for (const [c, w] of wrapped) {
      const hash = hashText(w.text);
      const old = new Set(ruleTags(c.text));
      const kept = c.tags.filter((t) => !old.has(t));
      const other = byHash.get(hash);
      if (other && other.id !== c.id) {
        const tags = cleanTags([...other.tags, ...kept]);
        if (tags.join() !== other.tags.join()) this.set({ [ClipField.tags]: tags }, other.id, "clip");
        this.deleteClip(c.id);
        continue;
      }
      const fields = { [ClipField.text]: w.text, [ClipField.hash]: hash, ...insightFields(insights(w.text)), [ClipField.tags]: cleanTags([...kept, ...ruleTags(w.text)]) };
      if (w.url && w.url !== w.text && !c.sourceURL) fields[ClipField.sourceURL] = w.url;
      this.set(fields, c.id, "clip");
      byHash.set(hash, c);
    }
    return wrapped.length;
  }

  async importClips(entries, { source = "Paste", progress = null } = {}) {
    let added = 0, merged = 0;
    const byHash = new Map(this.clips().map((c) => [c.hash, c]));
    for (const e of entries) {
      let hash, fields;
      if (e.text) {
        if (!e.text.trim() || utf8.encode(e.text).length > 256 * 1024 || isSensitiveText(e.text)) continue;
        hash = hashText(e.text);
        const tags = ruleTags(e.text);
        fields = { [ClipField.text]: e.text, ...insightFields(insights(e.text)), ...(tags.length ? { [ClipField.tags]: tags } : {}) };
      } else if (e.image) {
        hash = hashImageHex(hex(new Uint8Array(await crypto.subtle.digest("SHA-256", e.image.bytes))));
        if (!byHash.has(hash)) {
          const ext = e.image.mime === "image/jpeg" ? "jpg" : e.image.mime.split("/")[1];
          fields = { [ClipField.image]: await this.storeBlob(e.image.bytes, `Image.${ext}`, e.image.mime), [ClipField.autoTitle]: "Image" };
        }
      } else continue;
      const tags = cleanTags((e.pinboards ?? []).map((p) => cleanTagName(p)).filter(Boolean));
      const existing = byHash.get(hash);
      if (existing) {
        if (tags.some((t) => !existing.tags.includes(t))) this.setClipTags(existing.id, [...existing.tags, ...tags]);
        merged++;
        continue;
      }
      const at = e.createdAt ?? this.now();
      const id = crypto.randomUUID().toLowerCase();
      const all = { ...fields, [ClipField.hash]: hash, [ClipField.createdAt]: at, [ClipField.lastUsedAt]: at, [ClipField.device]: this.journal.device,
        [ClipField.sourceDevice]: `${source} import`, [ClipField.needsEnrichment]: !e.text };
      if (e.app) all[ClipField.sourceApp] = e.app;
      if (e.bundle) all[ClipField.sourceBundle] = e.bundle;
      if (e.url && e.url !== e.text) all[ClipField.sourceURL] = e.url;
      if (e.title) all[ClipField.title] = e.title;
      if (tags.length) all[ClipField.tags] = cleanTags([...(all[ClipField.tags] ?? []), ...tags]);
      this.set(all, id, "clip");
      this.recordClipEvent(id, "copy", { app: e.app, bundle: e.bundle, at });
      byHash.set(hash, this.clip(id));
      added++;
    }
    return { added, merged };
  }

  /** A clip's connections: other clips and library items. */
  setClipLinks(id, links) { this.set({ links: [...new Set(links)].filter((l) => l !== id) }, id, "clip"); }
  connectClip(id, other) { const c = this.clip(id); if (c && !c.links.includes(other)) this.setClipLinks(id, [...c.links, other]); }
  disconnectClip(id, other) { const c = this.clip(id); if (c) this.setClipLinks(id, c.links.filter((l) => l !== other)); }

  /** Turns a clip into a library item (link, note or file) and links the two. */
  async saveClipToLibrary(id) {
    const clip = this.clip(id);
    if (!clip) return null;
    if (clip.savedItem && this.item(clip.savedItem)) return clip.savedItem;
    let itemId;
    const named = clip.title ?? clip.aiTitle;
    if (clip.image) itemId = await this.addFile(await this.attachment(clip.image.id), clip.image.name, clip.image.mime, { source: "clipboard", title: named ?? undefined });
    else if (clip.kind === "link") itemId = this.addLink(clip.text.trim(), { title: named ?? "", note: clip.note, source: "clipboard" }).id;
    else itemId = this.addNote({ title: named ?? "", body: clip.note ? `${clip.text}\n\n${clip.note}` : clip.text, source: "clipboard" });
    // The item keeps where the copy came from (Library.saveClipToLibrary).
    const origin = { clip: id };
    if (clip.sourceApp) origin.app = clip.sourceApp;
    if (clip.sourceURL) origin.url = clip.sourceURL;
    if (clip.sourceTitle) origin.title = clip.sourceTitle;
    const fields = { [Field.origin]: origin };
    const item = this.item(itemId);
    if (clip.tags.length && item) fields[Field.tags] = cleanTags([...item.tags, ...clip.tags]).sort();
    if (clip.summary) fields[Field.summary] = clip.summary;
    if (clip.ocrText) fields[Field.ocrText] = clip.ocrText;
    this.update(itemId, fields);
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
    // Made from the relay's entry id, so the website and an app importing the same entry write one item.
    const newItemId = entry.id ? inboxItemId(entry.id) : newId();
    if (h.source === "webdav") {
      const path = h.meta?.davPath ?? entry.davPath ?? h.name ?? "notebook.pdf";
      const name = h.name ?? "notebook.pdf";
      let mime = h.mime ?? mimeForName(name);
      if (mime === "application/octet-stream" && /\.pdf$/i.test(name)) mime = "application/pdf";
      const attachment = await this.storeBlob(body, name, mime);
      const existing = this.items().find((i) => i.record.fields.origin?.davPath === path);
      if (existing) {
        // A newer backup of the same notebook: the previous one is kept as a version.
        const fields = { attachments: [attachment], needsEnrichment: true, ocrText: null, enrichment: null, thumbnail: null };
        const old = existing.attachments[0];
        if (old && old.id !== attachment.id) fields.fileVersions = this.versionsAdding(old, existing);
        this.update(existing.id, fields);
        return existing.id;
      }
      this.set({ ...this.baseFields(mime === "application/pdf" ? "pdf" : "file", titleFromFileName(name)), source: "goodnotes", attachments: [attachment],
        origin: { davPath: path }, ...this.filing({ kind: "pdf", source: "goodnotes" }) }, newItemId, "item");
      return newItemId;
    }
    if (h.source === "email") {
      if (h.mime === "text/html" || h.mime === "text/plain") {
        const id = newItemId;
        const origin = {};
        if (h.groupId) origin.emailGroup = h.groupId;
        if (h.meta?.from) origin.from = h.meta.from;
        this.set({ ...this.baseFields("email", h.title ?? "Email"), source: "email", origin, ...this.filing({ kind: "email", source: "email" }) }, id, "item");
        this.editText(Field.body, h.mime === "text/html" ? htmlToText(text()) : text(), id, "item");
        return id;
      }
      const attachment = await this.storeBlob(body, h.name ?? "attachment", h.mime ?? "application/octet-stream");
      const parent = h.groupId && this.items().find((i) => i.record.fields.origin?.emailGroup === h.groupId);
      if (parent) {
        this.update(parent.id, { attachments: [...parent.attachments, attachment] });
        return parent.id;
      }
      return this.addFile(body, attachment.name, attachment.mime, { source: "email", id: newItemId });
    }
    const source = h.source === "web" ? "web" : "share";
    if (h.url) {
      const note = h.mime?.startsWith("text/") ? text() : "";
      const { id, isNew } = this.addLink(h.url, { title: h.title ?? "", note, source, id: newItemId });
      const item = this.item(id);
      if (!isNew && note && item) this.setBody(id, item.body ? `${item.body}\n\n${note}` : note);
      return id;
    }
    if (h.mime && !h.mime.startsWith("text/")) return this.addFile(body, h.name ?? "file", h.mime, { source, title: h.title, id: newItemId });
    return this.addNote({ title: h.title ?? "", body: text(), source, id: newItemId });
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
  async addFile(bytes, name, mime, { source = "web", title, id: itemId = newId(), folder = [] } = {}) {
    const attachment = await this.storeBlob(bytes, name, mime);
    const kind = mime.startsWith("image/") ? "image" : mime === "application/pdf" ? "pdf" : mime.startsWith("audio/") ? "audio" : mime.startsWith("video/") ? "video" : "file";
    this.set({ ...this.baseFields(kind, title ?? titleFromFileName(name)), [Field.source]: source, [Field.attachments]: [attachment],
      ...this.filing({ kind, source, fileName: name, importPath: folder }) }, itemId, "item");
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


function mimeForName(name) {
  const ext = /\.([^./]+)$/.exec(name)?.[1]?.toLowerCase() ?? "";
  return { pdf: "application/pdf", goodnotes: "application/octet-stream", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg" }[ext] ?? "application/octet-stream";
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
