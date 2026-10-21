// Checkpoints (PROTOCOL.md §3 "Checkpoints"): the shared fixture, a fuzz against full replay, and the
// vault writing one, a new browser starting from it and keeping it locally.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { b64uDecode, b64uEncode } from "../public/core/bytes.js";
import * as cpm from "../public/core/checkpoint.js";
import { importVaultKeys } from "../public/core/keys.js";
import { RecordStore } from "../public/core/records.js";
import { Vault } from "../public/core/vault.js";
import { checkpointScenario, recordsView, rng } from "./checkpoint-scenario.mjs";
import { memoryStorage } from "./helpers.mjs";

test("Fixtures/checkpoint-cases.json loads, and later (and older offline) ops apply as a full replay does", async () => {
  const f = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/checkpoint-cases.json", import.meta.url), "utf8"));
  const full = new RecordStore();
  full.apply(f.ops);
  assert.deepEqual(recordsView(full), f.expected);
  for (const encoded of [f.deflated, f.plain]) assert.deepEqual(await cpm.decodeCheckpoint(b64uDecode(encoded)), f.checkpoint);
  const inside = new Set(f.inCheckpoint);
  const rest = f.ops.filter((op) => !inside.has(`${op.d}:${op.s}`));
  assert.equal(rest.length, f.restCount);
  for (const order of [rest, [...rest].reverse()]) {
    const s = new RecordStore();
    assert.ok(s.useBase(cpm.parseCheckpoint(structuredClone(f.checkpoint))));
    assert.deepEqual(recordsView(s), f.expectedAtCheckpoint);
    for (const op of order) s.apply([structuredClone(op)]);
    s.apply(f.ops.map((op) => structuredClone(op))); // everything again: covered or duplicates
    assert.deepEqual(recordsView(s), f.expected);
  }
});

test("any split by device prefixes, any arrival order, and a checkpoint of a checkpoint", () => {
  for (let seed = 1; seed <= 25; seed++) {
    const { all } = checkpointScenario(seed);
    const rand = rng(seed * 31);
    const full = new RecordStore();
    full.apply(all);
    const expected = recordsView(full);
    // Each device's first n ops are in the checkpoint (what one device had pulled at the time).
    const cut = {};
    for (const d of ["AAAA", "BBBB", "CCCC"]) cut[d] = Math.floor(rand() * (all.filter((op) => op.d === d).length + 1));
    const store = new RecordStore();
    store.apply(all.filter((op) => op.s <= cut[op.d]));
    const cp = JSON.parse(JSON.stringify(cpm.makeCheckpoint(store, {})));
    const s = new RecordStore();
    s.useBase(cpm.parseCheckpoint(cp));
    const rest = all.filter((op) => op.s > cut[op.d]).sort(() => rand() - 0.5);
    const half = Math.floor(rest.length / 2);
    for (const op of rest.slice(0, half)) s.apply([op]);
    const cp2 = JSON.parse(JSON.stringify(cpm.makeCheckpoint(s, {})));
    const s2 = new RecordStore();
    s2.useBase(cpm.parseCheckpoint(cp2));
    if (half > 0) assert.ok(!s2.useBase(cpm.parseCheckpoint(cp)), "an older checkpoint isn't taken over a newer one");
    for (const op of rest.slice(half)) { s.apply([op]); s2.apply([op]); }
    assert.deepEqual(recordsView(s), expected, `seed ${seed}`);
    assert.deepEqual(recordsView(s2), expected, `seed ${seed} (second checkpoint)`);
  }
});

/** A relay in memory: segments and checkpoints, enough for Vault.sync. */
function memoryRelay() {
  const segments = [], checkpoints = [], fetched = [];
  let now = 1_760_000_000_000;
  const fetch = async (url, init = {}) => {
    const u = new URL(url);
    const path = u.pathname.replace(/^\/v1\/vaults\/V\//, "");
    const method = init.method ?? "GET";
    const ok = (body, status = 200) => new Response(body instanceof Uint8Array ? body : JSON.stringify(body), { status });
    let m;
    if (path === "segments") {
      const after = Number(u.searchParams.get("after"));
      return ok({ segments: segments.filter((s) => s.cursor > after).map(({ body, ...s }) => s), more: false });
    }
    if ((m = /^segments\/([^/]+)\/(\d+)\/(\d+)$/.exec(path))) {
      if (method === "PUT") {
        const existing = segments.find((s) => s.device === m[1] && s.first === Number(m[2]));
        if (existing) return ok({ cursor: existing.cursor });
        segments.push({ cursor: segments.length + 1, device: m[1], first: Number(m[2]), last: Number(m[3]), size: init.body.length, body: init.body });
        return ok({ cursor: segments.length }, 201);
      }
      fetched.push(path);
      return ok(segments.find((s) => s.device === m[1] && s.first === Number(m[2])).body);
    }
    if (path === "checkpoints") return ok({ checkpoints: [...checkpoints].reverse().map(({ body, ...c }) => c) });
    if ((m = /^checkpoints\/(.+)$/.exec(path))) {
      if (method === "PUT") { checkpoints.push({ id: m[1], device: "x", size: init.body.length, createdAt: (now += 1000), body: init.body }); return ok({ id: m[1] }, 201); }
      const c = checkpoints.find((x) => x.id === m[1]);
      return c ? ok(c.body) : ok({ error: "no" }, 404);
    }
    if (path === "inbox") return ok({ entries: [] });
    return ok({});
  };
  return { fetch, segments, checkpoints, fetched };
}

test("the vault writes one after a sync; a new browser starts from it and keeps it locally", async () => {
  const relay = memoryRelay();
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  let t = 1_760_000_000_000;
  const make = (device, storage = memoryStorage()) => new Vault(storage, { deviceId: device, encrypted: true, base: "http://relay", vaultId: "V", token: "T" }, keys,
    { device }, [], [], [], 0, { now: () => (t += 1000), fetch: relay.fetch });
  const a = make("AAAA");
  for (let i = 0; i < 30; i++) { a.addNote({ title: `note ${i}`, body: `body ${i}` }); await a.sync(); }
  const sketch = a.addSketch({});
  a.addStroke({ on: sketch, page: "0", tool: "pen", color: "#000000", width: 2, points: [{ x: 1, y: 2, p: 0.5, t: 0 }, { x: 3, y: 4, p: 0.5, t: 8 }] });
  await a.sync();
  const report = { errors: [] };
  assert.equal(await a.maybeWriteCheckpoint(report, { force: true }), true, report.errors.join());
  assert.equal(relay.checkpoints.length, 1);
  assert.ok(a.store.base, "the writer uses its own checkpoint locally");
  assert.ok(!new TextDecoder().decode(relay.checkpoints[0].body).includes("note 1"), "the relay only sees ciphertext");
  // Not again straight away (one an hour at most, and the newest is less than a day old).
  assert.equal(await a.maybeWriteCheckpoint({ errors: [] }), false);
  a.addNote({ title: "after the checkpoint" });
  await a.sync();
  clearTimeout(a.saveTimer);

  // A new browser: the checkpoint plus the one segment after it, not 31 segments.
  const storageB = memoryStorage();
  const b = make("BBBB", storageB);
  const r = await b.sync();
  clearTimeout(b.saveTimer);
  assert.deepEqual(r.errors, []);
  assert.equal(r.checkpoint, relay.checkpoints[0].id);
  assert.equal(relay.fetched.length, 1, `fetched ${relay.fetched}`);
  const view = (v) => v.items().map((i) => [i.id, i.title, i.body]).sort();
  assert.deepEqual(view(b), view(a));
  assert.equal(b.strokes(sketch).length, 1);
  // Its local copy keeps the checkpoint: reopening needs no relay.
  await storageB.set("config", b.config);
  await storageB.set("keys", keys);
  const reopened = await Vault.open(storageB, { now: () => (t += 1000), fetch: async () => { throw new Error("offline"); } });
  assert.deepEqual(view(reopened), view(a));
  assert.equal(reopened.cursor, b.cursor);
  assert.ok(reopened.store.ops.length < 40, "the local copy holds the checkpoint, not every op");
  // Text history from before the checkpoint is still there (text ops travel inside it).
  assert.equal(reopened.textVersions(a.items().find((i) => i.title === "note 3").id).length, 1);

  // A browser that lost its copy but kept its journal number: new edits go after its ops in the checkpoint.
  const a2 = make("AAAA");
  await a2.sync();
  const before = a2.journal.state.nextSeq;
  assert.ok(before > 30, `next seq ${before}`);
});
