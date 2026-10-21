// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/digest-cases.json from the web core, for
// Digest.swift to match. Run after changing digest.js on purpose: `node test/make-digest-fixture.mjs`.
import { writeFileSync } from "node:fs";
import { digestId, isoWeek, onThisDay, possibleDuplicates, weeklyDigest, weekStart } from "../public/core/digest.js";
import { itemView } from "../public/core/items.js";

const at = (iso) => Date.parse(iso);
const items = [
  { id: "n1", kind: "note", title: "Garden plan", createdAt: at("2026-10-19T08:00:00Z") },
  { id: "s1", kind: "sketch", title: "Bike sketch", createdAt: at("2026-10-24T10:00:00Z") },
  { id: "l1", kind: "link", title: "How to Make Sourdough Bread at Home", url: "https://www.example.com/sourdough?utm_source=x", createdAt: at("2026-10-20T09:00:00Z") },
  { id: "l2", kind: "link", title: "How to make sourdough bread at home", url: "https://example.com/sourdough", createdAt: at("2026-10-21T09:00:00Z"), readAt: at("2026-10-21T10:00:00Z") },
  { id: "l3", kind: "link", title: "How to make sourdough bread at home", url: "https://bakery.example.org/recipes/sourdough", createdAt: at("2026-10-22T09:00:00Z") },
  { id: "l4", kind: "link", title: "Rust ownership explained clearly", url: "https://blog.dev/rust-ownership", createdAt: at("2026-10-05T09:00:00Z") },
  { id: "l5", kind: "link", title: "Rust ownership explained, clearly!", url: "https://blog.dev/posts/rust-ownership-2", createdAt: at("2026-10-06T09:00:00Z") },
  { id: "l6", kind: "link", title: "Café menus of Paris", url: "https://paris.example/cafes", createdAt: at("2026-09-30T09:00:00Z") },
  { id: "l7", kind: "link", title: "Cafe menus of Paris", url: "https://paris.example/cafes-2", createdAt: at("2026-10-01T09:00:00Z"), notDuplicates: ["l6"] },
  { id: "l9", kind: "link", title: "Best hiking trails in Wales guide", url: "https://walks.example/wales", createdAt: at("2026-07-01T09:00:00Z"), readAt: at("2026-07-01T09:00:00Z") },
  { id: "l10", kind: "link", title: "Best hiking trails in Wales: full guide", url: "https://walks.example/wales-full", createdAt: at("2026-07-02T09:00:00Z"), readAt: at("2026-07-02T09:00:00Z") },
  { id: "l8", kind: "link", title: "Old unread link", url: "https://old.example/a", createdAt: at("2026-08-01T09:00:00Z") },
  { id: "p1", kind: "pdf", title: "Tax return", createdAt: at("2026-10-25T23:59:59Z") },
  { id: "y1", kind: "note", title: "Holiday [ideas] | list", createdAt: at("2025-10-21T12:00:00Z") },
  { id: "y2", kind: "link", title: "Conference talk", url: "https://talks.example/1", createdAt: at("2024-10-21T12:00:00Z"), readAt: at("2024-10-22T12:00:00Z") },
  { id: "digest-2026-w42", kind: "note", title: "Week of 12 October 2026", createdAt: at("2026-10-19T00:00:01Z"), digest: { year: 2026, week: 42 } },
  { id: "n2", kind: "note", title: "Next week", createdAt: at("2026-10-26T00:00:00Z") },
];

const view = (o) => itemView({
  id: o.id, updatedHLC: "1", conflicts: {}, texts: { body: o.body ?? "" },
  fields: Object.fromEntries(Object.entries({ kind: o.kind, title: o.title, url: o.url, createdAt: o.createdAt, readAt: o.readAt, notDuplicates: o.notDuplicates, digest: o.digest })
    .filter(([, v]) => v !== undefined)),
});
const views = items.map(view);

const fixture = {
  weeks: ["2026-10-19T00:00:00Z", "2026-10-25T23:59:59Z", "2021-01-03T12:00:00Z", "2021-01-04T00:00:00Z", "2024-12-30T00:00:00Z", "2026-01-01T00:00:00Z"]
    .map((iso) => ({ at: at(iso), ...isoWeek(at(iso)), start: weekStart(isoWeek(at(iso)).year, isoWeek(at(iso)).week), id: digestId(isoWeek(at(iso)).year, isoWeek(at(iso)).week) })),
  items,
  digest: { year: 2026, week: 43, expect: weeklyDigest(views, 2026, 43) },
  quietDigest: { year: 2026, week: 30, expect: weeklyDigest(views, 2026, 30) },
  onThisDay: { at: at("2026-10-21T08:00:00Z"), expect: onThisDay(views, at("2026-10-21T08:00:00Z")).map((i) => i.id) },
  duplicates: possibleDuplicates(views),
};
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/digest-cases.json", import.meta.url), JSON.stringify(fixture, null, 2) + "\n");
console.log(JSON.stringify(fixture.digest.expect, null, 2), fixture.quietDigest.expect.body, fixture.onThisDay.expect, JSON.stringify(fixture.duplicates));
