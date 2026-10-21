// The web app's local copy of its vault (docs/PROTOCOL.md §7 "At rest"). Ops are kept in
// append-only chunks, so a save writes only the ops that are new since the last one; small chunks are
// merged as they pile up. Everything here is sealed with a non-extractable AES-GCM key made for this
// browser. Works over any {get, set, clear, delete?} store: IndexedDB in the browser, a Map in tests.
// A store that can't hold a CryptoKey and is private already (trove-mcp's owner-only files) sets
// `plainAtRest = true`, and values are kept as they are.
import { fromUtf8, utf8 } from "./bytes.js";

const INDEX = "opChunks";
const LOCAL_KEY = "localKey";
const OWNER = "localOwner";
const LEGACY_OPS = "ops";
/** {v: 1, id, cursor, data: b64u of the TRV1 checkpoint as the relay keeps it} (PROTOCOL.md §7). */
const BASE = "base";
/** A chunk isn't merged past this many bytes of JSON, so no single write gets huge. */
export const CHUNK_BYTES = 4 * 1024 * 1024;
const chunkKey = (n) => `ops.${n}`;
const isSealed = (v) => v && typeof v === "object" && v.sealed === 1 && v.iv && v.data;

export class LocalStore {
  constructor(storage, { chunkBytes = CHUNK_BYTES } = {}) {
    this.storage = storage;
    this.chunkBytes = chunkBytes;
    this.chunks = null; // [{ n, count, bytes, ops }] once loaded or first saved
    this.next = 0;
    this.needsRewrite = false;
    this.owner = crypto.randomUUID();
    this.claimed = false;
    this.queue = Promise.resolve();
  }

  // ---------- sealing ----------

  /** This browser's at-rest key: made once, non-extractable, kept next to the vault keys. */
  key() {
    this.keyPromise ??= (async () => {
      const existing = await this.storage.get(LOCAL_KEY);
      if (existing) return existing;
      const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
      await this.storage.set(LOCAL_KEY, key);
      return key;
    })();
    return this.keyPromise;
  }

  async seal(slot, value) {
    if (this.storage.plainAtRest) return value;
    const json = JSON.stringify(value);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: utf8.encode(`trove/local/${slot}`) }, await this.key(), utf8.encode(json));
    return { sealed: 1, iv, data: new Uint8Array(data), size: json.length };
  }

  /** The value in a slot; plain (pre-encryption) values are returned as they are. */
  async unseal(slot, stored) {
    if (!isSealed(stored)) return stored;
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: stored.iv, additionalData: utf8.encode(`trove/local/${slot}`) }, await this.key(), stored.data);
    return JSON.parse(fromUtf8.decode(new Uint8Array(plain)));
  }

  // ---------- loading ----------

  /**
   * Everything saved here: { journal, ops, applied, cursor }. Old browsers kept these as plain
   * values and every op under one "ops" key; that still opens, and `needsRewrite` is set so the next
   * save stores it sealed and chunked. Unreadable data (a lost key) opens as empty: the relay still
   * has every pushed op, and a cursor of 0 pulls them again.
   */
  async load() {
    let readable = true;
    // The checkpoint this copy starts from (already encrypted with the vault's segment key).
    const base = await this.storage.get(BASE);
    const raw = {};
    for (const slot of ["journal", "applied", "cursor"]) raw[slot] = await this.storage.get(slot);
    // Something stored before encryption at rest: write it again, sealed.
    if (Object.values(raw).some((v) => v !== undefined && v !== null && !isSealed(v))) this.needsRewrite = true;
    const read = async (slot) => {
      try { return await this.unseal(slot, raw[slot]); } catch { readable = false; return undefined; }
    };
    const journal = (await read("journal")) ?? null;
    let applied = (await read("applied")) ?? [], cursor = (await read("cursor")) ?? 0, ops = [];
    const index = await this.storage.get(INDEX);
    this.chunks = [];
    this.stale = [];
    this.next = index?.next ?? 0;
    for (const c of index?.chunks ?? []) {
      let chunk;
      try { chunk = await this.unseal("ops", await this.storage.get(chunkKey(c.n))); } catch { chunk = null; }
      if (!Array.isArray(chunk)) { readable = false; this.stale.push(c.n); continue; }
      this.chunks.push({ n: c.n, count: chunk.length, bytes: c.bytes ?? 0, ops: chunk });
      for (const op of chunk) ops.push(op);
    }
    const legacy = await this.storage.get(LEGACY_OPS);
    if (Array.isArray(legacy)) { for (const op of legacy) ops.push(op); this.needsRewrite = true; }
    if (!readable) {
      // Keep the journal (unsent edits) if it could be read; pull everything else again.
      ops = []; applied = []; cursor = 0; this.needsRewrite = true;
    }
    return { journal, ops, applied, cursor, base: readable && base?.data ? base : null };
  }

  // ---------- saving ----------

  /** Runs writes one after another (saves and journal writes never interleave). */
  enqueue(fn) {
    const run = this.queue.then(fn);
    this.queue = run.catch(() => {});
    return run;
  }

  /**
   * Another Vault opened this storage after us (the user chose "use here" in another tab): stop
   * writing, so a stale copy can't drop chunks the live one relies on.
   */
  async mayWrite() {
    if (!this.claimed) {
      await this.storage.set(OWNER, this.owner);
      this.claimed = true;
      return true;
    }
    return (await this.storage.get(OWNER)) === this.owner;
  }

  /** Claims the storage for this copy (Vault.open does it; the first save does it otherwise). */
  claim() { return this.enqueue(() => this.mayWrite()); }

  writeJournal(journal) {
    return this.enqueue(async () => {
      if (!(await this.mayWrite())) return false;
      await this.storage.set("journal", await this.seal("journal", journal));
      return true;
    });
  }

  /**
   * Saves `fresh` (ops new since the last save) as one chunk, or every op in `all` when the store
   * was rebuilt or migrated. `all` may be a function, called only when needed.
   */
  save({ journal, fresh, all, applied, cursor, base }) {
    return this.enqueue(async () => {
      if (!(await this.mayWrite())) return false;
      if (base !== undefined) {
        // A new checkpoint goes first: the ops it covers that are still in old chunks are then just
        // ignored, so a crash before the chunks are rewritten loses nothing.
        if (base) await this.storage.set(BASE, base);
        else await this.remove([BASE]);
        this.needsRewrite = true;
      }
      try {
        if (this.chunks === null) {
          // Never loaded (a vault made in this session): whatever is stored is ours to replace.
          const index = await this.storage.get(INDEX);
          this.chunks = [];
          this.next = index?.next ?? 0;
          this.stale = (index?.chunks ?? []).map((c) => c.n);
          this.needsRewrite = true;
        }
        if (this.needsRewrite) await this.rewrite(typeof all === "function" ? all() : all);
        else if (fresh.length) await this.append(fresh);
      } catch (e) {
        this.needsRewrite = true;
        throw e;
      }
      await this.storage.set("journal", await this.seal("journal", journal));
      await this.storage.set("applied", await this.seal("applied", applied));
      await this.storage.set("cursor", await this.seal("cursor", cursor));
      return true;
    });
  }

  async writeChunk(ops) {
    const n = this.next++;
    const sealed = await this.seal("ops", ops);
    await this.storage.set(chunkKey(n), sealed);
    return { n, count: ops.length, bytes: sealed.size, ops };
  }

  writeIndex() {
    return this.storage.set(INDEX, { v: 1, next: this.next, chunks: this.chunks.map(({ n, count, bytes }) => ({ n, count, bytes })) });
  }

  async remove(keys) {
    for (const k of keys) {
      if (typeof this.storage.delete === "function") await this.storage.delete(k);
      else await this.storage.set(k, undefined);
    }
  }

  async append(ops) {
    this.chunks.push(await this.writeChunk(ops));
    // Merge the tail while the chunk before the last is no more than twice its size (like a binary
    // counter: each op is rewritten O(log n) times), up to the chunk size limit.
    const dropped = [];
    while (this.chunks.length >= 2) {
      const last = this.chunks[this.chunks.length - 1], prev = this.chunks[this.chunks.length - 2];
      if (prev.bytes > 2 * last.bytes || prev.bytes + last.bytes > this.chunkBytes) break;
      this.chunks.splice(-2, 2, await this.writeChunk(prev.ops.concat(last.ops)));
      dropped.push(prev.n, last.n);
    }
    await this.writeIndex();
    await this.remove(dropped.filter((n) => !this.chunks.some((c) => c.n === n)).map(chunkKey));
  }

  async rewrite(all) {
    const ops = [...all]; // a snapshot: the live array keeps growing (and re-sorting) while we write
    const old = [...this.chunks.map((c) => c.n), ...(this.stale ?? [])];
    this.chunks = [];
    this.stale = old; // until the new index is written, the old chunks are still to delete
    try {
      // Split by size: estimate each op's JSON length once.
      let start = 0, bytes = 0;
      for (let i = 0; i < ops.length; i++) {
        bytes += JSON.stringify(ops[i]).length + 1;
        if (bytes >= this.chunkBytes / 2 || i === ops.length - 1) {
          this.chunks.push(await this.writeChunk(ops.slice(start, i + 1)));
          start = i + 1; bytes = 0;
        }
      }
      await this.writeIndex();
    } catch (e) {
      this.stale = [...old, ...this.chunks.map((c) => c.n)];
      this.chunks = [];
      throw e;
    }
    this.stale = null;
    this.needsRewrite = false;
    await this.remove([...old.map(chunkKey), LEGACY_OPS]);
  }
}
