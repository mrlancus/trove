// Records, ops, HLC, journal and segments (docs/PROTOCOL.md §3). Ports of RecordStore.swift,
// HLC.swift, Journal.swift and Segment.swift; any device holding the same ops computes the same records.
import { fromUtf8, sha256Hex, utf8 } from "./bytes.js";
import { merge } from "./merge.js";

// ---------- HLC ----------

export function formatHLC(millis, counter, device) {
  return `${String(millis).padStart(13, "0")}-${String(counter).padStart(4, "0")}-${device}`;
}

export function parseHLC(text) {
  const m = /^(\d+)-(\d+)-(.*)$/s.exec(text ?? "");
  return m ? { millis: Number(m[1]), counter: Number(m[2]), device: m[3] } : null;
}

export class HLCClock {
  constructor(device, last = null, now = () => Date.now()) {
    this.device = device;
    this.last = parseHLC(last) ?? { millis: 0, counter: 0 };
    this.now = now;
  }

  tick() {
    const wall = this.now();
    this.last = wall > this.last.millis ? { millis: wall, counter: 0 } : { millis: this.last.millis, counter: this.last.counter + 1 };
    return formatHLC(this.last.millis, this.last.counter, this.device);
  }

  observe(hlc) {
    const r = parseHLC(hlc);
    if (r && (r.millis > this.last.millis || (r.millis === this.last.millis && r.counter > this.last.counter))) {
      this.last = { millis: r.millis, counter: r.counter };
    }
  }
}

// ---------- Record store ----------

/** An "item" made only by edits to an id that never was one (no kind, no date): left out (RecordStore.swift isStrayItem). */
export const isStrayItem = (r) => r.kind === "item" && r.fields.kind === undefined && r.fields.createdAt === undefined;

const opId = (op) => `${op.d}:${op.s}`;
const order = (a, b) => (a.h !== b.h ? (a.h < b.h ? -1 : 1) : a.d !== b.d ? (a.d < b.d ? -1 : 1) : a.s - b.s);
const maxString = (a, b) => (a > b ? a : b);

export class RecordStore {
  constructor() {
    this.records = new Map();
    this.ops = [];
    this.opIds = new Set();
    this.lastApplied = "";
    this.history = new Map();
    this.resetIndex();
  }

  /** Ids by kind and ink by item (deleted ones too), so reading one kind doesn't walk every record. */
  resetIndex() {
    this.byKind = new Map();
    this.inkByItem = new Map();
    this.version = (this.version ?? 0) + 1;
  }

  /** Adds ops (duplicates ignored); incremental when all are newer, otherwise a full rebuild. */
  apply(incoming) {
    const fresh = incoming.filter((op) => !this.opIds.has(opId(op)) && this.opIds.add(opId(op)));
    if (fresh.length === 0) return false;
    fresh.sort(order);
    this.ops.push(...fresh);
    if (fresh[0].h > this.lastApplied) {
      for (const op of fresh) this.applyOne(op);
    } else {
      this.ops.sort(order);
      this.records = new Map();
      this.history = new Map();
      this.resetIndex();
      this.lastApplied = "";
      for (const op of this.ops) this.applyOne(op);
    }
    return true;
  }

  get visible() {
    return [...this.records.values()].filter((r) => r.fields._deleted !== true);
  }

  /** Records of one kind that aren't deleted. */
  visibleOf(kind) {
    const out = [];
    for (const id of this.byKind.get(kind) ?? []) { const r = this.records.get(id); if (r && r.kind === kind && r.fields._deleted !== true) out.push(r); }
    return out;
  }

  /** Strokes and elements on an item that aren't deleted. */
  inkOn(itemId) {
    const out = [];
    for (const id of this.inkByItem.get(itemId) ?? []) { const r = this.records.get(id); if (r && r.fields._deleted !== true) out.push(r); }
    return out;
  }

  applyOne(op) {
    this.lastApplied = maxString(this.lastApplied, op.h);
    const record = this.records.get(op.r) ?? { id: op.r, kind: op.k ?? "item", fields: {}, texts: {}, conflicts: {}, createdHLC: op.h, updatedHLC: op.h };
    const oldKind = this.records.has(op.r) ? record.kind : null;
    if (op.k) record.kind = op.k;
    if (oldKind !== record.kind) {
      if (oldKind) this.byKind.get(oldKind)?.delete(op.r);
      if (!this.byKind.has(record.kind)) this.byKind.set(record.kind, new Set());
      this.byKind.get(record.kind).add(op.r);
    }
    this.version++;
    record.updatedHLC = maxString(record.updatedHLC, op.h);
    if (op.t === "set") {
      for (const [key, value] of Object.entries(op.f ?? {})) record.fields[key] = value;
    } else if (op.t === "text" && op.x) {
      const edit = op.x;
      const key = `${op.r}\u001f${edit.field}`;
      const versions = this.history.get(key) ?? new Map();
      const current = record.texts[edit.field] ?? "";
      const currentHash = sha256Hex(current);
      versions.set(currentHash, current);
      versions.set(sha256Hex(edit.value), edit.value);
      if (edit.base === currentHash) {
        record.texts[edit.field] = edit.value;
      } else {
        const merged = merge(versions.get(edit.base) ?? "", current, edit.value);
        if (merged !== null) {
          record.texts[edit.field] = merged;
          versions.set(sha256Hex(merged), merged);
        } else {
          (record.conflicts[edit.field] ??= []).push(edit.value);
        }
      }
      this.history.set(key, versions);
    }
    if ((record.kind === "stroke" || record.kind === "element") && typeof record.fields.on === "string") {
      if (!this.inkByItem.has(record.fields.on)) this.inkByItem.set(record.fields.on, new Set());
      this.inkByItem.get(record.fields.on).add(op.r);
    }
    this.records.set(op.r, record);
  }
}

// ---------- Journal (this browser's outgoing ops) ----------

export class Journal {
  /** state = {device, nextSeq, lastHLC}; pending = ops not yet uploaded. */
  constructor(state, pending = [], now) {
    this.state = { nextSeq: 1, lastHLC: null, ...state };
    this.pending = pending;
    this.clock = new HLCClock(state.device, this.state.lastHLC, now);
  }

  get device() { return this.state.device; }

  observe(hlc) { this.clock.observe(hlc); }

  set(fields, record, kind) {
    return this.append({ t: "set", r: record, k: kind, f: fields });
  }

  text(field, value, previous, record, kind) {
    return this.append({ t: "text", r: record, k: kind, x: { field, value, base: sha256Hex(previous) } });
  }

  append(partial) {
    const op = { d: this.device, s: this.state.nextSeq, h: this.clock.tick(), ...partial };
    if (op.k === undefined) delete op.k;
    this.state.nextSeq += 1;
    this.state.lastHLC = op.h;
    this.pending.push(op);
    return op;
  }

  /** Renumbers pending ops to start at `first` (after another tab or a lost local state used the numbers). */
  renumberFrom(first) {
    this.pending.forEach((op, i) => { op.s = first + i; });
    this.state.nextSeq = first + this.pending.length;
  }

  /** Cuts pending ops into segments of at most 512 KiB of plaintext. Doesn't clear them. */
  segments() {
    const out = [];
    let batch = [], size = 0;
    for (const op of this.pending) {
      const opSize = utf8.encode(canonicalJSON(op)).length + 1;
      if (batch.length && size + opSize > MAX_SEGMENT_PLAINTEXT) { out.push(batch); batch = []; size = 0; }
      batch.push(op);
      size += opSize;
    }
    if (batch.length) out.push(batch);
    return out;
  }
}

// ---------- Segments ----------

export const MAX_SEGMENT_PLAINTEXT = 512 * 1024;

/** JSON with sorted keys, like the Swift encoder's `.sortedKeys`. */
export function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).filter((k) => value[k] !== undefined).sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJSON(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function encodeSegment(ops) {
  return utf8.encode(ops.map((op) => canonicalJSON(op) + "\n").join(""));
}

export function decodeSegment(plaintext, device) {
  const ops = fromUtf8.decode(plaintext).split("\n").filter((l) => l.length).map((l) => JSON.parse(l));
  ops.forEach((op, i) => {
    if (op.d !== device || op.s !== ops[0].s + i) throw new Error("segment ops aren't contiguous");
  });
  return ops;
}
