// Search: the shared cases (search-cases.json, also checked by SearchIndexTests.swift), the Worker's
// service (diffs, saving encrypted, loading), typo matching, top-k and search by meaning plumbing.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { clipView, parseClipQuery } from "../public/core/clips.js";
import { itemView, search } from "../public/core/items.js";
import { CLIP_FIELDS, clipDoc, clipFilter, clipIndexQuery, folderMap, ITEM_FIELDS, itemDoc, parseQuery, rrf, snippet, TermIndex, topK, withinOneEdit }
  from "../public/core/search.js";
import { memoryStorage, parseClipQueryLite, SearchService } from "../public/core/searchservice.js";

const fixture = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/search-cases.json", import.meta.url), "utf8"));
const record = (o, kind = "item") => ({ id: o.id, kind, fields: o.fields, texts: { body: o.body ?? "" }, conflicts: {}, updatedHLC: "x" });

test("search-cases.json: queries, snippets, clips and rank fusion", () => {
  const index = new TermIndex(ITEM_FIELDS);
  for (const o of fixture.items) index.update(itemDoc(itemView(record(o))));
  const folders = folderMap(fixture.folders);
  assert.ok(fixture.cases.length >= 40);
  for (const c of fixture.cases) {
    assert.deepEqual(index.search(parseQuery(c.query), { now: fixture.now, folders }).hits.map((h) => h.id), c.ids, c.query);
  }
  for (const c of fixture.snippets) {
    const { plan } = index.search(parseQuery(c.query), { now: fixture.now, folders });
    const s = index.snippet(c.id, plan);
    assert.equal(s?.field ?? null, c.field, c.query);
    assert.equal(s?.text ?? null, c.text, c.query);
    assert.deepEqual(s ? s.ranges.map(([a, b]) => s.text.slice(a, b)) : [], c.highlights, c.query);
  }
  const clips = new TermIndex(CLIP_FIELDS);
  for (const o of fixture.clips) clips.update(clipDoc(clipView(record(o, "clip"))));
  for (const c of fixture.clipCases) {
    const cq = parseClipQuery(c.query);
    assert.deepEqual(clips.search(clipIndexQuery(cq), { now: fixture.now, prefixAll: true, filter: clipFilter(cq) }).hits.map((h) => h.id), c.ids, c.query);
    assert.deepEqual(parseClipQueryLite(c.query), cq);
  }
  for (const c of fixture.rrf) assert.deepEqual(rrf(c.lists), c.ids);
});

test("query parsing: phrases, quoted values, excludes, dates", () => {
  const q = parseQuery('"exact words" title:"Recipe ideas" in:"Work notes" -tokyo -"bad phrase" has:ink has:nope before:2026-01 after:2025 type:sketch #Food plain');
  assert.deepEqual(q.phrases, [["exact", "word"]]);
  assert.deepEqual(q.title, ["recipe", "idea"]);
  assert.equal(q.collection, "Work notes");
  assert.deepEqual(q.exclude, ["tokyo"]);
  assert.deepEqual(q.excludePhrases, [["bad", "phrase"]]);
  assert.deepEqual(q.has, ["ink"]);
  assert.equal(q.before, Date.UTC(2026, 0, 1));
  assert.equal(q.after, Date.UTC(2025, 0, 1));
  assert.deepEqual(q.kinds, ["sketch"]);
  assert.deepEqual(q.tags, ["food"]);
  assert.equal(q.text, "has:nope plain");
  assert.equal(parseQuery("before:2026-13").before, null);
});

test("one edit away, top-k and snippets", () => {
  assert.ok(withinOneEdit("recipie", "recipe"));
  assert.ok(withinOneEdit("recpie", "recipe"));   // swapped neighbours
  assert.ok(withinOneEdit("recipa", "recipe"));
  assert.ok(withinOneEdit("recipe", "recipes"));
  assert.ok(!withinOneEdit("recpies", "recipe"));
  assert.ok(!withinOneEdit("abcdef", "abcfed"));
  const nums = Array.from({ length: 5000 }, (_, i) => ({ id: String(i), score: (i * 7919) % 1000, createdAt: i }));
  const cmp = (a, b) => b.score - a.score || b.createdAt - a.createdAt;
  assert.deepEqual(topK([...nums], 50, cmp), [...nums].sort(cmp).slice(0, 50));
  const s = snippet("Line one.\n\n   The   ramen\tbar was great", new Set(["ramen"]));
  assert.equal(s.text, "Line one. The ramen bar was great");
  assert.deepEqual(s.ranges.map(([a, b]) => s.text.slice(a, b)), ["ramen"]);
  assert.equal(snippet("nothing here", new Set(["ramen"])), null);
});

test("search() keeps working for callers on this thread, folders included", () => {
  const items = fixture.items.map((o) => itemView(record(o)));
  assert.deepEqual(search(items, "in:garden", fixture.now, { folders: fixture.folders }).map((i) => i.id), ["s1"]);
  assert.deepEqual(search(items.filter((i) => i.id !== "r1"), "ramen", fixture.now).map((i) => i.id), ["e1", "n1"]);
});

const docsFor = () => fixture.items.map((o) => itemDoc(itemView(record(o))));

test("search service: diffs, snippets, clips, and an encrypted saved index", async () => {
  const storage = memoryStorage();
  const a = new SearchService({ storage, saveDelay: 10_000 });
  assert.deepEqual(await a.init("V1"), { items: [], clips: [] });
  a.apply({ docs: docsFor(), folders: fixture.folders });
  a.apply({ index: "clips", docs: fixture.clips.map((o) => clipDoc(clipView(record(o, "clip")))) });
  let r = await a.query({ text: "ramen", now: fixture.now, clips: true });
  assert.deepEqual(r.items.ids, ["r1", "e1", "n1"]);
  assert.equal(r.items.total, 3);
  assert.equal(r.items.snippets.n1.text, "We had ramen in Tokyo. The best bowl was near the station.");
  r = await a.query({ text: "pasta", now: fixture.now, clips: true });
  assert.deepEqual(r.clips.ids, ["c4", "c5"]);
  a.setScope("notes", ["n1", "n2"]);
  assert.deepEqual((await a.query({ text: "ramen", scope: "notes", now: fixture.now })).items.ids, ["n1"]);
  a.apply({ removed: ["n1"] });
  assert.deepEqual((await a.query({ text: "ramen", now: fixture.now })).items.ids, ["r1", "e1"]);
  assert.equal(await a.save(), true);
  assert.equal(await a.save(), false); // nothing changed since

  // Stored encrypted: no words from the vault in what's kept, and the key is a non-extractable CryptoKey.
  const saved = storage.map.get("index:V1");
  assert.ok(!Buffer.from(saved.data).toString("latin1").includes("ramen"));
  const key = storage.map.get("key");
  assert.equal(key.extractable, false);
  await assert.rejects(crypto.subtle.exportKey("raw", key));

  // A new page loads it in one read: same answers, nothing re-sent.
  const b = new SearchService({ storage });
  const versions = await b.init("V1");
  assert.equal(versions.items.length, fixture.items.length - 1);
  assert.equal(versions.clips.length, fixture.clips.length);
  assert.deepEqual((await b.query({ text: "ramen", now: fixture.now })).items.ids, ["r1", "e1"]);
  assert.deepEqual((await b.query({ text: "in:garden", now: fixture.now })).items.ids, ["s1"]);
  // Another vault on this browser starts empty; a broken record starts again.
  assert.deepEqual(await new SearchService({ storage }).init("V2"), { items: [], clips: [] });
  storage.map.set("index:V1", { iv: new Uint8Array(12), data: new Uint8Array(40) });
  assert.deepEqual(await new SearchService({ storage }).init("V1"), { items: [], clips: [] });
});

test("search by meaning: vectors, rank fusion with keywords, saved with the index", async () => {
  // A stand-in model: words → a few fixed directions.
  const topics = { food: ["ramen", "recipe", "miso", "pasta", "dinner", "noodle", "broth", "meal"], garden: ["garden", "compost", "tomatoes", "fence", "beans"] };
  const embedder = {
    calls: 0,
    async embed(texts) {
      this.calls++;
      return texts.map((t) => {
        const w = t.toLowerCase();
        return Float32Array.from([...Object.values(topics).map((list) => list.filter((x) => w.includes(x)).length), 0.1]);
      });
    },
  };
  const storage = memoryStorage();
  const s = new SearchService({ storage, embedder, saveDelay: 10_000 });
  await s.init("V1");
  s.apply({ docs: docsFor() });
  while (await s.embedPending(5)) { /* in batches */ }
  assert.equal(s.vectors.size, fixture.items.length);
  const meaning = await s.meaning("meal");
  assert.ok(meaning.length >= 3 && meaning.slice(0, 3).every(([id]) => ["r1", "n2", "e1", "n1"].includes(id)));
  // "meal" isn't a word in any item: keywords find nothing, meaning finds the food.
  const r = await s.query({ text: "meal", now: fixture.now, semantic: true });
  assert.ok(r.items.ids.includes("r1") && r.items.ids.includes("n2"));
  assert.ok(!r.items.ids.includes("s1"));
  // Filters still apply to what meaning found.
  assert.deepEqual((await s.query({ text: "meal type:link", now: fixture.now, semantic: true })).items.ids, ["r1"]);
  await s.save();
  const t = new SearchService({ storage, embedder });
  await t.init("V1");
  assert.equal(t.vectors.size, fixture.items.length);
  const calls = embedder.calls;
  assert.equal(await t.embedPending(), 0);
  assert.equal(embedder.calls, calls);
});
