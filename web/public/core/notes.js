// Notes: placeholders, the daily note, templates and checklists (PROTOCOL.md §12).
// Notes.swift is a port; both run Packages/TroveCore/Tests/TroveCoreTests/Fixtures/notes-cases.json
// (made by web/test/make-notes-fixture.mjs).

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const pad = (n, w = 2) => String(n).padStart(w, "0");

/**
 * The parts of a moment on this device's clock: `{year, month (1–12), day, hour, minute, second,
 * weekday (0 = Sunday)}`. Everything below takes these, so tests don't depend on the time zone.
 */
export function dateParts(date = new Date()) {
  return { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(), hour: date.getHours(), minute: date.getMinutes(),
    second: date.getSeconds(), weekday: date.getDay() };
}

export const isoDate = (p) => `${pad(p.year, 4)}-${pad(p.month)}-${pad(p.day)}`;
export const longDate = (p) => `${WEEKDAYS[p.weekday % 7]} ${p.day} ${MONTHS[(p.month - 1) % 12]} ${p.year}`;

// ---------- placeholders ----------

const NAMES = new Set(["date", "time", "datetime", "longdate", "weekday", "day", "month", "year", "clipboard", "title"]);
const replacePlaceholders = (text, value) =>
  String(text).replace(/\{([a-z]+)\}/g, (whole, name) => {
    const v = NAMES.has(name) ? value(name) : null;
    return v ?? whole;
  });

/**
 * Fills in `{date}` (2026-10-21), `{time}` (14:05), `{datetime}`, `{longdate}` (Wednesday 21 October
 * 2026), `{weekday}`, `{day}`, `{month}` (October), `{year}`, `{clipboard}` and `{title}`. Anything
 * else in braces stays as it is.
 */
export function expandPlaceholders(text, p, { clipboard = "", title = "" } = {}) {
  const time = `${pad(p.hour)}:${pad(p.minute)}`;
  const values = {
    date: isoDate(p), time, datetime: `${isoDate(p)} ${time}`, longdate: longDate(p), weekday: WEEKDAYS[p.weekday % 7], day: String(p.day),
    month: MONTHS[(p.month - 1) % 12], year: String(p.year), clipboard, title,
  };
  return replacePlaceholders(text, (name) => values[name]);
}

const placeholders = (text) => {
  const found = new Set();
  replacePlaceholders(text, (name) => { found.add(name); return null; });
  return found;
};

/** True when text has a placeholder we fill in. */
export const hasPlaceholders = (text) => placeholders(text).size > 0;

/** Whether filling in a template needs the clipboard (the browser asks permission to read it). */
export const usesClipboard = (template) => placeholders(template.title ?? "").has("clipboard") || placeholders(template.body ?? "").has("clipboard");

// ---------- templates and the daily note ----------

export const TEMPLATE_TAG = "template";
export const DAILY_TAG = "daily";
export const DAILY_NAME = "Daily note";

/** Built-in templates. `title` and `body` take placeholders. */
export const TEMPLATES = [
  { id: "daily", name: DAILY_NAME, title: "{longdate}", body: "## Tasks\n- [ ] \n\n## Notes\n", tags: ["daily"], category: null, user: false },
  { id: "meeting", name: "Meeting", title: "Meeting {date}", body: "{longdate}, {time}\n\n## Who\n- \n\n## Agenda\n- \n\n## Notes\n\n\n## Actions\n- [ ] ",
    tags: ["meeting"], category: null, user: false },
  { id: "journal", name: "Journal", title: "Journal {date}", body: "## How I feel\n\n\n## What happened\n\n\n## Grateful for\n- \n\n## Tomorrow\n- [ ] ",
    tags: ["journal"], category: null, user: false },
  { id: "recipe", name: "Recipe", title: "New recipe", body: "Serves: \nTakes: \n\n## Ingredients\n- \n\n## Method\n1. \n\n## Notes\n",
    tags: ["recipe"], category: "recipe", user: false },
];

/** The daily note's id: the same on every device for that day, so they all write one note. */
export const dailyNoteId = (p) => `daily-${isoDate(p)}`;
export const isDaily = (item) => item.id.startsWith("daily-");

/** A template's name: its title without placeholders ("Meeting {date}" is "Meeting"). */
export function templateName(title) {
  const words = replacePlaceholders(title, () => "").split(/[ \t\n]+/).filter(Boolean);
  return words.length ? words.join(" ") : "Template";
}

const byName = (a, b) => {
  const x = a.name.toLowerCase(), y = b.name.toLowerCase();
  return x !== y ? (x < y ? -1 : 1) : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
};

/** Notes tagged `template` are your own templates, named after their title, A to Z. */
export function userTemplates(items) {
  return items.filter((i) => i.kind === "note" && i.tags.includes(TEMPLATE_TAG) && !isDaily(i))
    .map((i) => ({ id: i.id, name: templateName(i.title), title: i.title, body: i.body, tags: i.tags.filter((t) => t !== TEMPLATE_TAG),
      category: i.category === "note" || i.category === "other" ? null : i.category, user: true }))
    .sort(byName);
}

/** Every template, yours first; one of yours named like a built-in one replaces it. */
export function allTemplates(items) {
  const mine = userTemplates(items);
  const names = new Set(mine.map((t) => t.name.toLowerCase()));
  return [...mine, ...TEMPLATES.filter((t) => !names.has(t.name.toLowerCase()))];
}

/** A new note from a template: `{title, body, tags, category}` (`{title}` in the body is the new title). */
export function fromTemplate(template, p, { clipboard = "" } = {}) {
  const title = expandPlaceholders(template.title ?? "", p, { clipboard });
  const body = expandPlaceholders(template.body ?? "", p, { clipboard, title });
  return { title, body, tags: [...new Set(template.tags ?? [])].sort(), category: template.category ?? null };
}

/**
 * The daily note for a day: titled with the long date; the body and tags from your template named
 * "Daily note" if you made one, else the built-in one. Always tagged `daily`.
 */
export function dailyNote(items, p) {
  const template = allTemplates(items).find((t) => t.name.toLowerCase() === DAILY_NAME.toLowerCase()) ?? TEMPLATES[0];
  const note = fromTemplate({ ...template, title: "{longdate}" }, p);
  return { id: dailyNoteId(p), date: isoDate(p), note: { ...note, tags: [...new Set([...note.tags, DAILY_TAG])].sort() } };
}

// ---------- checklists ----------

// `- [ ]`, `- [x]` (also `*` or `•`), indented with spaces or tabs.
const CHECKBOX = /^([ \t]*[-*•][ \t]+\[)( |x|X)\]([ \t]|$)/;
const isFence = (line) => line.trim().startsWith("```");

/** The checklist lines outside code blocks, in order: `{line (from 0), done, text}`. */
export function checkboxes(body) {
  const out = [];
  let fence = false;
  String(body).split("\n").forEach((line, i) => {
    if (isFence(line)) { fence = !fence; return; }
    const m = !fence && CHECKBOX.exec(line);
    if (m) out.push({ line: i, done: m[2] !== " ", text: line.slice(m[0].length) });
  });
  return out;
}

/** Ticks or unticks the `index`th checkbox (from 0); the body unchanged if there's no such checkbox. */
export function toggleCheckbox(body, index) {
  const box = checkboxes(body)[index];
  if (!box) return body;
  const lines = String(body).split("\n");
  const m = CHECKBOX.exec(lines[box.line]);
  const at = m[1].length;
  lines[box.line] = lines[box.line].slice(0, at) + (box.done ? " " : "x") + lines[box.line].slice(at + 1);
  return lines.join("\n");
}

/** How many checkboxes are ticked, of how many. */
export function checkboxCounts(body) {
  const boxes = checkboxes(body);
  return { done: boxes.filter((b) => b.done).length, total: boxes.length };
}
