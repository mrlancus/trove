import { pageListOf, PAPERS, validSize } from "./ink.js";
import { folderMap, ITEM_FIELDS, itemDoc, matchesFilters, parseQuery, TermIndex } from "./search.js";
// Item view, search and smart collections for the web app. Mirrors Item.swift, SearchIndex.swift,
// SmartCollections.swift, URLCleaner.swift and Markdown.hashtags closely enough to feel the same.

export const Field = {
  title: "title", url: "url", summary: "summary", tags: "tags", category: "category", source: "source",
  createdAt: "createdAt", capturedOn: "capturedOn", attachments: "attachments", extracted: "extracted",
  collections: "collections", pinned: "pinned", readAt: "readAt", enrichment: "enrichment",
  needsEnrichment: "needsEnrichment", ocrText: "ocrText", siteName: "siteName", imageURL: "imageURL",
  kind: "kind", resolvedConflicts: "resolvedConflicts", priceWatch: "priceWatch", published: "published", body: "body",
  folder: "folder", folderAuto: "folderAuto", links: "links", fileVersions: "fileVersions", thumbnail: "thumbnail", origin: "origin",
};

const isAttachment = (a) => a && typeof a === "object" && typeof a.id === "string";

const views = new WeakMap(); // record → { hlc, item }: records change in place, and each change moves updatedHLC on

/** A read-only view of an item record (Item.swift), made once per version of the record. */
export function itemView(record) {
  const cached = views.get(record);
  if (cached && cached.hlc === record.updatedHLC) return cached.item;
  const item = makeItemView(record);
  views.set(record, { hlc: record.updatedHLC, item });
  return item;
}

const isGoodNotesName = (a) => typeof a?.name === "string" && a.name.toLowerCase().endsWith(".goodnotes");

function makeItemView(record) {
  const f = record.fields;
  const str = (v) => (typeof v === "string" ? v : null);
  const body = record.texts.body ?? "";
  const title = str(f.title) ?? "";
  let url = null;
  try { url = f.url ? new URL(f.url) : null; } catch { url = null; }
  const conflicts = (record.conflicts.body ?? []).slice(Number(f.resolvedConflicts ?? 0));
  const item = {
    id: record.id, record, title, body, url,
    kind: str(f.kind) ?? "note",
    category: str(f.category) ?? "other",
    source: str(f.source) ?? "app",
    // A GoodNotes notebook counts as GoodNotes however it got here (Item.sources).
    sources: [...new Set([str(f.source) ?? "app", ...(Array.isArray(f.alsoFrom) ? f.alsoFrom.filter((s) => typeof s === "string") : []),
      ...((Array.isArray(f.attachments) && f.attachments.some(isGoodNotesName)) || (Array.isArray(f.fileVersions) && f.fileVersions.some((v) => isGoodNotesName(v?.attachment)))
        ? ["goodnotes"] : [])])],
    summary: str(f.summary),
    tags: Array.isArray(f.tags) ? f.tags.filter((t) => typeof t === "string") : [],
    createdAt: typeof f.createdAt === "number" ? f.createdAt : 0,
    collections: Array.isArray(f.collections) ? f.collections : [],
    isPinned: f.pinned === true,
    readAt: typeof f.readAt === "number" ? f.readAt : null,
    // Notebooks (attachment ids) whose ink was handed to Trove's editor (PROTOCOL.md §10).
    goodnotesInk: Array.isArray(f.goodnotesInk) ? f.goodnotesInk.filter((x) => typeof x === "string") : [],
    ocrText: str(f.ocrText), sketchText: str(f.sketchText), inkText: str(f.inkText), siteName: str(f.siteName), imageURL: str(f.imageURL),
    extracted: f.extracted && typeof f.extracted === "object" ? f.extracted : {},
    attachments: Array.isArray(f.attachments) ? f.attachments.filter(isAttachment) : [],
    folder: str(f.folder),
    isAutoFiled: f.folderAuto === true,
    links: Array.isArray(f.links) ? f.links.filter((l) => typeof l === "string") : [],
    thumbnail: isAttachment(f.thumbnail) ? f.thumbnail : null,
    fileVersions: Array.isArray(f.fileVersions) ? f.fileVersions.filter((v) => v && isAttachment(v.attachment)) : [],
    priceWatch: f.priceWatch && typeof f.priceWatch === "object" ? f.priceWatch : null,
    published: f.published && typeof f.published === "object" ? f.published : null,
    conflictingVersions: conflicts,
    hasConflicts: conflicts.length > 0,
  };
  if (item.kind === "sketch") {
    const size = validSize(f.pageSize) ?? [768, 1024];
    const pageList = pageListOf(f);
    Object.assign(item, { paper: PAPERS.includes(f.paper) ? f.paper : "blank", pageList, sketchPages: pageList.length, pageSize: size,
      infinite: f.canvas === "infinite" });
  }
  item.displayTitle = title || body.split("\n").find((l) => l.trim())?.slice(0, 80) || url?.host || (item.kind === "sketch" ? "Sketch" : "Untitled");
  return item;
}

// ---------- URLs ----------

const trackingPrefixes = ["utm_", "mc_", "pk_", "hsa_", "_hs", "vero_"];
const globalOnly = new Set(["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "igshid", "igsh",
  "ref_src", "ref_url", "s_cid", "cmpid", "_ga", "_gl", "spm", "share_id", "mkt_tok", "oly_anon_id", "oly_enc_id"]);
const hostScoped = { "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"], "open.spotify.com": ["si"] };

export function cleanURL(input) {
  const u = new URL(input);
  if (u.protocol !== "http:" && u.protocol !== "https:") return u;
  const host = u.hostname.replace("www.", "").replace(/^m\./, "");
  const scoped = Object.entries(hostScoped).find(([h]) => host === h || host.endsWith("." + h))?.[1] ?? [];
  for (const name of [...u.searchParams.keys()]) {
    const n = name.toLowerCase();
    if (globalOnly.has(n) || scoped.includes(n) || trackingPrefixes.some((p) => n.startsWith(p))) u.searchParams.delete(name);
  }
  if (u.hash.startsWith("#:~:text=")) u.hash = "";
  return u;
}

export function dedupeKey(url) {
  return cleanURL(url).toString().replace(/^https?:\/\//, "").replace(/^www\./, "").replace(/\/+$/, "");
}

// ---------- Tags ----------

export function hashtags(text) {
  const tags = [];
  let fence = false;
  for (const line of text.split("\n")) {
    if (line.trim().startsWith("```")) { fence = !fence; continue; }
    if (fence) continue;
    for (const m of line.replace(/`[^`]*`/g, "").matchAll(/(?:^|[\s(])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)/gu)) {
      const tag = m[1].toLowerCase();
      if (!/^\p{N}+$/u.test(tag) && !tags.includes(tag)) tags.push(tag);
    }
  }
  return tags;
}

// ---------- Search (core/search.js; the page searches in a Worker, searchclient.js) ----------

export { KINDS, matchesFilters, parseQuery, terms } from "./search.js";

/** SearchQuery.matches for an item view. */
export const matchesQuery = (q, item, folders = null) => matchesFilters(q, itemDoc(item).meta, folders);

// One index for this page's synchronous searches (tests, the "connect to" box), updated per version of each item.
const shared = new TermIndex(ITEM_FIELDS);
const indexed = new Map(); // item id → the item view indexed

/** BM25 over weighted fields with the last word as a prefix, typos, phrases and operators (SearchIndex.swift). */
export function search(items, input, now = Date.now(), { folders = null, limit = Infinity } = {}) {
  const byId = new Map();
  for (const item of items) {
    byId.set(item.id, item);
    if (indexed.get(item.id) !== item) { shared.update(itemDoc(item)); indexed.set(item.id, item); }
  }
  const { hits } = shared.search(parseQuery(input), { scope: new Set(byId.keys()), now, limit: Math.min(limit, items.length), folders: folders && folderMap(folders) });
  return hits.map((h) => byId.get(h.id));
}

// ---------- Smart collections ----------

export const smartCollections = [
  ["all", "Everything", () => true],
  ["recent", "Recent", (i, now) => now - i.createdAt < 14 * 86_400_000],
  ["pinned", "Pinned", (i) => i.isPinned],
  ["toRead", "To Read", (i) => i.readAt === null && (i.category === "article" || (i.kind === "link" && i.category === "other"))],
  ["notes", "Notes", (i) => i.kind === "note"],
  ["sketches", "Sketches", (i) => i.kind === "sketch"],
  ["recipes", "Recipes", (i) => i.category === "recipe"],
  ["places", "Places", (i) => i.category === "place" || i.extracted.place !== undefined],
  ["thingsToBuy", "Things to Buy", (i) => i.category === "product"],
  ["events", "Events", (i) => i.category === "event"],
  ["videos", "Videos", (i) => i.category === "video" || i.kind === "video"],
  ["quotes", "Quotes & Highlights", (i) => i.kind === "highlight" || i.category === "quote"],
  ["handwriting", "Handwriting", (i) => i.sources.includes("goodnotes")],
  ["needsAttention", "Needs Attention", (i) => i.hasConflicts],
].map(([id, title, contains]) => ({ id, title, contains }));
