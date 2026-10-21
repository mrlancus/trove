// Checkpoints (docs/PROTOCOL.md §3 "Checkpoints"): the materialised records at some point, so a new
// device (or a website login) loads one file instead of replaying every op since the vault began.
// A port of Checkpoint.swift; both sides check Fixtures/checkpoint-cases.json.
//
// A checkpoint holds, for every record, its kind, first and last HLC and its fields grouped by the
// HLC of the op that set them; every text op verbatim (text merges replay them); and which ops it
// covers (per device, ranges of sequence numbers). Ops it doesn't cover, even older ones from a device
// that was offline, then apply on top exactly as a full replay would.
import { concat, fromUtf8, u32, utf8 } from "./bytes.js";
import { opOrder, rangesOf } from "./records.js";
import { decrypt, encrypt } from "./trv1.js";

const MAGIC = utf8.encode("TRC1");
const PLAIN = 0, DEFLATE = 1;
/** Don't upload checkpoints bigger than this (the relay takes up to 95 MB). */
export const MAX_CHECKPOINT_BYTES = 90 * 1024 * 1024;

/**
 * The checkpoint of everything `store` holds. Call it only when every op is pushed (no pending
 * journal), so nothing it covers can be renumbered. `cursor` is the relay cursor every relay segment
 * up to which is applied (null without a relay).
 */
export function makeCheckpoint(store, { cursor = null, device = "", createdAt = Date.now() } = {}) {
  // Which op set each field (and the kind): the checkpoint's own, then every op since, in order.
  const stamps = new Map();
  if (store.base) for (const [id, s] of store.base.stamps) stamps.set(id, { fields: { ...s.fields }, kind: s.kind });
  const seqs = new Map();
  if (store.base) for (const [d, ranges] of store.base.covers) seqs.set(d, ranges.map((r) => [...r]));
  const texts = [];
  const ops = [...store.ops].sort(opOrder);
  for (const op of ops) {
    if (!seqs.has(op.d)) seqs.set(op.d, []);
    seqs.get(op.d).push([op.s, op.s]);
    if (op.t === "text") texts.push(op);
    let s = stamps.get(op.r);
    if (!s) { s = { fields: {}, kind: undefined }; stamps.set(op.r, s); }
    if (op.k && !(s.kind && op.h < s.kind)) s.kind = op.h;
    if (op.t === "set") {
      for (const key of Object.keys(op.f ?? {})) if (!(s.fields[key] !== undefined && op.h < s.fields[key])) s.fields[key] = op.h;
    }
  }
  const covers = {};
  for (const [d, list] of [...seqs].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) covers[d] = mergeRanges(list);
  const records = [];
  for (const id of [...store.records.keys()].sort()) {
    const r = store.records.get(id), s = stamps.get(id) ?? { fields: {} };
    const groups = new Map();
    for (const key of Object.keys(r.fields).sort()) {
      const h = s.fields[key] ?? r.updatedHLC;
      if (!groups.has(h)) groups.set(h, {});
      groups.get(h)[key] = r.fields[key];
    }
    const entry = { id, k: r.kind, c: r.createdHLC, u: r.updatedHLC, g: [...groups].sort(([a], [b]) => (a < b ? -1 : 1)) };
    if (s.kind) entry.ks = s.kind;
    records.push(entry);
  }
  return { v: 1, frontier: store.lastApplied, cursor, device, createdAt, covers, records, texts };
}

function mergeRanges(list) {
  list.sort((a, b) => a[0] - b[0]);
  const out = [];
  for (const [a, b] of list) {
    const last = out[out.length - 1];
    if (last && a <= last[1] + 1) last[1] = Math.max(last[1], b);
    else out.push([a, b]);
  }
  return out;
}

/** A checkpoint as RecordStore.useBase takes it: records with their fields, stamps by record, covers as a Map. */
export function parseCheckpoint(cp) {
  if (!cp || cp.v !== 1 || !Array.isArray(cp.records) || !Array.isArray(cp.texts) || typeof cp.covers !== "object") throw new Error("not a Trove checkpoint");
  const covers = new Map();
  for (const [d, ranges] of Object.entries(cp.covers)) covers.set(d, mergeRanges(ranges.map(([a, b]) => [a, b])));
  const records = [], stamps = new Map();
  for (const r of cp.records) {
    const fields = {}, fieldStamps = {};
    for (const [h, group] of r.g ?? []) for (const [key, value] of Object.entries(group)) { fields[key] = value; fieldStamps[key] = h; }
    records.push({ id: r.id, kind: r.k ?? "item", created: r.c, updated: r.u, fields });
    stamps.set(r.id, { fields: fieldStamps, kind: r.ks });
  }
  return { frontier: cp.frontier ?? "", cursor: cp.cursor ?? null, device: cp.device ?? "", createdAt: cp.createdAt ?? 0, covers, records, stamps, texts: cp.texts };
}

/** How many ops of `device` the checkpoint covers up to (the highest sequence number), or 0. */
export function lastCoveredSeq(base, device) {
  const ranges = base?.covers.get(device);
  return ranges?.length ? ranges[ranges.length - 1][1] : 0;
}

// ---------- bytes ----------

async function pipe(bytes, transform) {
  return new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(transform)).arrayBuffer());
}

/** "TRC1", a format byte (0 = JSON, 1 = raw DEFLATE of the JSON, after a u32 of its length), then the payload. */
export async function encodeCheckpoint(cp, { compress = typeof CompressionStream === "function" } = {}) {
  const json = utf8.encode(JSON.stringify(cp));
  if (!compress) return concat(MAGIC, new Uint8Array([PLAIN]), json);
  return concat(MAGIC, new Uint8Array([DEFLATE]), u32(json.length), await pipe(json, new CompressionStream("deflate-raw")));
}

export async function decodeCheckpoint(bytes) {
  if (bytes.length < 5 || !MAGIC.every((b, i) => bytes[i] === b)) throw new Error("not a Trove checkpoint");
  let json;
  if (bytes[4] === PLAIN) json = bytes.subarray(5);
  else if (bytes[4] === DEFLATE) json = await pipe(bytes.subarray(9), new DecompressionStream("deflate-raw"));
  else throw new Error("unknown checkpoint format");
  return JSON.parse(fromUtf8.decode(json));
}

/** Encrypted for the relay or iCloud: TRV1 with the segment key (§2), so only the vault's devices can read it. */
export async function sealCheckpoint(cp, segmentKey) {
  return encrypt(await encodeCheckpoint(cp), segmentKey);
}

export async function openCheckpoint(data, segmentKey) {
  return decodeCheckpoint(await decrypt(data, segmentKey));
}

export { rangesOf };
