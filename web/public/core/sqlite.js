// A small read-only SQLite reader (https://sqlite.org/fileformat.html): tables, their columns and
// rows, with overflow pages and a write-ahead log (`-wal`) applied. Enough to read another app's
// database in the browser (the Paste importer, pasteimport.js) without WebAssembly.

const text = new TextDecoder();

function varint(view, at) {
  let v = 0n;
  for (let i = 0; i < 8; i++) {
    const b = view.getUint8(at + i);
    v = (v << 7n) | BigInt(b & 0x7f);
    if (!(b & 0x80)) return [v, i + 1];
  }
  return [(v << 8n) | BigInt(view.getUint8(at + 8)), 9];
}

/** The column names in a CREATE TABLE statement, and which one is the rowid (INTEGER PRIMARY KEY). */
export function columnsOf(sql) {
  const open = sql.indexOf("("), close = sql.lastIndexOf(")");
  if (open < 0 || close < open) return { names: [], rowidColumn: -1 };
  const body = sql.slice(open + 1, close);
  const parts = [];
  let depth = 0, start = 0, quote = null;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (quote) { if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"' || c === "`" || c === "[") { quote = c === "[" ? "]" : c; continue; }
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "," && depth === 0) { parts.push(body.slice(start, i)); start = i + 1; }
  }
  parts.push(body.slice(start));
  const names = [];
  let rowidColumn = -1;
  for (const raw of parts) {
    const p = raw.trim();
    if (!p || /^(constraint|primary\s+key|unique|check|foreign\s+key)\b/i.test(p)) continue;
    const m = /^(?:"([^"]+)"|`([^`]+)`|\[([^\]]+)\]|'([^']+)'|(\S+))\s*(.*)$/s.exec(p);
    if (!m) continue;
    const name = m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5];
    if (/^integer\s+primary\s+key/i.test(m[6].trim())) rowidColumn = names.length;
    names.push(name);
  }
  return { names, rowidColumn };
}

export class SQLiteFile {
  /** `bytes`: the database file; `wal`: its `-wal` file, if there is one. */
  constructor(bytes, wal = null) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (text.decode(bytes.subarray(0, 15)) !== "SQLite format 3") throw new Error("This isn't a SQLite database");
    const ps = this.view.getUint16(16);
    this.pageSize = ps === 1 ? 65536 : ps;
    this.usable = this.pageSize - this.view.getUint8(20);
    this.overlay = new Map();
    if (wal) this.applyWAL(wal);
  }

  /** The newest committed copy of each page in the log (frames with the log's current salts). */
  applyWAL(wal) {
    if (wal.length < 32) return;
    const v = new DataView(wal.buffer, wal.byteOffset, wal.byteLength);
    const magic = v.getUint32(0);
    if (magic !== 0x377f0682 && magic !== 0x377f0683) return;
    const pageSize = v.getUint32(8), salt1 = v.getUint32(16), salt2 = v.getUint32(20);
    if (pageSize !== this.pageSize) return;
    let pending = new Map();
    for (let at = 32; at + 24 + pageSize <= wal.length; at += 24 + pageSize) {
      if (v.getUint32(at + 8) !== salt1 || v.getUint32(at + 12) !== salt2) break;
      pending.set(v.getUint32(at), wal.subarray(at + 24, at + 24 + pageSize));
      if (v.getUint32(at + 4) !== 0) { for (const [n, page] of pending) this.overlay.set(n, page); pending = new Map(); }
    }
  }

  page(n) {
    const own = this.overlay.get(n);
    if (own) return { bytes: own, view: new DataView(own.buffer, own.byteOffset, own.byteLength) };
    const start = (n - 1) * this.pageSize;
    if (start < 0 || start + this.pageSize > this.bytes.length) throw new Error(`page ${n} is outside the file`);
    const bytes = this.bytes.subarray(start, start + this.pageSize);
    return { bytes, view: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength) };
  }

  /** Every row of the table b-tree at `root`, as {rowid, payload}. */
  *cells(root, seen = new Set()) {
    if (seen.has(root)) return; // a loop: a damaged file
    seen.add(root);
    const { bytes, view } = this.page(root);
    const h = root === 1 ? 100 : 0;
    const type = view.getUint8(h), count = view.getUint16(h + 3);
    if (type === 0x05) {
      for (let i = 0; i < count; i++) yield* this.cells(view.getUint32(view.getUint16(h + 12 + i * 2)), seen);
      yield* this.cells(view.getUint32(h + 8), seen);
    } else if (type === 0x0d) {
      for (let i = 0; i < count; i++) {
        let at = view.getUint16(h + 8 + i * 2);
        const [size, a] = varint(view, at); at += a;
        const [rowid, b] = varint(view, at); at += b;
        yield { rowid: Number(rowid), payload: this.payload(bytes, view, at, Number(size)) };
      }
    }
  }

  /** A cell's payload, joined from its overflow pages when it's too big for the page. */
  payload(bytes, view, at, size) {
    const u = this.usable, x = u - 35;
    if (size <= x) return bytes.subarray(at, at + size);
    const m = Math.floor(((u - 12) * 32) / 255) - 23;
    const k = m + ((size - m) % (u - 4));
    const local = k <= x ? k : m;
    const out = new Uint8Array(size);
    out.set(bytes.subarray(at, at + local), 0);
    let filled = local, next = view.getUint32(at + local);
    const seen = new Set();
    while (next && filled < size && !seen.has(next)) {
      seen.add(next);
      const p = this.page(next);
      const take = Math.min(u - 4, size - filled);
      out.set(p.bytes.subarray(4, 4 + take), filled);
      filled += take;
      next = p.view.getUint32(0);
    }
    return out;
  }

  /** A record's values: null, numbers, strings and Uint8Arrays (blobs). */
  static record(payload) {
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const [headerSize, n] = varint(view, 0);
    const types = [];
    for (let at = n; at < Number(headerSize);) { const [t, k] = varint(view, at); types.push(Number(t)); at += k; }
    const values = [];
    let at = Number(headerSize);
    for (const t of types) {
      if (t === 0) values.push(null);
      else if (t >= 1 && t <= 6) {
        const len = [0, 1, 2, 3, 4, 6, 8][t];
        let v = 0n;
        for (let i = 0; i < len; i++) v = (v << 8n) | BigInt(payload[at + i]);
        if (payload[at] & 0x80) v -= 1n << BigInt(len * 8);
        values.push(Number(v));
        at += len;
      } else if (t === 7) { values.push(view.getFloat64(at)); at += 8; }
      else if (t === 8 || t === 9) values.push(t - 8);
      else if (t >= 12 && t % 2 === 0) { const len = (t - 12) / 2; values.push(payload.slice(at, at + len)); at += len; }
      else if (t >= 13) { const len = (t - 13) / 2; values.push(text.decode(payload.subarray(at, at + len))); at += len; }
      else values.push(null);
    }
    return values;
  }

  /** The tables: [{name, root, columns, rowidColumn}]. */
  tables() {
    if (this._tables) return this._tables;
    const out = [];
    for (const { payload } of this.cells(1)) {
      const [type, name, , root, sql] = SQLiteFile.record(payload);
      if (type !== "table" || typeof root !== "number" || !root || typeof sql !== "string") continue;
      const { names, rowidColumn } = columnsOf(sql);
      out.push({ name, root, columns: names, rowidColumn });
    }
    return (this._tables = out);
  }

  table(name) { return this.tables().find((t) => t.name.toLowerCase() === name.toLowerCase()) ?? null; }

  /** A table's rows as objects keyed by column name (the rowid column gets the rowid). */
  rows(name) {
    const t = typeof name === "string" ? this.table(name) : name;
    if (!t) return [];
    const out = [];
    for (const { rowid, payload } of this.cells(t.root)) {
      const values = SQLiteFile.record(payload);
      const row = { rowid };
      t.columns.forEach((c, i) => { row[c] = i === t.rowidColumn ? rowid : values[i] ?? null; });
      out.push(row);
    }
    return out;
  }
}
