// Ask Trove retrieval, the weekly digest, duplicates and link suggestions (ROADMAP §4 A1-A3).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { answerNote, askSources, bestPassage, questionTerms, rankForQuestion } from "../public/core/ask.js";
import { digestId, isoWeek, onThisDay, possibleDuplicates, previousWeek, weeklyDigest, weekStart } from "../public/core/digest.js";
import { itemView } from "../public/core/items.js";
import { wikilinks } from "../public/core/links.js";
import { suggestLinks } from "../public/core/suggest.js";

const fixture = (name) => JSON.parse(readFileSync(new URL(`../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/${name}.json`, import.meta.url)));
let hlc = 0;
const item = (o) => itemView({
  id: o.id, updatedHLC: String(++hlc), conflicts: {}, texts: { body: o.body ?? "" },
  fields: Object.fromEntries(Object.entries({ kind: o.kind ?? "note", title: o.title, url: o.url, createdAt: o.createdAt ?? 1, readAt: o.readAt,
    tags: o.tags, links: o.links, notDuplicates: o.notDuplicates, digest: o.digest, summary: o.summary }).filter(([, v]) => v !== undefined)),
});

test("digest: ISO weeks, ids and the shared cases", () => {
  const f = fixture("digest-cases");
  for (const w of f.weeks) {
    assert.deepEqual(isoWeek(w.at), { year: w.year, week: w.week });
    assert.equal(weekStart(w.year, w.week), w.start);
    assert.equal(digestId(w.year, w.week), w.id);
  }
  const items = f.items.map(item);
  assert.deepEqual(weeklyDigest(items, f.digest.year, f.digest.week), f.digest.expect);
  assert.deepEqual(weeklyDigest(items, f.quietDigest.year, f.quietDigest.week), f.quietDigest.expect);
  assert.deepEqual(onThisDay(items, f.onThisDay.at).map((i) => i.id), f.onThisDay.expect);
  assert.deepEqual(possibleDuplicates(items), f.duplicates);
});

test("digest: the same on every device, links resolve, AI summary labelled", () => {
  const f = fixture("digest-cases");
  const a = weeklyDigest(f.items.map(item), 2026, 43);
  const b = weeklyDigest([...f.items].reverse().map(item), 2026, 43); // another device, other order
  assert.equal(a.id, "digest-2026-w43");
  assert.deepEqual(a, b);
  assert.ok(wikilinks(a.body).includes("Holiday ideas list")); // brackets taken out of titles
  assert.ok(!a.body.includes("Week of 12 October")); // other digests aren't listed
  assert.ok(!a.body.includes("Next week"));
  const ai = weeklyDigest(f.items.map(item), 2026, 43, { summary: "Mostly bread.", model: "claude-haiku-5-5" });
  assert.match(ai.body, /## In short\nMostly bread\.\n\n_Processed in the cloud \(claude-haiku-5-5\)\._/);
  assert.deepEqual(previousWeek(Date.parse("2026-10-21T00:00:00Z")), { year: 2026, week: 42 });
});

test("duplicates: a 'not a duplicate' answer sticks", () => {
  const items = [
    item({ id: "a", kind: "link", title: "x", url: "https://e.com/p?utm_source=1", createdAt: 1 }),
    item({ id: "b", kind: "link", title: "y", url: "https://e.com/p", createdAt: 2, notDuplicates: ["a"] }),
    item({ id: "n", kind: "note", title: "x", createdAt: 3 }),
  ];
  assert.deepEqual(possibleDuplicates(items), []);
  assert.deepEqual(possibleDuplicates(items.slice(0, 1).concat(item({ id: "c", kind: "link", title: "z", url: "http://www.e.com/p/", createdAt: 5 }))),
    [{ reason: "same link", ids: ["a", "c"] }]);
});

test("ask: chatty questions still find things, best passage first, within limits", () => {
  assert.deepEqual(questionTerms("What did I save about sourdough starters?"), ["sourdough", "starter"]);
  const filler = "Unrelated words about the weather and trains. ".repeat(80);
  const items = [
    item({ id: "bread", title: "Bread notes", body: `${filler}\nFeed the sourdough starter twice a day with rye flour.\n${filler}`, createdAt: 10 }),
    item({ id: "starter", title: "Starter motor repair", body: "Car starter motor fix.", createdAt: 20 }),
    item({ id: "both", title: "Sourdough starter guide", body: "Everything about a sourdough starter.", createdAt: 5 }),
    item({ id: "none", title: "Gardening", body: "Tomatoes", createdAt: 30 }),
  ];
  const ranked = rankForQuestion(items, "What did I save about sourdough starters?");
  assert.equal(ranked[0].id, "both"); // all words beat some words
  assert.deepEqual(new Set(ranked.map((i) => i.id)), new Set(["both", "bread", "starter"]));
  assert.deepEqual(rankForQuestion(items, "what did I save?"), []);

  const sources = askSources(items, "sourdough starter feeding", { snippetChars: 300 });
  const bread = sources.find((s) => s.id === "bread");
  assert.ok(bread.text.startsWith("Title: Bread notes\n"));
  assert.match(bread.text, /Feed the sourdough starter twice a day/);
  assert.ok(sources.every((s) => s.text.length <= 300));
  const many = Array.from({ length: 40 }, (_, i) => item({ id: `n${i}`, title: `Sourdough ${i}`, body: "sourdough ".repeat(500), createdAt: i }));
  const capped = askSources(many, "sourdough", { totalChars: 5000 });
  assert.ok(capped.length <= 20 && capped.length > 0);
  assert.ok(capped.reduce((n, s) => n + s.text.length, 0) <= 5000);
  assert.equal(askSources(many, "sourdough").length, 20);

  assert.equal(bestPassage("short", ["x"], 100), "short");
});

test("ask: an answer saves as a note with [[links]] and says where it ran", () => {
  const cited = [item({ id: "a", title: "Bread [notes]" }), item({ id: "b", title: "Rye" })];
  const note = answerNote("How often do I feed my starter?", "Twice a day.", cited, { model: "claude-haiku-5-5" });
  assert.equal(note.title, "How often do I feed my starter?");
  assert.deepEqual(wikilinks(note.body), ["Bread notes", "Rye"]);
  assert.match(note.body, /processed in the cloud, claude-haiku-5-5/);
});

test("suggest links: named titles and shared topics, never what's already linked", () => {
  const items = [
    item({ id: "me", title: "Trip to Lisbon", body: "Ideas for Lisbon: pastel de nata, trams, and the Alfama walk. See [[Packing list]].", tags: ["travel"], createdAt: 1 }),
    item({ id: "walk", title: "Alfama walk", body: "A walking route", createdAt: 2 }),
    item({ id: "nata", title: "Pastel de nata recipe", body: "Custard tarts from Lisbon", createdAt: 3 }),
    item({ id: "pack", title: "Packing list", body: "Socks", createdAt: 4 }),
    item({ id: "hand", title: "Lisbon hotels", body: "Lisbon stays", links: ["me"], createdAt: 5 }),
    item({ id: "tag", title: "Rome", body: "Pasta", tags: ["travel"], createdAt: 6 }),
    item({ id: "off", title: "Tax return", body: "Numbers", createdAt: 7 }),
  ];
  const got = suggestLinks(items[0], items);
  const ids = got.map((s) => s.item.id);
  assert.equal(ids[0], "walk");
  assert.equal(got[0].reason, "Named in this note");
  assert.ok(ids.includes("nata"));
  for (const no of ["me", "pack", "hand", "off"]) assert.ok(!ids.includes(no), no);
});
