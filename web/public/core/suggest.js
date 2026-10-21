// "Suggest links" (ROADMAP §4 A2/A3): items a note probably wants to link to, found with the local
// search and the related-items rules. No AI and nothing leaves the device. Run on demand (a tap), not
// per render, because it searches the vault a few times.
import { search, terms } from "./items.js";
import { related, wikilinks } from "./links.js";

/** The note's most telling words: frequent, not tiny, title words counted double. */
export function keyTerms(item, max = 6) {
  const counts = new Map();
  const add = (text, w) => { for (const t of terms(text ?? "")) if (t.length >= 4 && !/^\p{N}+$/u.test(t)) counts.set(t, (counts.get(t) ?? 0) + w); };
  add(item.title, 2);
  add(item.body, 1);
  add(item.summary, 1);
  add(item.tags.join(" "), 2);
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, max).map(([t]) => t);
}

/**
 * Up to `limit` items to link from `item`: `[{item, reason}]`, best first. Leaves out the item, what
 * it already links to (by hand or by [[title]]) and what links to it by hand.
 */
export function suggestLinks(item, items, limit = 6) {
  const linkedTitles = new Set(wikilinks(item.body).map((t) => t.toLowerCase()));
  const skip = (o) => o.id === item.id || item.links.includes(o.id) || o.links.includes(item.id) || linkedTitles.has(o.displayTitle.trim().toLowerCase());
  const pool = items.filter((o) => !skip(o));
  const scores = new Map();
  const bump = (o, s, reason) => {
    const e = scores.get(o.id) ?? { item: o, score: 0, reason };
    e.score += s;
    if (s > (e.best ?? 0)) { e.best = s; e.reason = reason; }
    scores.set(o.id, e);
  };
  // Its title written out in this note: almost certainly worth a link.
  const body = (item.body ?? "").toLowerCase();
  for (const o of pool) {
    const t = o.displayTitle.trim().toLowerCase();
    if ([...t].length >= 4 && t !== "untitled" && body.includes(t)) bump(o, 3, "Named in this note");
  }
  for (const word of keyTerms(item)) {
    search(pool, word).slice(0, 8).forEach((o, rank) => bump(o, 1 / (2 + rank), `Also about “${word}”`));
  }
  related(item, pool, 8).forEach((o, rank) => bump(o, 0.6 / (1 + rank), "Shares tags or a folder"));
  return [...scores.values()]
    .filter((e) => e.score >= 0.3)
    .sort((a, b) => b.score - a.score || b.item.createdAt - a.item.createdAt)
    .slice(0, limit)
    .map(({ item: o, reason }) => ({ item: o, reason }));
}
