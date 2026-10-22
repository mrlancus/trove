// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/notes-cases.json: placeholders, templates,
// the daily note and checklists (core/notes.js), checked by web/test/notes.test.mjs and NotesTests.swift.
// Run after changing notes.js on purpose: `node test/make-notes-fixture.mjs`.
import { writeFileSync } from "node:fs";
import { itemView } from "../public/core/items.js";
import {
  allTemplates, checkboxCounts, checkboxes, dailyNote, expandPlaceholders, fromTemplate, hasPlaceholders, templateName, toggleCheckbox,
  usesClipboard,
} from "../public/core/notes.js";

const parts = [
  { year: 2026, month: 10, day: 21, hour: 14, minute: 5, second: 2, weekday: 3 },
  { year: 2027, month: 1, day: 3, hour: 0, minute: 0, second: 0, weekday: 0 },
  { year: 999, month: 12, day: 31, hour: 23, minute: 59, second: 59, weekday: 6 },
];
const texts = [
  "Today is {longdate} ({weekday}), {date} at {time}; {datetime}. {day} {month} {year}.",
  "From the clipboard: {clipboard}. Title: {title}.",
  "Unknown {stays}, {Date} stays, {} and { date } stay, {{date}} half, {date",
  "No placeholders here",
];
const items = [
  { id: "t1", title: "Meeting {date}", body: "Who: \n- [ ] {title}", tags: ["template", "work"] },
  { id: "t2", title: "Daily note", body: "## Today\n- [ ] Water plants\n- [ ] {weekday} things", tags: ["template", "mine"] },
  { id: "t3", title: "  {date}  ", body: "Just a date", tags: ["template"] },
  { id: "t4", title: "bread", body: "Flour", tags: ["template"], category: "recipe" },
  { id: "daily-2026-10-20", title: "Tuesday 20 October 2026", body: "x", tags: ["daily", "template"] },
  { id: "n1", title: "Not a template", body: "", tags: ["work"] },
  { id: "l1", kind: "link", title: "A link tagged template", url: "https://example.com", tags: ["template"] },
];
const view = (o) => itemView({
  id: o.id, updatedHLC: "1", conflicts: {}, texts: { body: o.body ?? "" },
  fields: Object.fromEntries(Object.entries({ kind: o.kind ?? "note", title: o.title, url: o.url, tags: o.tags, category: o.category ?? "note", createdAt: 1 })
    .filter(([, v]) => v !== undefined)),
});
const views = items.map(view);
const builtInOnly = [];
const bodies = [
  "- [ ] one\n- [x] two\n  * [X] three, indented\n\t• [ ] tabbed\n- [ ]\n- [ ]x not one\n-[ ] not one\n```\n- [ ] in code\n```\n- [ ] after code",
  "No tasks\n## Heading",
  "- [ ] crlf\r\n- [x] done\r\n",
];

const fixture = {
  parts,
  placeholders: texts.flatMap((text) => parts.map((p, n) => ({ text, part: n, clipboard: "clip", title: "My title",
    expect: expandPlaceholders(text, p, { clipboard: "clip", title: "My title" }), has: hasPlaceholders(text) }))),
  templateNames: ["Meeting {date}", "  {date}  ", "Weekly   review {year}", "", "{clipboard} notes"].map((title) => ({ title, expect: templateName(title) })),
  items,
  templates: allTemplates(views).map((t) => ({ ...t, clipboard: usesClipboard(t), made: fromTemplate(t, parts[0], { clipboard: "clip" }) })),
  builtInTemplates: allTemplates(builtInOnly).map((t) => ({ ...t, clipboard: usesClipboard(t), made: fromTemplate(t, parts[0]) })),
  daily: dailyNote(views, parts[0]),
  dailyBuiltIn: dailyNote(builtInOnly, parts[1]),
  checklists: bodies.map((body) => {
    const boxes = checkboxes(body);
    return { body, boxes, counts: checkboxCounts(body), toggled: boxes.map((_, i) => toggleCheckbox(body, i)), outOfRange: toggleCheckbox(body, boxes.length) };
  }),
};
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/notes-cases.json", import.meta.url), JSON.stringify(fixture, null, 2) + "\n");
console.log(JSON.stringify({ daily: fixture.daily, names: fixture.templates.map((t) => t.name), checklists: fixture.checklists[0].boxes }, null, 2));
