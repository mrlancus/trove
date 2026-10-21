// What the search Worker does (search-worker.js), kept free of Worker plumbing so node can test it:
// an index of items and one of clips, kept in step with the page by small diffs, saved encrypted in
// IndexedDB (a non-extractable AES-GCM key made here, never raw key bytes) and loaded in one read.
import { CLIP_FIELDS, clipFilter, clipIndexQuery, folderMap, hasWords, ITEM_FIELDS, parseQuery, TermIndex } from "./search.js";

const FORMAT = 1;
const enc = new TextEncoder(), dec = new TextDecoder();

async function squeeze(bytes, mode) {
  if (typeof CompressionStream === "undefined") return bytes;
  const stream = new Blob([bytes]).stream().pipeThrough(mode === "gzip" ? new CompressionStream("gzip") : new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** IndexedDB key-value store for the Worker, separate from the page's (db.js). */
export function idbStorage(name = "trove-search") {
  const open = () => new Promise((resolve, reject) => {
    const req = indexedDB.open(name, 1);
    req.onupgradeneeded = () => req.result.createObjectStore("kv");
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  const run = (mode, fn) => open().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction("kv", mode);
    const req = fn(tx.objectStore("kv"));
    tx.oncomplete = () => { db.close(); resolve(req?.result); };
    tx.onerror = () => { db.close(); reject(tx.error); };
  }));
  return { get: (k) => run("readonly", (s) => s.get(k)), set: (k, v) => run("readwrite", (s) => s.put(v, k)), delete: (k) => run("readwrite", (s) => s.delete(k)) };
}

export const memoryStorage = () => { const m = new Map(); return { get: async (k) => m.get(k), set: async (k, v) => { m.set(k, v); }, delete: async (k) => { m.delete(k); }, map: m }; };

export class SearchService {
  constructor({ storage = null, saveDelay = 3000, embedder = null } = {}) {
    this.storage = storage;
    this.saveDelay = saveDelay;
    this.items = new TermIndex(ITEM_FIELDS);
    this.clips = new TermIndex(CLIP_FIELDS);
    this.folders = new Map();
    this.scopes = new Map(); // key → Set(id) | null
    this.vaultId = null;
    this.key = null;
    this.dirty = false;
    this.timer = null;
    this.embedder = embedder; // { embed(texts) → Float32Array[] } for search by meaning, or null
    this.vectors = new Map(); // item id → { v, vec }
  }

  /** Loads the saved index for this vault. Returns what it has: { items: [[id, v]], clips: [[id, v]] }. */
  async init(vaultId) {
    this.vaultId = vaultId;
    if (this.storage) {
      try {
        this.key = await this.storage.get("key");
        if (!this.key) {
          this.key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
          await this.storage.set("key", this.key);
        }
        const saved = await this.storage.get(`index:${vaultId}`);
        if (saved) {
          const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: saved.iv }, this.key, saved.data);
          const json = JSON.parse(dec.decode(await squeeze(new Uint8Array(plain), "gunzip")));
          if (json.v === FORMAT) {
            this.items = TermIndex.fromJSON(json.items, ITEM_FIELDS);
            this.clips = TermIndex.fromJSON(json.clips, CLIP_FIELDS);
            this.folders = folderMap(json.folders);
            for (const [id, v, vec] of json.vectors ?? []) this.vectors.set(id, { v, vec: Float32Array.from(vec) });
          }
        }
      } catch {
        // Unreadable (another key, an older format, storage blocked): start again.
        this.items = new TermIndex(ITEM_FIELDS);
        this.clips = new TermIndex(CLIP_FIELDS);
      }
    }
    return { items: this.items.versions(), clips: this.clips.versions() };
  }

  /** Changed docs and removed ids for one index ("items" or "clips"); `folders` [{id, name, parent}] when they changed. */
  apply({ index = "items", docs = [], removed = [], folders }) {
    const target = index === "clips" ? this.clips : this.items;
    for (const id of removed) { target.remove(id); if (index === "items") this.vectors.delete(id); }
    for (const doc of docs) target.update(doc);
    if (folders) this.folders = folderMap(folders);
    target.prepare();
    if (docs.length || removed.length || folders) this.changed();
  }

  setScope(key, ids) { this.scopes.clear(); this.scopes.set(key, ids ? new Set(ids) : null); }

  /**
   * One search of everything: `{ text, scope, limit, snippets, clips, clipLimit, now }` →
   * `{ items: { ids, total, snippets: { id: {field, text, ranges} } }, clips: { ids, total } | null }`.
   */
  async query({ text, scope = null, limit = 400, snippets = 60, clips = false, clipLimit = 8, now = Date.now(), semantic = false }) {
    const q = parseQuery(text);
    let meaning = null;
    if (semantic && this.embedder && q.text.trim().length >= 3) meaning = await this.meaning(q.text).catch(() => null);
    const res = this.items.search(q, { scope: scope === null ? null : this.scopes.get(scope) ?? null, limit, now, folders: this.folders, semantic: meaning });
    const out = { items: { ids: res.hits.map((h) => h.id), total: res.total, snippets: {} }, clips: null };
    if (hasWords(q)) {
      for (const { id } of res.hits.slice(0, snippets)) {
        const s = this.items.snippet(id, res.plan);
        if (s) out.items.snippets[id] = s;
      }
    }
    if (clips) {
      const cq = parseClipQueryLite(text);
      const r = this.clips.search(clipIndexQuery(cq), { now, prefixAll: true, filter: clipFilter(cq), limit: clipLimit });
      out.clips = { ids: r.hits.map((h) => h.id), total: r.total };
    }
    return out;
  }

  // ---------- search by meaning (optional; see search-worker.js for the model) ----------

  /** Embeds items that changed since their vector was made, a few at a time. */
  async embedPending(max = 64) {
    if (!this.embedder) return 0;
    const todo = [];
    for (const doc of this.items.docs.values()) {
      if (this.vectors.get(doc.id)?.v !== doc.v) todo.push(doc);
      if (todo.length >= max) break;
    }
    if (!todo.length) return 0;
    const texts = todo.map((d) => [d.fields.title, d.fields.summary, d.fields.tags, (d.fields.body ?? "").slice(0, 400), (d.fields.ocr ?? "").slice(0, 200)]
      .filter(Boolean).join(". "));
    const vecs = await this.embedder.embed(texts);
    todo.forEach((d, i) => this.vectors.set(d.id, { v: d.v, vec: normalised(vecs[i]) }));
    this.changed();
    return todo.length;
  }

  /** Items by meaning, best first: [[id, cosine]] above `minimum`. */
  async meaning(text, minimum = 0.3) {
    const [q] = await this.embedder.embed([text]);
    const qv = normalised(q), out = [];
    for (const [id, { vec }] of this.vectors) {
      let dot = 0;
      for (let i = 0; i < vec.length; i++) dot += vec[i] * qv[i];
      if (dot >= minimum) out.push([id, dot]);
    }
    return out.sort((a, b) => b[1] - a[1]);
  }

  // ---------- saving ----------

  changed() {
    this.dirty = true;
    if (!this.storage || this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.save().catch(() => {}); }, this.saveDelay);
  }

  /** Saves the index now if it changed (encrypted, gzipped JSON, one record per vault). */
  async save() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    if (!this.storage || !this.dirty || !this.key || !this.vaultId) return false;
    this.dirty = false;
    const json = { v: FORMAT, items: this.items.toJSON(), clips: this.clips.toJSON(),
      folders: [...this.folders].map(([id, f]) => ({ id, name: f.name, parent: f.parent })),
      vectors: [...this.vectors].map(([id, { v, vec }]) => [id, v, [...vec].map((x) => Math.round(x * 1e4) / 1e4)]) };
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, this.key, await squeeze(enc.encode(JSON.stringify(json)), "gzip"));
    await this.storage.set(`index:${this.vaultId}`, { iv, data });
    return true;
  }
}

function normalised(v) {
  const out = Float32Array.from(v);
  let n = 0;
  for (const x of out) n += x * x;
  n = Math.sqrt(n) || 1;
  for (let i = 0; i < out.length; i++) out[i] /= n;
  return out;
}

// core/clips.js parseClipQuery, repeated so the Worker doesn't load clips.js (and everything it imports).
const foldWord = (t) => t.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
export function parseClipQueryLite(query) {
  const q = { words: [], tags: [], apps: [], pinnedOnly: false };
  for (const w of query.split(/\s+/).filter(Boolean)) {
    const lower = w.toLowerCase();
    if (lower.startsWith("tag:") && lower.length > 4) q.tags.push(lower.slice(4).replace(/#/g, ""));
    else if (lower.startsWith("#") && lower.length > 1) q.tags.push(lower.slice(1));
    else if (lower.startsWith("app:") && lower.length > 4) q.apps.push(foldWord(w.slice(4)));
    else if (lower === "is:pinned") q.pinnedOnly = true;
    else q.words.push(foldWord(w));
  }
  return q;
}
