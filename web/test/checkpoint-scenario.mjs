// Three devices editing one vault, with a checkpoint in the middle (PROTOCOL.md §3 "Checkpoints").
// Device C is offline: its ops have older HLCs than the checkpoint but arrive after it, so loading the
// checkpoint and then every op it doesn't cover must give exactly what a full replay gives.
// Used by make-checkpoint-fixture.mjs (Fixtures/checkpoint-cases.json) and core.test.mjs.
import { Journal } from "../public/core/records.js";

/** A small seeded PRNG (mulberry32), so the scenario is the same everywhere. */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function checkpointScenario(seed = 7) {
  const rand = rng(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  let clock = 1_760_000_000_000;
  const now = () => (clock += 1 + Math.floor(rand() * 3));
  const a = new Journal({ device: "AAAA" }, [], now);
  const b = new Journal({ device: "BBBB" }, [], now);
  const c = new Journal({ device: "CCCC" }, [], now); // offline: its HLCs lag behind
  const texts = new Map(); // record → text each device last saw
  const body = (j, id, value) => {
    const key = `${j.device}:${id}`;
    const prev = texts.get(key) ?? "";
    texts.set(key, value);
    return j.text("body", value, prev, id, "item");
  };
  // Shared start: notes, a link, strokes, a collection.
  a.set({ kind: "note", title: "Plan", createdAt: 1, tags: ["home"] }, "n1", "item");
  body(a, "n1", "one\ntwo\nthree");
  a.set({ kind: "link", url: "https://example.com", title: "Example" }, "l1", "item");
  for (let i = 0; i < 6; i++) a.set({ on: "s1", layer: "", page: "p0", tool: "pen", color: "#000000", width: 2, points: "AAAgQQAAoEEAAAA_AAAAAA", createdAt: i }, `st${i}`, "stroke");
  a.set({ name: "Kitchen" }, "c1", "collection");
  // B and C both saw that.
  for (const op of a.pending) { b.observe(op.h); c.observe(op.h); }
  for (const j of [b, c]) texts.set(`${j.device}:n1`, "one\ntwo\nthree");
  // C goes offline now: its later edits keep old HLCs.
  const cClock = clock;
  // A and B carry on (these end up in the checkpoint).
  body(a, "n1", "one\ntwo\nthree\nfour");
  body(b, "n1", "zero\none\ntwo\nthree");
  b.set({ title: "Plans" }, "n1");
  a.set({ pinned: true }, "n1");
  b.set({ _deleted: true }, "st2", "stroke");
  a.set({ title: "Example site", tags: ["web"] }, "l1");
  b.set({ kind: "note", title: "Second", createdAt: 2 }, "n2", "item");
  body(b, "n2", "hello");
  for (let i = 0; i < 20; i++) {
    const j = pick([a, b]);
    const r = rand();
    if (r < 0.4) j.set({ title: `t${i}`, [pick(["x", "y", "z"])]: i }, pick(["n1", "n2", "l1"]));
    else if (r < 0.6) j.set({ color: pick(["#ff0000", "#00ff00"]) }, `st${Math.floor(rand() * 6)}`, "stroke");
    else body(j, pick(["n1", "n2"]), `line ${i}\n${texts.get(`${j.device}:n2`) ?? ""}`);
  }
  const checkpointed = { AAAA: a.state.nextSeq - 1, BBBB: b.state.nextSeq - 1 };
  // C's offline edits: older HLCs than most of the above.
  let cTime = cClock;
  c.clock.now = () => (cTime += 2);
  body(c, "n1", "one\ntwo\nthree\nC was here");
  c.set({ title: "C's title", tags: ["offline"] }, "n1");
  c.set({ _deleted: false, color: "#0000ff" }, "st2", "stroke");
  c.set({ kind: "note", title: "From C", createdAt: 3 }, "n3", "item");
  body(c, "n3", "offline note");
  c.set({ title: "renamed by C", name: "Pantry" }, "c1", "collection");
  c.set({ on: "s1", layer: "", page: "p0", tool: "pen", color: "#000000", width: 2, points: "AAAgQQAAoEEAAAA_AAAAAA", createdAt: 9 }, "stC", "stroke");
  // A and B after the checkpoint.
  c.clock.now = now;
  for (const op of c.pending) { a.observe(op.h); b.observe(op.h); }
  body(a, "n2", "hello\nafter");
  a.set({ title: "After" }, "n2");
  b.set({ _deleted: true }, "l1", "item");
  b.set({ on: "s1", layer: "", page: "p0", tool: "marker", color: "#ff0000", width: 4, points: "AAAgQQAAoEEAAAA_AAAAAA", createdAt: 10 }, "stB", "stroke");
  const all = [...a.pending, ...b.pending, ...c.pending];
  const inCheckpoint = all.filter((op) => op.d !== "CCCC" && op.s <= checkpointed[op.d]);
  const rest = all.filter((op) => !inCheckpoint.includes(op));
  return { all, inCheckpoint, rest, rand };
}

/** Records as both cores compare them (fields, texts, conflicts and the first and last HLC). */
export function recordsView(store) {
  const out = {};
  for (const id of [...store.records.keys()].sort()) {
    const r = store.records.get(id);
    out[id] = { kind: r.kind, fields: r.fields, texts: r.texts, conflicts: r.conflicts, created: r.createdHLC, updated: r.updatedHLC };
  }
  return out;
}
