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

/** A read-only view of an item record (Item.swift). */
export function itemView(record) {
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
    summary: str(f.summary),
    tags: Array.isArray(f.tags) ? f.tags.filter((t) => typeof t === "string") : [],
    createdAt: typeof f.createdAt === "number" ? f.createdAt : 0,
    collections: Array.isArray(f.collections) ? f.collections : [],
    isPinned: f.pinned === true,
    readAt: typeof f.readAt === "number" ? f.readAt : null,
    ocrText: str(f.ocrText), siteName: str(f.siteName), imageURL: str(f.imageURL),
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
  item.displayTitle = title || body.split("\n").find((l) => l.trim())?.slice(0, 80) || url?.host || "Untitled";
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

// ---------- Search ----------

const stopwords = new Set(["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "i", "in", "is", "it",
  "its", "of", "on", "or", "that", "the", "this", "to", "was", "were", "will", "with", "you", "your", "my", "me", "we"]);

function stem(w) {
  if (w.length <= 3 || !/^\p{L}+$/u.test(w)) return w;
  if (w.endsWith("ies") && w.length > 4) return w.slice(0, -3) + "y";
  for (const s of ["sses", "ches", "shes", "xes", "zes"]) if (w.endsWith(s)) return w.slice(0, -2);
  if (w.endsWith("s") && !w.endsWith("ss") && !w.endsWith("us") && !w.endsWith("is")) return w.slice(0, -1);
  return w;
}

export function terms(text) {
  const folded = text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  return (folded.match(/[\p{L}\p{N}]+/gu) ?? [])
    .filter((t) => !stopwords.has(t) && (t.length > 1 || /^\p{N}+$/u.test(t)))
    .map(stem);
}

export function parseQuery(input) {
  const q = { text: "", kinds: [], categories: [], tags: [], sources: [], collection: null, pinnedOnly: false, unreadOnly: false, after: null, before: null };
  const free = [];
  for (const token of input.split(" ").filter(Boolean)) {
    const i = token.indexOf(":");
    const key = i > 0 ? token.slice(0, i).toLowerCase() : "", value = i > 0 ? token.slice(i + 1).toLowerCase() : "";
    if (!value) { free.push(token); continue; }
    if (key === "tag") q.tags.push(value.replace("#", ""));
    else if (key === "type" || key === "kind") (KINDS.includes(value) ? q.kinds : q.categories).push(value);
    else if (key === "is") value === "pinned" ? (q.pinnedOnly = true) : value === "unread" ? (q.unreadOnly = true) : q.categories.push(value);
    else if (key === "from" || key === "source") q.sources.push(value);
    else if (key === "in") q.collection = token.slice(i + 1);
    else if (key === "after" || key === "before") q[key] = Date.parse(value + "T00:00:00Z") || null;
    else free.push(token);
  }
  q.text = free.join(" ");
  return q;
}

const KINDS = ["note", "link", "image", "pdf", "audio", "video", "file", "highlight", "email"];

export function matchesQuery(q, item) {
  if (q.kinds.length && !q.kinds.includes(item.kind)) return false;
  if (q.categories.length && !q.categories.includes(item.category)) return false;
  if (q.tags.length && !q.tags.every((t) => item.tags.map((x) => x.toLowerCase()).includes(t))) return false;
  if (q.sources.length && !q.sources.includes(item.source.toLowerCase())) return false;
  if (q.collection && !item.collections.includes(q.collection)) return false;
  if (q.pinnedOnly && !item.isPinned) return false;
  if (q.unreadOnly && item.readAt !== null) return false;
  if (q.after && item.createdAt < q.after) return false;
  if (q.before && item.createdAt >= q.before) return false;
  return true;
}

/** BM25 over weighted fields with a prefix match on the last word, like SearchIndex.swift. */
export function search(items, input, now = Date.now()) {
  const q = parseQuery(input);
  const words = terms(q.text);
  const docs = items.map((item) => {
    const tf = new Map();
    const add = (text, w) => { for (const t of terms(text ?? "")) tf.set(t, (tf.get(t) ?? 0) + w); };
    add(item.title, 3); add(item.tags.join(" "), 2.5); add(item.summary, 1.5); add(item.siteName, 1.5);
    add(item.body, 1); add(item.ocrText, 1); add(item.url?.host, 1);
    return { item, tf, length: [...tf.values()].reduce((a, b) => a + b, 0) };
  });
  const n = Math.max(docs.length, 1);
  const avg = docs.reduce((s, d) => s + d.length, 0) / n;
  const df = new Map();
  for (const d of docs) for (const t of d.tf.keys()) df.set(t, (df.get(t) ?? 0) + 1);
  const hits = [];
  for (const doc of docs) {
    if (!matchesQuery(q, doc.item)) continue;
    let score = 0, ok = true;
    words.forEach((w, i) => {
      let matched = doc.tf.has(w) ? [[w, doc.tf.get(w)]] : [];
      if (!matched.length && i === words.length - 1 && w.length >= 2) {
        matched = [...doc.tf].filter(([t]) => t.startsWith(w)).map(([t, v]) => [t, v * 0.7]);
      }
      if (!matched.length) ok = false;
      for (const [t, tf] of matched) {
        const d = df.get(t) ?? 1;
        score += Math.log(1 + (n - d + 0.5) / (d + 0.5)) * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * doc.length / Math.max(avg, 1)));
      }
    });
    if (!ok) continue;
    if (doc.item.isPinned) score += 0.25;
    score += Math.max(0, 0.5 - (now - doc.item.createdAt) / 86_400_000 / 60);
    hits.push({ item: doc.item, score });
  }
  hits.sort((a, b) => (words.length && a.score !== b.score ? b.score - a.score : b.item.createdAt - a.item.createdAt));
  return hits.map((h) => h.item);
}

// ---------- Smart collections ----------

export const smartCollections = [
  ["all", "Everything", () => true],
  ["recent", "Recent", (i, now) => now - i.createdAt < 14 * 86_400_000],
  ["pinned", "Pinned", (i) => i.isPinned],
  ["toRead", "To Read", (i) => i.readAt === null && (i.category === "article" || (i.kind === "link" && i.category === "other"))],
  ["notes", "Notes", (i) => i.kind === "note"],
  ["recipes", "Recipes", (i) => i.category === "recipe"],
  ["places", "Places", (i) => i.category === "place" || i.extracted.place !== undefined],
  ["thingsToBuy", "Things to Buy", (i) => i.category === "product"],
  ["events", "Events", (i) => i.category === "event"],
  ["videos", "Videos", (i) => i.category === "video" || i.kind === "video"],
  ["quotes", "Quotes & Highlights", (i) => i.kind === "highlight" || i.category === "quote"],
  ["handwriting", "Handwriting", (i) => i.source === "goodnotes"],
  ["needsAttention", "Needs Attention", (i) => i.hasConflicts],
].map(([id, title, contains]) => ({ id, title, contains }));
