// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/search-cases.json: a fixed set of items,
// folders and clips, queries and the order the website's search (core/search.js) returns them in.
// SearchIndexTests.swift and core.test.mjs both check against it. Run: node test/make-search-fixture.mjs
import { writeFileSync } from "node:fs";
import { clipView } from "../public/core/clips.js";
import { itemView } from "../public/core/items.js";
import { CLIP_FIELDS, clipDoc, clipFilter, clipIndexQuery, folderMap, ITEM_FIELDS, itemDoc, parseQuery, rrf, TermIndex } from "../public/core/search.js";
import { parseClipQuery } from "../public/core/clips.js";

const day = (s) => Date.parse(s + "T12:00:00Z");
const now = day("2026-06-01");

const folders = [
  { id: "f-home", name: "Home", parent: null },
  { id: "f-garden", name: "Garden", parent: "f-home" },
  { id: "f-cook", name: "Cooking", parent: "f-home" },
  { id: "f-travel", name: "Travel", parent: null },
  { id: "f-work", name: "Work notes", parent: null },
];

const long = "Discussed the garden budget for next spring and who looks after the compost. " +
  "Then a long aside about fonts, colours and the new logo that nobody could agree on, until someone said the exact words that matter: " +
  "the quick brown fox. After that we went back to the budget and the meeting ran over by twenty minutes.";

const items = [
  { id: "r1", fields: { title: "Miso ramen recipe", tags: ["food", "japan"], kind: "link", category: "recipe", url: "https://cooking.example.com/miso", createdAt: day("2025-03-10"), folder: "f-cook" },
    body: "Rich broth with miso paste and noodles." },
  { id: "n1", fields: { title: "Trip notes", kind: "note", category: "note", createdAt: day("2025-04-02"), collections: ["c-travel"], folder: "f-travel" },
    body: "We had ramen in Tokyo. The best bowl was near the station." },
  { id: "p1", fields: { title: "Desk lamp", kind: "link", category: "product", pinned: true, url: "https://shop.example.com/lamp", createdAt: day("2025-01-05") }, body: "" },
  { id: "s1", fields: { title: "Garden plan", kind: "sketch", inkText: "tomatoes beans compost bin", sketchText: "north fence", createdAt: day("2025-05-20"), folder: "f-garden" }, body: "" },
  { id: "pdf1", fields: { title: "Tax return 2024", kind: "pdf", source: "import", createdAt: day("2025-02-14"),
    ocrText: "Total income for the year. Deductions: charitable donations and pension contributions.",
    attachments: [{ id: "att1", name: "tax.pdf", mime: "application/pdf", size: 1000 }] }, body: "" },
  { id: "a1", fields: { title: "Voice memo", kind: "audio", source: "voice", createdAt: day("2025-06-01"),
    attachments: [{ id: "att2", name: "memo.m4a", mime: "audio/mp4", size: 2000 }] }, body: "Remember to call the plumber about the leaking tap" },
  { id: "g1", fields: { title: "Lecture 5 notebook", kind: "file", createdAt: day("2025-03-30"), inkText: "photosynthesis converts light energy",
    attachments: [{ id: "att3", name: "Biology.goodnotes", mime: "application/octet-stream", size: 3000 }] }, body: "" },
  { id: "e1", fields: { title: "Your order has shipped", kind: "email", source: "email", createdAt: day("2025-05-01"), readAt: day("2025-05-02") },
    body: "Order 4471: the recipe book and the ramen bowls are on the way" },
  { id: "h1", fields: { title: "Thinking, Fast and Slow", kind: "highlight", source: "kindle", category: "quote", createdAt: day("2024-12-01") },
    body: "> Nothing in life is as important as you think it is, while you are thinking about it." },
  { id: "n2", fields: { title: "Recipe ideas", kind: "note", tags: ["food"], createdAt: day("2025-07-07") }, body: "Quick weeknight dinners: pasta, stir fry, curry" },
  { id: "n3", fields: { title: "Meeting notes", kind: "note", createdAt: day("2025-08-08"), folder: "f-work" }, body: long },
  { id: "l2", fields: { title: "Brown fox facts", kind: "link", url: "https://facts.example.org/fox", createdAt: day("2025-08-09") }, body: "A fox that is quick and brown" },
];

const queries = [
  "ramen", "ram", "ramen -tokyo", "recipie", "recipe", "\"quick brown fox\"", "quick brown fox", "title:fox", "title:recipe", "title:\"recipe ideas\"",
  "in:garden", "in:home", "in:c-travel", "in:\"work notes\"", "in:f-cook", "type:pdf", "type:sketch", "type:note fox", "from:kindle", "from:goodnotes",
  "has:ink", "has:audio", "has:file", "has:link", "before:2025-02", "after:2025-08", "after:2025 before:2025-03", "before:2025-01-05", "#food", "tag:japan",
  "is:unread type:email", "is:pinned", "tomatoes", "photosyntesis", "donation", "plumbr", "lamp", "garden", "garden -compost", "-ramen #food",
  "brown -\"quick brown fox\"", "fox title:brown", "", "zzzz", "budget meeting", "bowl", "4471", "Café", "the", "fo",
];

const snippetCases = [
  ["n1", "ramen"], ["s1", "compost"], ["pdf1", "charitable donation"], ["n3", "fox"], ["n3", "\"quick brown fox\""], ["a1", "plumbr"], ["e1", "rec"], ["g1", "light"],
];

const clips = [
  { id: "c1", fields: { title: "Deploy command", text: "ssh deploy@10.0.0.4", sourceApp: "Terminal", createdAt: day("2025-09-01") } },
  { id: "c2", fields: { title: "Meeting", text: "Meeting at 3pm with Dana", sourceApp: "Slack", tags: ["work"], createdAt: day("2025-09-02") } },
  { id: "c3", fields: { title: "Pricing page", text: "https://example.com/pricing", sourceApp: "Safari", createdAt: day("2025-09-03") } },
  { id: "c4", fields: { title: "Carbonara", text: "Pasta carbonara recipe with eggs", pinned: true, createdAt: day("2025-09-04") } },
  { id: "c5", fields: { title: "Dinner plans", text: "Pasta at Dana's on Friday", sourceApp: "Messages", createdAt: day("2025-09-05") } },
];
const clipQueries = ["deplo", "meet dana", "app:slack", "#work", "is:pinned", "recipes", "pasta", "pasta dan", "examp", "dana -friday"];

const record = (o) => ({ id: o.id, kind: "item", fields: o.fields, texts: { body: o.body ?? "" }, conflicts: {}, updatedHLC: "x" });
const index = new TermIndex(ITEM_FIELDS);
for (const o of items) index.update(itemDoc(itemView(record(o))));
const fm = folderMap(folders);
const cases = queries.map((query) => ({ query, ids: index.search(parseQuery(query), { now, folders: fm }).hits.map((h) => h.id) }));
const snippets = snippetCases.map(([id, query]) => {
  const { plan } = index.search(parseQuery(query), { now, folders: fm });
  const s = index.snippet(id, plan);
  return { id, query, field: s?.field ?? null, text: s?.text ?? null, highlights: s ? s.ranges.map(([a, b]) => s.text.slice(a, b)) : [] };
});

const clipIndex = new TermIndex(CLIP_FIELDS);
for (const o of clips) clipIndex.update(clipDoc(clipView({ id: o.id, kind: "clip", fields: o.fields, texts: {}, conflicts: {}, updatedHLC: "x" })));
const clipCases = clipQueries.map((query) => {
  const cq = parseClipQuery(query);
  return { query, ids: clipIndex.search(clipIndexQuery(cq), { now, prefixAll: true, filter: clipFilter(cq) }).hits.map((h) => h.id) };
});

const rrfCases = [
  { lists: [["a", "b", "c"], ["c", "d", "a"]] },
  { lists: [["x"], [], ["y", "x"]] },
  { lists: [["a", "b"], ["b", "a"]] },
].map((c) => ({ ...c, ids: rrf(c.lists) }));

const out = { now, folders, items, cases, snippets, clips, clipCases, rrf: rrfCases };
const path = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/search-cases.json", import.meta.url);
writeFileSync(path, JSON.stringify(out, null, 1) + "\n");
console.log(JSON.stringify({ cases, snippets, clipCases, rrf: rrfCases }, null, 0).replace(/\},\{/g, "},\n{"));
