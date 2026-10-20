// Connections between items: a port of Links.swift. Both run
// Packages/TroveCore/Tests/TroveCoreTests/Fixtures/links-cases.json.

/** Targets of [[Target]], [[Target|label]], [[Target#heading]], in order, no repeats; code skipped. */
export function wikilinks(text) {
  const out = [];
  let fence = false;
  for (const line of (text ?? "").split("\n")) {
    if (line.trim().startsWith("```")) { fence = !fence; continue; }
    if (fence) continue;
    let rest = line.replace(/`[^`]*`/g, "");
    for (;;) {
      const open = rest.indexOf("[[");
      if (open < 0) break;
      const close = rest.indexOf("]]", open + 2);
      if (close < 0) break;
      let target = rest.slice(open + 2, close);
      target = target.split("|")[0].split("#")[0].trim();
      if (target && !target.includes("[") && !out.some((t) => t.localeCompare(target, undefined, { sensitivity: "accent" }) === 0)) out.push(target);
      rest = rest.slice(close + 2);
    }
  }
  return out;
}

const titleKey = (item) => item.displayTitle.trim().toLowerCase();

/** lowercased title → item id; the newest item wins a shared title (then the smallest id). */
export function titleIndex(items) {
  const index = new Map();
  for (const item of items) {
    const key = titleKey(item);
    if (!key) continue;
    const seen = index.get(key);
    if (seen && (seen.createdAt > item.createdAt || (seen.createdAt === item.createdAt && seen.id < item.id))) continue;
    index.set(key, { id: item.id, createdAt: item.createdAt });
  }
  return new Map([...index].map(([k, v]) => [k, v.id]));
}

/** {outgoing, incoming, unresolved} as plain objects of sorted id lists. */
export function linkGraph(items) {
  const titles = titleIndex(items);
  const ids = new Set(items.map((i) => i.id));
  const out = new Map(), unresolved = {};
  const add = (from, to) => { if (!out.has(from)) out.set(from, new Set()); out.get(from).add(to); };
  for (const item of items) {
    for (const target of wikilinks(item.body)) {
      const id = titles.get(target.toLowerCase());
      if (id) { if (id !== item.id) add(item.id, id); } else (unresolved[item.id] ??= []).push(target);
    }
    for (const id of item.links ?? []) if (id !== item.id && ids.has(id)) add(item.id, id);
  }
  const outgoing = {}, incomingSets = new Map();
  for (const [from, tos] of out) {
    outgoing[from] = [...tos].sort();
    for (const to of tos) { if (!incomingSets.has(to)) incomingSets.set(to, new Set()); incomingSets.get(to).add(from); }
  }
  const incoming = {};
  for (const [to, froms] of incomingSets) incoming[to] = [...froms].sort();
  return { outgoing, incoming, unresolved };
}

export function neighbours(graph, id) {
  return [...new Set([...(graph.outgoing[id] ?? []), ...(graph.incoming[id] ?? [])])].sort();
}

const fold = (s) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Items that mention this one's title without linking it. */
export function mentions(item, items, linked = new Set()) {
  const title = item.displayTitle.trim();
  if ([...title].length < 4 || title === "Untitled") return [];
  const needle = fold(title);
  return items.filter((o) => o.id !== item.id && !linked.has(o.id) && fold(o.body).includes(needle));
}

/** Items that look related: shared tags count most, then the same folder and the same site. */
export function related(item, items, limit = 6) {
  const tags = new Set(item.tags);
  const host = item.url?.host;
  const scored = [];
  for (const o of items) {
    if (o.id === item.id) continue;
    let score = 2 * o.tags.filter((t) => tags.has(t)).length;
    if (item.folder && item.folder === o.folder && (tags.size || item.kind === o.kind)) score += 1;
    if (host && host === o.url?.host) score += 1;
    if (score >= 2) scored.push([o, score]);
  }
  return scored.sort((a, b) => (a[1] !== b[1] ? b[1] - a[1] : b[0].createdAt - a[0].createdAt)).slice(0, limit).map(([o]) => o);
}
