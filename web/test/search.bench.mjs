// Search speed at 50,000 items and 50,000 clips (ROADMAP Q1, §3.5): each keystroke of a few typed
// queries, timed the way the search Worker runs them (search + snippets for the first page).
// Run: node --test test/search.bench.mjs   (BENCH_ITEMS / BENCH_CLIPS change the sizes)
import assert from "node:assert/strict";
import { test } from "node:test";
import { SearchService } from "../public/core/searchservice.js";

const ITEMS = Number(process.env.BENCH_ITEMS ?? 50_000), CLIPS = Number(process.env.BENCH_CLIPS ?? 50_000);
const BOUND_MS = Number(process.env.BENCH_BOUND_MS ?? 50); // generous, for slow shared CI machines

// A deterministic vocabulary with a long tail, like real notes: a few common words, many rare ones.
let seed = 42;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const syllables = ["ra", "me", "no", "ti", "ka", "lo", "su", "ve", "pi", "do", "an", "er", "is", "ou", "tr", "st", "ch", "pl", "gr", "en"];
const vocab = Array.from({ length: 20_000 }, () => Array.from({ length: 2 + Math.floor(rand() * 3) }, () => syllables[Math.floor(rand() * syllables.length)]).join(""));
vocab.push("recipe", "ramen", "garden", "invoice", "meeting", "photosynthesis");
const word = () => vocab[Math.floor(vocab.length * rand() ** 2.5)];
const words = (n) => Array.from({ length: n }, word).join(" ");

function makeDocs() {
  const items = [], clips = [];
  const day = 86_400_000, start = Date.UTC(2020, 0, 1);
  for (let i = 0; i < ITEMS; i++) {
    const kind = ["note", "link", "pdf", "sketch", "image"][i % 5];
    const body = words(40 + Math.floor(rand() * 80)) + (i % 97 === 0 ? " a great ramen recipe" : "");
    items.push({ id: `i${i}`, v: "1",
      fields: { title: words(4), tags: i % 7 === 0 ? "food" : "", summary: "", site: "", body, ocr: kind === "pdf" ? words(60) : "", sketch: "", ink: kind === "sketch" ? words(10) : "", host: "" },
      meta: { kind, category: "other", tags: i % 7 === 0 ? ["food"] : [], sources: ["app"], collections: [], folder: null, pinned: i % 500 === 0, unread: true,
        createdAt: start + (i % 2000) * day, has: kind === "sketch" ? ["ink"] : [] } });
  }
  for (let i = 0; i < CLIPS; i++) {
    clips.push({ id: `c${i}`, v: "1", fields: { title: words(3), tags: "", text: words(8 + Math.floor(rand() * 20)), note: "", summary: "", ocr: "", source: "Safari" },
      meta: { tags: [], app: "safari", pinned: false, createdAt: start + i * 60_000 } });
  }
  return { items, clips };
}

test(`a keystroke's search at ${ITEMS} items + ${CLIPS} clips stays under ${BOUND_MS} ms`, async () => {
  const { items, clips } = makeDocs();
  const service = new SearchService();
  await service.init("bench");
  let t = performance.now();
  service.apply({ docs: items });
  service.apply({ index: "clips", docs: clips });
  const buildMs = performance.now() - t;

  const typed = (s) => Array.from({ length: s.length }, (_, i) => s.slice(0, i + 1)).filter((x) => x.trim());
  const sessions = [typed("ramen recipe"), typed("photosyntesis"), typed('"ramen recipe"'), typed("garden type:sketch"), typed("meeting -invoice"), ["has:ink"], ["before:2021-03"], ["#food"]];
  const times = [];
  const now = Date.UTC(2026, 0, 1);
  for (const keys of sessions) {
    for (const text of keys) {
      t = performance.now();
      await service.query({ text, now, clips: true, limit: 400, snippets: 60 });
      times.push([performance.now() - t, text]);
    }
  }
  times.sort((a, b) => a[0] - b[0]);
  const ms = times.map(([x]) => x);
  const pct = (p) => ms[Math.min(ms.length - 1, Math.floor(ms.length * p))];
  const slowest = times.slice(-3).map(([x, q]) => `${q.trim()} ${x.toFixed(1)}`).join(", ");
  const report = `index ${ITEMS}+${CLIPS}: built in ${buildMs.toFixed(0)} ms; per keystroke (${ms.length}): median ${pct(0.5).toFixed(2)} ms, ` +
    `p90 ${pct(0.9).toFixed(2)} ms, max ${ms.at(-1).toFixed(2)} ms (slowest: ${slowest})`;
  console.log(report);
  const r = await service.query({ text: "ramen recipe", now });
  assert.ok(r.items.total >= Math.floor(ITEMS / 97));
  assert.ok(pct(0.5) < BOUND_MS, report);
  assert.ok(pct(0.9) < BOUND_MS * 3, report);
});
