// Notes: placeholders, the daily note, templates, checklists and embeds (PROTOCOL.md §12).
// A port of Notes.swift; both run Packages/TroveCore/Tests/TroveCoreTests/Fixtures/notes-cases.json
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
export const longDate = (p) => `${WEEKDAYS[p.weekday]} ${p.day} ${MONTHS[p.month - 1]} ${p.year}`;

/**
 * Fills in `{date}` (2026-10-21), `{time}` (14:05), `{datetime}`, `{longdate}` (Wednesday 21 October
 * 2026), `{weekday}`, `{day}`, `{month}` (October), `{year}`, `{clipboard}` and `{title}`. Anything
 * else in braces stays as it is.
 */
export function expandPlaceholders(text, parts, { clipboard = "", title = "" } = {}) {
  const values = {
    date: isoDate(parts), time: `${pad(parts.hour)}:${pad(parts.minute)}`, datetime: `${isoDate(parts)} ${pad(parts.hour)}:${pad(parts.minute)}`,
    longdate: longDate(parts), weekday: WEEKDAYS[parts.weekday], day: String(parts.day), month: MONTHS[parts.month - 1], year: String(parts.year),
    clipboard, title,
  };
  return String(text).replace(/\{([a-z]+)\}/g, (whole, name) => (Object.hasOwn(values, name) ? values[name] : whole));
}

/** True when text has a placeholder we fill in. */
export const hasPlaceholders = (text) => /\{(date|time|datetime|longdate|weekday|day|month|year|clipboard|title)\}/.test(String(text));

// ---------- daily note and templates ----------

/** The daily note's id: the same on every device for that day, so they all write one note. */
export const dailyNoteId = (parts) => `daily-${isoDate(parts)}`;

/** Built-in templates. `title` and `body` take placeholders. */
export const TEMPLATES = [
  { id: "daily", name: "Daily note", title: "{longdate}", tags: ["daily"], body: "## Tasks\n- [ ] \n\n## Notes\n" },
  { id: "meeting", name: "Meeting", title: "Meeting {date}", tags: ["meeting"],
    body: "{longdate}, {time}\n\n## Who\n- \n\n## Agenda\n- \n\n## Notes\n\n\n## Actions\n- [ ] " },
  { id: "journal", name: "Journal", title: "Journal {date}", tags: ["journal"],
    body: "## How I feel\n\n\n## What happened\n\n\n## Grateful for\n- \n\n## Tomorrow\n- [ ] " },
  { id: "recipe", name: "Recipe", title: "New recipe", tags: ["recipe"], category: "recipe",
    body: "Serves: \nTakes: \n\n## Ingredients\n- \n\n## Method\n1. \n\n## Notes\n" },
];

/** Notes tagged `template` are your own templates: their title is the name, title and body are filled in. */
export function userTemplates(items) {
  return items.filter((i) => i.kind === "note" && i.tags.includes("template") && !i.id.startsWith("daily-"))
    .sort((a, b) => a.displayTitle.localeCompare(b.displayTitle) || (a.id < b.id ? -1 : 1))
    .map((i) => ({ id: i.id, name: i.displayTitle, title: i.title, body: i.body, tags: i.tags.filter((t) => t !== "template"), user: true }));
}

/** Every template, yours first; one of yours named like a built-in one replaces it. */
export function allTemplates(items) {
  const mine = userTemplates(items);
  const names = new Set(mine.map((t) => t.name.toLowerCase()));
  return [...mine, ...TEMPLATES.filter((t) => !names.has(t.name.toLowerCase()))];
}

/** A new note from a template: `{title, body, tags, category?}` with the placeholders filled in. */
export function fromTemplate(template, parts, { clipboard = "" } = {}) {
  const title = expandPlaceholders(template.title ?? "", parts, { clipboard });
  const body = expandPlaceholders(template.body ?? "", parts, { clipboard, title });
  const out = { title, body, tags: [...new Set(template.tags ?? [])].sort() };
  if (template.category) out.category = template.category;
  return out;
}

/** The daily note for a day: your template named "Daily note" if you made one, else the built-in one. */
export function dailyNote(items, parts) {
  const template = allTemplates(items).find((t) => t.name.toLowerCase() === "daily note");
  const note = fromTemplate(template, parts);
  return { id: dailyNoteId(parts), daily: isoDate(parts), ...note, tags: [...new Set([...note.tags, "daily"])].sort() };
}

// ---------- checklists ----------

const TASK = /^(\s*[-*•]\s+\[)( |x|X)(\]\s)/;

/** The lines (0-based) of `- [ ]` / `- [x]` tasks outside code blocks, in order. */
export function taskLines(body) {
  const out = [];
  let fence = false;
  String(body).split("\n").forEach((line, i) => {
    if (line.trim().startsWith("```")) { fence = !fence; return; }
    if (!fence && TASK.test(line + " ")) out.push(i);
  });
  return out;
}

/** Ticks or unticks the `index`th task (counting from 0); the body unchanged if there's no such task. */
export function toggleTask(body, index) {
  const lines = String(body).split("\n");
  const at = taskLines(body)[index];
  if (at === undefined) return body;
  lines[at] = (lines[at] + " ").replace(TASK, (_, a, mark, c) => `${a}${mark === " " ? "x" : " "}${c}`).slice(0, -1);
  return lines.join("\n");
}

/** How many tasks are done, of how many. */
export function taskCounts(body) {
  const lines = String(body).split("\n");
  const tasks = taskLines(body).map((i) => (lines[i] + " ").match(TASK)[2]);
  return { done: tasks.filter((m) => m !== " ").length, total: tasks.length };
}

// ---------- embeds: ![[name]], ![[item-id]], ![[sketch-id#page]] ----------

/**
 * Embeds in a note, in order: `{target, page}` for `![[target]]` and `![[target#n]]` (page from 1;
 * null when not given or not a number). Code is skipped. Embeds aren't wikilinks.
 */
export function embeds(text) {
  const out = [];
  let fence = false;
  for (const line of String(text ?? "").split("\n")) {
    if (line.trim().startsWith("```")) { fence = !fence; continue; }
    if (fence) continue;
    const plain = line.replace(/`[^`]*`/g, "");
    for (const m of plain.matchAll(/!\[\[([^[\]\n]+)\]\]/g)) {
      const [target, frag] = m[1].split("|")[0].split("#");
      const t = target.trim();
      if (!t) continue;
      const n = frag !== undefined && /^\s*\d+\s*$/.test(frag) ? Number(frag) : null;
      out.push({ target: t, page: n && n > 0 ? n : null });
    }
  }
  return out;
}

/**
 * What an embed in `note` shows: `{type: "attachment", attachment}` for one of the note's own files
 * with that name, else `{type: "item", id, page}` for an item with that id, then that title
 * (`titles`: lowercased title → id, links.js titleIndex), else null.
 */
export function resolveEmbed(embed, note, itemIds, titles) {
  const att = (note?.attachments ?? []).find((a) => a.name === embed.target);
  if (att) return { type: "attachment", attachment: att };
  if (itemIds.has(embed.target)) return { type: "item", id: embed.target, page: embed.page };
  const id = titles.get(embed.target.toLowerCase());
  return id ? { type: "item", id, page: embed.page } : null;
}

/** The name a pasted picture gets (Obsidian's convention): `Pasted image 20261021140502.png`. */
export function pastedImageName(parts, mime = "image/png") {
  const ext = { "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic" }[mime] ?? "png";
  return `Pasted image ${pad(parts.year, 4)}${pad(parts.month)}${pad(parts.day)}${pad(parts.hour)}${pad(parts.minute)}${pad(parts.second ?? 0)}.${ext}`;
}

// ---------- folding headings ----------

/**
 * The sections a heading folds: `[{line, level, end}]` for each `#`–`######` heading outside code,
 * `end` the line before the next heading of the same or a higher level (or the last line).
 */
export function headingSections(body) {
  const lines = String(body).split("\n");
  const heads = [];
  let fence = false;
  lines.forEach((line, i) => {
    if (line.trim().startsWith("```")) { fence = !fence; return; }
    const m = !fence && /^(#{1,6})\s+\S/.exec(line);
    if (m) heads.push({ line: i, level: m[1].length });
  });
  return heads.map((hd, k) => {
    const next = heads.slice(k + 1).find((o) => o.level <= hd.level);
    return { ...hd, end: (next ? next.line : lines.length) - 1 };
  });
}
