// Looking back (ROADMAP §4 A3): the weekly digest note, "on this day" and possible duplicates.
// All local, no AI needed. A port of Digest.swift; both run
// Packages/TroveCore/Tests/TroveCoreTests/Fixtures/digest-cases.json (PROTOCOL.md §11).
import { dedupeKey } from "./items.js";

const DAY = 86_400_000;
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const SECTION_MAX = 25;

/** The ISO 8601 week of a moment, in UTC: `{year, week}` (weeks start on Monday). */
export function isoWeek(ms) {
  const d = new Date(Math.floor(ms / DAY) * DAY);
  const weekday = (d.getUTCDay() + 6) % 7; // Monday 0
  const thursday = new Date(d.getTime() + (3 - weekday) * DAY);
  const year = thursday.getUTCFullYear();
  const jan1 = Date.UTC(year, 0, 1);
  return { year, week: 1 + Math.floor((thursday.getTime() - jan1) / DAY / 7) };
}

/** Monday 00:00 UTC of ISO week `week` of `year`, in ms. */
export function weekStart(year, week) {
  const jan4 = Date.UTC(year, 0, 4);
  const monday1 = jan4 - ((new Date(jan4).getUTCDay() + 6) % 7) * DAY;
  return monday1 + (week - 1) * 7 * DAY;
}

/** The digest's item id: the same on every device, so two devices write the same item. */
export const digestId = (year, week) => `digest-${year}-w${String(week).padStart(2, "0")}`;

/** The week before the one `ms` is in. */
export const previousWeek = (ms) => isoWeek(weekStart(isoWeek(ms).year, isoWeek(ms).week) - DAY);

const dayLabel = (ms) => { const d = new Date(ms); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };
const linkTitle = (t) => String(t ?? "").replace(/[[\]|#\n]/g, " ").replace(/\s+/g, " ").trim();
const host = (item) => (item.url?.hostname ?? "").replace(/^www\./, "");
const isDigest = (item) => item.record?.fields?.digest !== undefined || item.id.startsWith("digest-");
const written = (item) => item.kind === "note" || item.kind === "sketch";
const byCreated = (a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

function list(items, describe) {
  const lines = items.slice(0, SECTION_MAX).map((i) => {
    const note = describe?.(i);
    return `- [[${linkTitle(i.displayTitle)}]]${note ? ` (${note})` : ""}`;
  });
  if (items.length > SECTION_MAX) lines.push(`- and ${items.length - SECTION_MAX} more`);
  return lines;
}

/**
 * The digest for ISO week `week` of `year`: `{id, title, body, year, week, counts}`. `summary` (an AI
 * paragraph) and `model` are optional; without them it's the same text on every device.
 */
export function weeklyDigest(items, year, week, { summary = "", model = "" } = {}) {
  const start = weekStart(year, week), end = start + 7 * DAY;
  const pool = items.filter((i) => !isDigest(i));
  const inWeek = pool.filter((i) => i.createdAt >= start && i.createdAt < end).sort(byCreated);
  const saved = inWeek.filter((i) => !written(i));
  const wrote = inWeek.filter(written);
  const unopened = pool.filter((i) => i.kind === "link" && i.readAt === null && i.createdAt >= start - 28 * DAY && i.createdAt < start).sort(byCreated).slice(0, 10);
  const yearsAgo = pool.filter((i) => i.createdAt < start && i.createdAt > 0 && (() => { const w = isoWeek(i.createdAt); return w.week === week && w.year < year; })())
    .sort((a, b) => byCreated(b, a)).slice(0, 10);

  const title = `Week of ${dayLabel(start)} ${new Date(start).getUTCFullYear()}`;
  const things = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  const lines = [];
  if (!saved.length && !wrote.length) lines.push("A quiet week: nothing new saved or written.");
  else lines.push(`You saved ${things(saved.length, "thing", "things")} and wrote ${things(wrote.length, "note", "notes")} this week.`);
  if (summary.trim()) lines.push("", "## In short", summary.trim(), "", `_Processed in the cloud${model ? ` (${model})` : ""}._`);
  if (saved.length) lines.push("", "## Saved", ...list(saved, (i) => [i.kind, host(i)].filter(Boolean).join(", ")));
  if (wrote.length) lines.push("", "## Written", ...list(wrote, (i) => (i.kind === "sketch" ? "sketch" : "")));
  if (unopened.length) lines.push("", "## Not opened yet", ...list(unopened, (i) => `saved ${dayLabel(i.createdAt)}`));
  if (yearsAgo.length) lines.push("", "## This week in other years", ...list(yearsAgo, (i) => String(new Date(i.createdAt).getUTCFullYear())));
  return {
    id: digestId(year, week), title, body: lines.join("\n"), year, week,
    counts: { saved: saved.length, written: wrote.length, unopened: unopened.length, yearsAgo: yearsAgo.length },
  };
}

/** Items saved on today's date (UTC) in earlier years, newest first. */
export function onThisDay(items, now = Date.now()) {
  const d = new Date(now);
  return items.filter((i) => {
    if (isDigest(i) || !i.createdAt) return false;
    const c = new Date(i.createdAt);
    return c.getUTCMonth() === d.getUTCMonth() && c.getUTCDate() === d.getUTCDate() && c.getUTCFullYear() < d.getUTCFullYear();
  }).sort((a, b) => byCreated(b, a));
}

// ---------- Possible duplicates ----------

const STOP = new Set(["a", "an", "and", "the", "of", "to", "in", "on", "for", "with", "is", "at", "by", "from", "how", "what", "why"]);

/** Title words for comparing: folded, lowercased, no stopwords or one-letter words. */
export function titleWords(title) {
  const folded = String(title ?? "").normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  return (folded.match(/[\p{L}\p{N}]+/gu) ?? []).filter((w) => w.length > 1 && !STOP.has(w));
}

function jaccard(a, b) {
  const sa = new Set(a), sb = new Set(b);
  let both = 0;
  for (const w of sa) if (sb.has(w)) both++;
  return both / (sa.size + sb.size - both);
}

/** ids this item was told isn't a duplicate of (field `notDuplicates`). */
const notDuplicates = (item) => (Array.isArray(item.record?.fields?.notDuplicates) ? item.record.fields.notDuplicates : []);

/**
 * Items that look like the same thing saved twice: `[{reason, ids}]`, `reason` one of
 * "same link" (the same address once tracking bits are cleaned off), "same title" (4+ words, any
 * site) or "similar title" (same site, 3+ words, 80% of the words shared). Groups are newest first.
 */
export function possibleDuplicates(items) {
  const pool = items.filter((i) => !isDigest(i) && i.kind !== "note" && i.kind !== "sketch");
  const parent = new Map(pool.map((i) => [i.id, i.id]));
  const reason = new Map(); // root → best reason
  const rank = { "same link": 0, "same title": 1, "similar title": 2 };
  const find = (id) => { while (parent.get(id) !== id) { parent.set(id, parent.get(parent.get(id))); id = parent.get(id); } return id; };
  const refused = (a, b) => notDuplicates(a).includes(b.id) || notDuplicates(b).includes(a.id);
  const join = (a, b, why) => {
    if (refused(a, b)) return;
    const ra = find(a.id), rb = find(b.id);
    const best = [why, reason.get(ra), reason.get(rb)].filter(Boolean).sort((x, y) => rank[x] - rank[y])[0];
    if (ra !== rb) parent.set(rb, ra);
    reason.set(ra, best);
  };
  const keyOf = new Map();
  for (const i of pool) {
    if (!i.url) continue;
    try { keyOf.set(i.id, dedupeKey(i.url.toString())); } catch { /* not a web address */ }
  }
  const groups = (keyFn) => {
    const m = new Map();
    for (const i of pool) { const k = keyFn(i); if (k) { if (!m.has(k)) m.set(k, []); m.get(k).push(i); } }
    return [...m.values()].filter((g) => g.length > 1);
  };
  for (const g of groups((i) => keyOf.get(i.id))) for (const o of g.slice(1)) join(g[0], o, "same link");
  const words = new Map(pool.map((i) => [i.id, titleWords(i.title)]));
  for (const g of groups((i) => (words.get(i.id).length >= 4 ? words.get(i.id).join(" ") : ""))) for (const o of g.slice(1)) join(g[0], o, "same title");
  for (const g of groups((i) => host(i))) {
    for (let x = 0; x < g.length; x++) {
      for (let y = x + 1; y < g.length; y++) {
        const a = g[x], b = g[y], wa = words.get(a.id), wb = words.get(b.id);
        if (wa.length < 3 || wb.length < 3 || keyOf.get(a.id) === keyOf.get(b.id)) continue;
        if (jaccard(wa, wb) >= 0.8) join(a, b, "similar title");
      }
    }
  }
  const out = new Map();
  for (const i of pool) {
    const r = find(i.id);
    if (!out.has(r)) out.set(r, []);
    out.get(r).push(i);
  }
  return [...out.entries()].filter(([, g]) => g.length > 1).map(([r, g]) => {
    const sorted = g.sort(byCreated);
    return { reason: reason.get(r), ids: sorted.map((i) => i.id), newest: sorted[sorted.length - 1].createdAt };
  }).sort((a, b) => b.newest - a.newest || (a.ids[0] < b.ids[0] ? -1 : 1)).map(({ reason: why, ids }) => ({ reason: why, ids }));
}
