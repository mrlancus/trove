// Where and when clips were copied and pasted (PROTOCOL.md §8 "Copy and paste events"): one
// `clipEvent` record per copy or paste, so devices never overwrite each other's. ClipEvents.swift
// is the same; both check Fixtures/clip-events.json. Also the clipboard map: clips joined to the
// apps and sites they came from, the apps they went to, the places and the days.

export const CLIP_EVENT_FIELDS = ["clip", "type", "at", "device", "deviceName", "app", "bundle", "url", "title", "window", "place"];

/** A clipEvent record as {id, clip, type: "copy"|"paste"|"use", at, device, deviceName, app, url, title, window, place}. */
export function clipEventView(record) {
  const f = record.fields;
  const str = (v) => (typeof v === "string" && v ? v : null);
  const p = f.place && typeof f.place === "object" && Number.isFinite(f.place.lat) && Number.isFinite(f.place.lon) ? f.place : null;
  return {
    id: record.id, clip: str(f.clip), type: ["copy", "paste", "use"].includes(f.type) ? f.type : "copy",
    at: typeof f.at === "number" ? f.at : 0, device: str(f.device), deviceName: str(f.deviceName),
    app: str(f.app), bundle: str(f.bundle), url: str(f.url), title: str(f.title), window: str(f.window),
    place: p ? { lat: p.lat, lon: p.lon, accuracy: Number.isFinite(p.accuracy) ? p.accuracy : null, name: str(p.name), city: str(p.city) } : null,
  };
}

/** A place's key and label: its name, else its city, else its rounded position (about 100 m). */
export function placeKey(place) {
  if (!place) return null;
  if (place.name) return { key: `place:${place.name.toLowerCase()}`, label: place.name };
  const lat = place.lat.toFixed(3), lon = place.lon.toFixed(3);
  return { key: `place:${lat},${lon}`, label: place.city ? `${place.city} (${lat}, ${lon})` : `${lat}, ${lon}` };
}

/** Where a copy came from or a paste went: the site (host) when there's a page, else the app. */
export function appKey(e) {
  if (e.url) {
    try { const host = new URL(e.url).host.replace(/^www\./, ""); if (host) return { key: `site:${host}`, label: host }; } catch { /* not a URL */ }
  }
  if (e.app) return { key: `app:${e.app.toLowerCase()}`, label: e.app };
  return null;
}

/** The local day of a time, as YYYY-MM-DD. */
export const dayKey = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};

/**
 * What each clip is known for, from its events and its own fields: {from: Map(key → label),
 * to: Map, places: Map, days: Set, last: ms}. A clip with no copy event still counts its own
 * `sourceApp`/`sourceURL` and `createdAt`.
 */
export function clipFacts(clips, events) {
  const facts = new Map();
  for (const c of clips) {
    const f = { from: new Map(), to: new Map(), places: new Map(), days: new Set([dayKey(c.createdAt || c.sortDate)]), last: c.sortDate };
    const own = appKey({ url: c.sourceURL, app: c.sourceApp });
    if (own) f.from.set(own.key, own.label);
    facts.set(c.id, f);
  }
  for (const e of events) {
    const f = facts.get(e.clip);
    if (!f) continue;
    const where = appKey(e);
    if (where) (e.type === "copy" ? f.from : e.type === "paste" ? f.to : new Map()).set(where.key, where.label);
    const place = placeKey(e.place);
    if (place) f.places.set(place.key, place.label);
    if (e.at) { f.days.add(dayKey(e.at)); f.last = Math.max(f.last, e.at); }
  }
  return facts;
}

/**
 * The clips that pass the filters: {from, to, place} are keys from `clipFacts`, `since` a time
 * (ms), `tag` a tag, `kind` a clip kind.
 */
export function filterClips(clips, facts, { from = null, to = null, place = null, since = null, tag = null, kind = null } = {}) {
  return clips.filter((c) => {
    const f = facts.get(c.id);
    if (!f) return false;
    if (from && !f.from.has(from)) return false;
    if (to && !f.to.has(to)) return false;
    if (place && !f.places.has(place)) return false;
    if (since && f.last < since) return false;
    if (tag && !c.tags.includes(tag)) return false;
    if (kind && c.kind !== kind) return false;
    return true;
  });
}

/** The choices each filter offers, most used first: [{key, label, count}]. */
export function filterChoices(clips, facts) {
  const count = (field) => {
    const m = new Map();
    for (const c of clips) for (const [key, label] of facts.get(c.id)?.[field] ?? []) { const x = m.get(key) ?? { key, label, count: 0 }; x.count++; m.set(key, x); }
    return [...m.values()].sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  };
  return { from: count("from"), to: count("to"), places: count("places") };
}

export const CLIP_KIND_COLORS = { text: "#54a0ff", link: "#1dd1a1", email: "#feca57", phone: "#feca57", color: "#ff6b6b", code: "#a55eea", json: "#a55eea",
  number: "#48dbfb", path: "#c8d6e5", image: "#ff9f43", file: "#c8d6e5" };
export const CLIP_GROUP_COLORS = { from: "#1dd1a1", to: "#ff4f8b", place: "#feca57", day: "#8395a7", tag: "#a55eea" };

/**
 * The clipboard map (graph.js draws it): clips as points coloured by kind, joined to what they're
 * grouped by: `groups` any of "from", "to", "place", "day", "tag". Clips connected to each other or
 * to library items (`links`) are joined too. Groups with one clip are left out unless `singles`.
 */
export function buildClipGraph(clips, facts, { groups = ["from", "to", "place"], items = [], singles = false } = {}) {
  const nodes = new Map(), edges = [];
  const label = (c) => c.displayTitle.length > 40 ? c.displayTitle.slice(0, 39) + "…" : c.displayTitle;
  const addClip = (c) => { if (!nodes.has(c.id)) nodes.set(c.id, { id: c.id, type: "item", label: label(c), color: CLIP_KIND_COLORS[c.kind] ?? "#54a0ff", clip: c, degree: 0 }); };
  const members = new Map();
  const join = (group, key, text, c) => {
    const id = `${group}|${key}`;
    if (!members.has(id)) members.set(id, { group, label: text, clips: [] });
    members.get(id).clips.push(c);
  };
  for (const c of clips) {
    const f = facts.get(c.id);
    if (!f) continue;
    if (groups.includes("from")) for (const [k, l] of f.from) join("from", k, l, c);
    if (groups.includes("to")) for (const [k, l] of f.to) join("to", k, l, c);
    if (groups.includes("place")) for (const [k, l] of f.places) join("place", k, l, c);
    if (groups.includes("day")) for (const d of f.days) join("day", d, d, c);
    if (groups.includes("tag")) for (const t of c.tags) join("tag", t, `#${t}`, c);
  }
  for (const [id, m] of members) {
    if (m.clips.length < 2 && !singles) continue;
    nodes.set(id, { id, type: m.group === "place" || m.group === "tag" ? "tag" : "folder", group: m.group, label: m.group === "to" ? `→ ${m.label}` : m.label,
      color: CLIP_GROUP_COLORS[m.group], degree: 0 });
    for (const c of m.clips) { addClip(c); edges.push({ a: c.id, b: id, kind: m.group === "from" || m.group === "to" ? "flow" : "group" }); }
  }
  const byId = new Map(clips.map((c) => [c.id, c]));
  const itemsById = new Map(items.map((i) => [i.id, i]));
  for (const c of clips) for (const other of c.links) {
    if (byId.has(other)) { addClip(c); addClip(byId.get(other)); edges.push({ a: c.id, b: other, kind: "link" }); }
    else if (itemsById.has(other)) {
      const it = itemsById.get(other);
      addClip(c);
      if (!nodes.has(it.id)) nodes.set(it.id, { id: it.id, type: "item", label: it.displayTitle, color: "#c8d6e5", item: it, degree: 0 });
      edges.push({ a: c.id, b: it.id, kind: "link" });
    }
  }
  if (!edges.length) for (const c of clips.slice(0, 200)) addClip(c);
  for (const e of edges) { nodes.get(e.a).degree++; nodes.get(e.b).degree++; }
  return { nodes: [...nodes.values()], edges };
}
