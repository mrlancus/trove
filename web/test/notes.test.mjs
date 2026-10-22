// Notes: placeholders, templates, the daily note and checklists (PROTOCOL.md §12), on the shared cases.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { itemView } from "../public/core/items.js";
import {
  allTemplates, checkboxCounts, checkboxes, dailyNote, dateParts, expandPlaceholders, fromTemplate, hasPlaceholders, templateName, toggleCheckbox,
  usesClipboard,
} from "../public/core/notes.js";

const f = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/notes-cases.json", import.meta.url)));
const view = (o) => itemView({
  id: o.id, updatedHLC: "1", conflicts: {}, texts: { body: o.body ?? "" },
  fields: Object.fromEntries(Object.entries({ kind: o.kind ?? "note", title: o.title, url: o.url, tags: o.tags, category: o.category ?? "note", createdAt: 1 })
    .filter(([, v]) => v !== undefined)),
});

test("notes: placeholders and template names", () => {
  for (const c of f.placeholders) {
    assert.equal(expandPlaceholders(c.text, f.parts[c.part], { clipboard: c.clipboard, title: c.title }), c.expect);
    assert.equal(hasPlaceholders(c.text), c.has);
  }
  for (const c of f.templateNames) assert.equal(templateName(c.title), c.expect);
  const p = dateParts(new Date(2026, 9, 21, 14, 5, 2));
  assert.deepEqual(p, { year: 2026, month: 10, day: 21, hour: 14, minute: 5, second: 2, weekday: 3 });
});

test("notes: templates and the daily note", () => {
  const items = f.items.map(view);
  const strip = (t) => ({ ...t, clipboard: usesClipboard(t), made: fromTemplate(t, f.parts[0], { clipboard: "clip" }) });
  assert.deepEqual(allTemplates(items).map(strip), f.templates);
  assert.deepEqual(allTemplates([]).map((t) => ({ ...t, clipboard: usesClipboard(t), made: fromTemplate(t, f.parts[0]) })), f.builtInTemplates);
  assert.deepEqual(dailyNote(items, f.parts[0]), f.daily);
  assert.deepEqual(dailyNote([...items].reverse(), f.parts[0]), f.daily); // another device, other order
  assert.deepEqual(dailyNote([], f.parts[1]), f.dailyBuiltIn);
});

test("notes: checklists", () => {
  for (const c of f.checklists) {
    assert.deepEqual(checkboxes(c.body), c.boxes);
    assert.deepEqual(checkboxCounts(c.body), c.counts);
    assert.deepEqual(c.boxes.map((_, i) => toggleCheckbox(c.body, i)), c.toggled);
    assert.equal(toggleCheckbox(c.body, c.boxes.length), c.outOfRange);
    for (const [i, t] of c.toggled.entries()) assert.equal(checkboxes(t)[i].done, !c.boxes[i].done);
  }
});
