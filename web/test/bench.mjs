// Speed benchmarks for the website's core (docs/ROADMAP.md §3.6). A synthetic vault made from a seed
// (50,000 items, 50,000 clips, a 500-page notebook with 100,000 strokes) is timed through the same
// core functions the website uses: materialising ops, listing items and clips, saving to and opening
// from the local op store (sealed chunks), decoding strokes, and eraser hit-testing.
//
//   node test/bench.mjs                  run, write results, compare with bench-baseline.json
//   BENCH_UPDATE=1 node test/bench.mjs   run and store the results as the new baseline
//   BENCH_SCALE=0.1 node test/bench.mjs  a smaller vault (no comparison: the baseline is full size)
//   BENCH_OUT=<file>                     where results go (default: bench-results.json in the OS temp dir)
//
// Machines differ, so the baseline is scaled by a calibration workload timed on both. A metric fails
// only when it is more than 20 % slower than that AND slower by more than its noise floor.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { importVaultKeys } from "../public/core/keys.js";
import { b64uEncode, sha256Hex } from "../public/core/bytes.js";
import { Journal, RecordStore } from "../public/core/records.js";
import { decodePoints, encodePoints, erase, hits, strokeView } from "../public/core/ink.js";
import { LocalStore } from "../public/core/localstore.js";
import { makeCheckpoint, openCheckpoint, parseCheckpoint, sealCheckpoint } from "../public/core/checkpoint.js";
import { Vault } from "../public/core/vault.js";

const SCALE = Number(process.env.BENCH_SCALE ?? 1);
const SIZES = { items: Math.round(50_000 * SCALE), clips: Math.round(50_000 * SCALE), pages: Math.max(1, Math.round(500 * SCALE)), strokesPerPage: 200 };
const SLOWER = 1.2;
const BASELINE = new URL("./bench-baseline.json", import.meta.url);
const OUT = process.env.BENCH_OUT ?? join(tmpdir(), "trove-bench-results.json");

// ---------- the synthetic vault ----------

function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const WORDS = "plum jam cardamom river map lecture limits physics draft budget invoice recipe garden ticket train meeting notes idea sketch chapter".split(" ");

function makeVault(seed = 42) {
  const random = rng(seed);
  const pick = (a) => a[Math.floor(random() * a.length)];
  const words = (n) => Array.from({ length: n }, () => pick(WORDS)).join(" ");
  let t = 1_700_000_000_000;
  const journal = new Journal({ device: "BENCH" }, [], () => (t += 7));
  const id = (prefix, i) => `${prefix}-${String(i).padStart(8, "0")}`;
  for (let i = 0; i < SIZES.items; i++) {
    const kind = i % 3 === 0 ? "link" : "note";
    const fields = { kind, source: "web", title: words(4), createdAt: t, capturedOn: "BENCH", category: kind, tags: [pick(WORDS)] };
    if (kind === "link") fields.url = `https://example.com/${i}/${pick(WORDS)}`;
    journal.set(fields, id("item", i), "item");
    if (kind === "note") journal.text("body", words(30), "", id("item", i), "item");
  }
  for (let i = 0; i < SIZES.clips; i++) {
    const text = `${words(8)} ${i}`;
    journal.set({ text, hash: sha256Hex(text), createdAt: t, lastUsedAt: t, uses: 1, sourceApp: pick(["Safari", "Notes", "Mail"]), device: "BENCH" }, id("clip", i), "clip");
  }
  const pageList = Array.from({ length: SIZES.pages }, (_, p) => ({ id: `p${p}` }));
  journal.set({ kind: "sketch", source: "web", title: "Notebook", createdAt: t, paper: "lined", pages: pageList.length, pageList }, "notebook", "item");
  let n = 0;
  for (const page of pageList) {
    for (let s = 0; s < SIZES.strokesPerPage; s++) {
      let x = random() * 700 + 30, y = random() * 950 + 30;
      const points = [];
      const count = 20 + Math.floor(random() * 40);
      for (let k = 0; k < count; k++) { x += random() * 6 - 3; y += random() * 6 - 3; points.push({ x, y, p: 0.5 + random() * 0.5, t: k * 0.008 }); }
      journal.set({ on: "notebook", layer: "", page: page.id, tool: "pen", color: "#1c1c1e", width: 2, points: encodePoints(points), createdAt: t + n++, device: "BENCH" }, id("stroke", n), "stroke");
    }
  }
  return journal.pending;
}

// ---------- timing ----------

const now = () => performance.now();
async function time(fn, runs = 3) {
  const times = [];
  for (let i = 0; i < runs; i++) { const t0 = now(); await fn(); times.push(now() - t0); }
  times.sort((a, b) => a - b);
  return times[Math.floor(times.length / 2)];
}

/** A fixed CPU workload (hashing and JSON), so results from different machines can be compared. */
async function calibrate() {
  const data = JSON.stringify(Array.from({ length: 20_000 }, (_, i) => ({ i, s: `value ${i}`, a: [i, i * 2, i * 3] })));
  return time(() => { for (let k = 0; k < 5; k++) { sha256Hex(data.slice(k)); JSON.parse(data); } }, 5);
}

function memoryStorage() {
  const m = new Map();
  return { m, get: async (k) => m.get(k), set: async (k, v) => { m.set(k, v); }, delete: async (k) => { m.delete(k); }, clear: async () => m.clear() };
}

// Absolute noise floors (ms): a metric must be at least this much slower to fail, on top of 20 %.
const FLOORS = {
  materialise: 1000, vaultItems: 100, vaultClips: 100, saveAll: 1500, saveOneEdit: 20, openFromStorage: 1000,
  decodeAllStrokes: 800, notebookPage: 40, eraserHits: 50, partialErase: 30,
};

async function run() {
  const results = { scale: SCALE, sizes: SIZES, node: process.version, metrics: {} };
  const m = results.metrics;
  results.calibration = await calibrate();

  let t0 = now();
  const ops = makeVault();
  results.ops = ops.length;
  results.generate = now() - t0;

  m.materialise = await time(() => { new RecordStore().apply(ops); }, 3);

  const keys = await importVaultKeys({ vaultKey: b64uEncode(new Uint8Array(32).fill(7)) });
  const config = { deviceName: "Bench", deviceId: "WEB", encrypted: true, base: "http://relay", vaultId: "V", token: "T" };
  const vault = new Vault(memoryStorage(), config, keys, { device: "WEB" }, [], ops, [], 0, { now: () => 1_800_000_000_000 });
  m.vaultItems = await time(() => vault.items(), 3);
  m.vaultClips = await time(() => vault.clips(), 3);

  // Saving: everything once (a first save or a migration), then one edit (the common case).
  let storage;
  m.saveAll = await time(async () => {
    storage = memoryStorage();
    const local = new LocalStore(storage);
    await local.save({ journal: {}, fresh: [], all: ops, applied: [], cursor: 0 });
  }, 3);
  const local = new LocalStore(storage);
  await local.load();
  let seq = 0;
  m.saveOneEdit = await time(async () => {
    const op = { d: "WEB", s: ++seq, h: `1800000000000-${String(seq).padStart(4, "0")}-WEB`, t: "set", r: `new-${seq}`, k: "item", f: { kind: "note", title: "new" } };
    await local.save({ journal: { state: {}, pending: [] }, fresh: [op], all: ops, applied: [], cursor: 0 });
  }, 9);
  m.openFromStorage = await time(async () => { await new LocalStore(storage).load(); }, 2);
  // Not gated: what every save cost before the op store was append-only (IndexedDB structured-clones
  // the whole op array; structuredClone here is a lower bound for it).
  results.info = { saveWholeArrayBefore: await time(() => { structuredClone(ops); }, 2) };

  // Checkpoints (PROTOCOL.md §3): what a new device downloads and does instead of replaying every op.
  // Not gated yet (no baseline): written to the results so the next baseline update picks them up.
  let cp, sealed;
  results.info.makeCheckpoint = await time(() => { cp = makeCheckpoint(vault.store, { cursor: 0, device: "WEB" }); }, 1);
  results.info.sealCheckpoint = await time(async () => { sealed = await sealCheckpoint(cp, keys.segment); }, 1);
  results.info.checkpointMB = +(sealed.length / 1e6).toFixed(1);
  results.info.segmentsMB = +(ops.reduce((n, op) => n + JSON.stringify(op).length + 1, 0) / 1e6).toFixed(1);
  results.info.openCheckpoint = await time(async () => {
    const s = new RecordStore();
    s.useBase(parseCheckpoint(await openCheckpoint(sealed, keys.segment)));
  }, 1);

  // Ink: decode every stroke; open one page (cold, through the vault); eraser on that page.
  const strokeRecords = vault.store.visibleOf("stroke");
  m.decodeAllStrokes = await time(() => { for (const r of strokeRecords) decodePoints(r.fields.points); }, 2);
  const pageKeys = Array.from({ length: SIZES.pages }, (_, p) => `p${p}`);
  let pageIndex = 0;
  m.notebookPage = await time(() => {
    // A page not opened before, so stroke views aren't cached yet.
    const records = vault.store.inkOn("notebook").filter((r) => r.fields.page === pageKeys[pageIndex % pageKeys.length]);
    pageIndex += 7;
    return records.map(strokeView);
  }, 7);
  const page = vault.strokes("notebook", "", "p0");
  const random = rng(7);
  const path = Array.from({ length: 100 }, () => ({ x: random() * 760, y: random() * 1010 }));
  m.eraserHits = await time(() => { let n = 0; for (const p of path) for (const s of page) if (hits(s, p.x, p.y, 8)) n++; return n; }, 5);
  m.partialErase = await time(() => { for (const s of page) erase(s.points, path.slice(0, 20), 8); }, 5);
  return results;
}

function compare(results, baseline) {
  const ratio = results.calibration / baseline.calibration;
  const failures = [];
  const rows = [];
  for (const [name, value] of Object.entries(results.metrics)) {
    const base = baseline.metrics[name];
    if (base === undefined) { rows.push(`  ${name.padEnd(18)} ${value.toFixed(1).padStart(9)} ms   (new, no baseline)`); continue; }
    const expected = base * ratio;
    const slower = value > expected * SLOWER && value - expected > (FLOORS[name] ?? 100);
    rows.push(`  ${name.padEnd(18)} ${value.toFixed(1).padStart(9)} ms   expected ≤ ${(expected * SLOWER).toFixed(1)} (${base.toFixed(1)} × ${ratio.toFixed(2)} × ${SLOWER})${slower ? "   SLOWER" : ""}`);
    if (slower) failures.push(name);
  }
  return { rows, failures, ratio };
}

const results = await run();
writeFileSync(OUT, JSON.stringify(results, null, 2) + "\n");
console.log(`Synthetic vault: ${results.ops} ops (${SIZES.items} items, ${SIZES.clips} clips, ${SIZES.pages * SIZES.strokesPerPage} strokes), made in ${results.generate.toFixed(0)} ms`);
console.log(`Calibration: ${results.calibration.toFixed(1)} ms. Results: ${OUT}`);
console.log(`Before the append-only store, every save cloned all ops: ≥ ${results.info.saveWholeArrayBefore.toFixed(0)} ms (now ${results.metrics.saveOneEdit.toFixed(1)} ms)`);
if (process.env.BENCH_UPDATE) {
  if (SCALE !== 1) throw new Error("The baseline is made at full size (BENCH_SCALE=1).");
  const { generate, info, ...stored } = results;
  writeFileSync(BASELINE, JSON.stringify(stored, null, 2) + "\n");
  for (const [k, v] of Object.entries(results.metrics)) console.log(`  ${k.padEnd(18)} ${v.toFixed(1).padStart(9)} ms`);
  console.log("Baseline updated.");
} else if (SCALE !== 1) {
  for (const [k, v] of Object.entries(results.metrics)) console.log(`  ${k.padEnd(18)} ${v.toFixed(1).padStart(9)} ms`);
  console.log("Not compared: the baseline is for BENCH_SCALE=1.");
} else {
  const baseline = JSON.parse(readFileSync(BASELINE, "utf8"));
  const { rows, failures, ratio } = compare(results, baseline);
  console.log(`This machine is ${ratio.toFixed(2)}× the baseline machine's time.`);
  for (const r of rows) console.log(r);
  if (failures.length) {
    console.error(`Slower than the baseline by more than 20 %: ${failures.join(", ")}`);
    process.exitCode = 1;
  } else {
    console.log("No regressions.");
  }
}
