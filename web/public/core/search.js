// Full-text search shared by the page and the search Worker. Mirrors SearchIndex.swift: postings
// (term → doc ids) and a sorted vocabulary, BM25 over weighted fields, the last word matched as a
// prefix, one-edit typo tolerance for longer words, "phrases", operators, snippets with highlights
// and reciprocal rank fusion for "search by meaning". Search-cases.json keeps both sides in step.
// No imports, so the Worker loads only this file.

const stopwords = new Set(["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "i", "in", "is", "it",
  "its", "of", "on", "or", "that", "the", "this", "to", "was", "were", "will", "with", "you", "your", "my", "me", "we"]);

export const fold = (text) => text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();

/** Very light English stemming so "recipes" finds "recipe" and "boxes" finds "box". */
export function stem(w) {
  if (w.length <= 3 || !/^\p{L}+$/u.test(w)) return w;
  if (w.endsWith("ies") && w.length > 4) return w.slice(0, -3) + "y";
  for (const s of ["sses", "ches", "shes", "xes", "zes"]) if (w.endsWith(s)) return w.slice(0, -2);
  if (w.endsWith("s") && !w.endsWith("ss") && !w.endsWith("us") && !w.endsWith("is")) return w.slice(0, -1);
  return w;
}

const keep = (t) => !stopwords.has(t) && (t.length > 1 || /^\p{N}+$/u.test(t));

export function terms(text) {
  return (fold(text ?? "").match(/[\p{L}\p{N}]+/gu) ?? []).filter(keep).map(stem);
}

/** Length in code points (what "5 letters" means on both sides). */
const cpLength = (s) => { let n = 0; for (const _ of s) n++; return n; };

// ---------- the query ----------

export const KINDS = ["note", "link", "image", "pdf", "audio", "video", "file", "highlight", "email", "sketch"];
export const SOURCES = ["app", "share", "web", "email", "goodnotes", "kindle", "readwise", "obsidian", "appleNotes", "notion", "screenshot",
  "voice", "scan", "import", "clipboard"];
const HAS = ["ink", "audio", "file", "link"];

/** Splits the search box into tokens: words, `"phrases"`, `key:"quoted values"`, and `-` for excluding. */
function queryTokens(input) {
  const out = [];
  const n = input.length;
  const space = (c) => c === " " || c === "\t" || c === "\n";
  let i = 0;
  while (i < n) {
    if (space(input[i])) { i++; continue; }
    let neg = false;
    if (input[i] === "-" && i + 1 < n && !space(input[i + 1])) { neg = true; i++; }
    if (input[i] === '"') {
      let j = input.indexOf('"', i + 1);
      if (j < 0) j = n;
      out.push({ neg, phrase: input.slice(i + 1, j) });
      i = j + 1;
      continue;
    }
    let j = i;
    while (j < n && !space(input[j])) {
      if (input[j] === '"') { const k = input.indexOf('"', j + 1); j = k < 0 ? n : k + 1; } else j++;
    }
    out.push({ neg, raw: input.slice(i, j) });
    i = j;
  }
  return out;
}

/** `2026`, `2026-01` or `2026-01-31` → the start of that year, month or day (UTC, ms). */
export function parseDay(value) {
  const m = /^(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?$/.exec(value);
  if (!m) return null;
  const month = m[2] ? Number(m[2]) : 1, day = m[3] ? Number(m[3]) : 1;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return Date.UTC(Number(m[1]), month - 1, day);
}

/** The search box: free words, `"phrases"`, `-word`, `#tag`/`tag:`, `title:`, `in:` (collection or folder),
 *  `type:`, `from:`, `has:ink|audio|file|link`, `is:pinned|unread`, `before:`/`after:` (YYYY, YYYY-MM, YYYY-MM-DD). */
export function parseQuery(input) {
  const q = { text: "", phrases: [], title: [], exclude: [], excludePhrases: [], kinds: [], categories: [], tags: [], sources: [], collection: null, has: [],
    pinnedOnly: false, unreadOnly: false, after: null, before: null };
  const free = [];
  for (const t of queryTokens(input ?? "")) {
    if (t.phrase !== undefined) {
      const words = terms(t.phrase);
      if (t.neg) { if (words.length > 1) q.excludePhrases.push(words); else q.exclude.push(...words); } else if (words.length) q.phrases.push(words);
      continue;
    }
    const token = t.raw;
    if (t.neg) { q.exclude.push(...terms(token)); continue; }
    if (token.length > 1 && token.startsWith("#")) { q.tags.push(token.slice(1).toLowerCase()); continue; }
    const i = token.indexOf(":");
    const key = i > 0 ? token.slice(0, i).toLowerCase() : "";
    const rawValue = i > 0 ? token.slice(i + 1).replace(/"/g, "") : "";
    const value = rawValue.toLowerCase();
    if (!value) { free.push(token); continue; }
    if (key === "tag") q.tags.push(value.replace(/#/g, ""));
    else if (key === "type" || key === "kind") (KINDS.includes(value) ? q.kinds : q.categories).push(value);
    else if (key === "is") { if (value === "pinned") q.pinnedOnly = true; else if (value === "unread") q.unreadOnly = true; else q.categories.push(value); }
    else if (key === "from" || key === "source") {
      const s = SOURCES.find((x) => x.toLowerCase() === value);
      if (s) q.sources.push(s); else free.push(token);
    } else if (key === "in") q.collection = rawValue;
    else if (key === "title") q.title.push(...terms(rawValue));
    else if (key === "has" && HAS.includes(value)) q.has.push(value);
    else if (key === "after" || key === "before") q[key] = parseDay(value);
    else free.push(token);
  }
  q.text = free.join(" ");
  return q;
}

/** Whether the query asks for words (as opposed to only filters). */
export const hasWords = (q) => terms(q.text).length > 0 || q.phrases.length > 0 || q.title.length > 0;

// ---------- what's searched ----------

/** Item fields and their weights, in scoring order (SearchIndex.swift `itemFields`). */
export const ITEM_FIELDS = [["title", 3], ["tags", 2.5], ["summary", 1.5], ["site", 1.5], ["body", 1], ["ocr", 1], ["sketch", 1], ["ink", 1], ["host", 1]];
/** Where a snippet may come from, in order of preference. */
export const SNIPPET_FIELDS = ["body", "ocr", "ink", "sketch", "summary"];

/** A plain, cloneable search doc for an item view (core/items.js itemView). `inked`: it has strokes drawn on it. */
export function itemDoc(item, { inked = false } = {}) {
  const has = [];
  if (inked || item.kind === "sketch" || item.inkText || item.sources.includes("goodnotes") || item.goodnotesInk?.length) has.push("ink");
  if (item.kind === "audio" || item.attachments.some((a) => typeof a.mime === "string" && a.mime.startsWith("audio/"))) has.push("audio");
  if (item.attachments.length) has.push("file");
  if (item.url) has.push("link");
  return {
    id: item.id, v: item.record?.updatedHLC ?? "",
    fields: { title: item.title, tags: item.tags.join(" "), summary: item.summary ?? "", site: item.siteName ?? "", body: item.body,
      ocr: item.ocrText ?? "", sketch: item.sketchText ?? "", ink: item.inkText ?? "", host: item.url?.hostname ?? "" },
    meta: { kind: item.kind, category: item.category, tags: item.tags.map((t) => t.toLowerCase()), sources: item.sources, collections: item.collections,
      folder: item.folder, pinned: item.isPinned, unread: item.readAt === null, createdAt: item.createdAt, has },
  };
}

/** Clip fields (Clip.searchText, split by weight). */
export const CLIP_FIELDS = [["title", 3], ["tags", 2.5], ["text", 1], ["note", 1], ["summary", 1], ["ocr", 1], ["source", 1]];

export function clipDoc(clip) {
  return {
    id: clip.id, v: clip.record?.updatedHLC ?? "",
    fields: { title: [clip.displayTitle, clip.aiTitle ?? ""].join(" "), tags: clip.tags.join(" "), text: clip.text ?? "", note: clip.note ?? "",
      summary: clip.summary ?? "", ocr: clip.ocrText ?? "",
      source: [clip.sourceApp, clip.sourceTitle, clip.sourceURL, clip.sourceDevice, ...(clip.files ?? []), clip.image?.name].filter(Boolean).join(" ") },
    meta: { tags: clip.tags, app: fold(clip.sourceApp ?? ""), pinned: clip.isPinned, createdAt: clip.sortDate ?? 0 },
  };
}

/** ClipQuery filters (tag:, #, app:, is:pinned) over a clip doc's meta. */
export function clipFilter(cq) {
  return (m) => !(cq.pinnedOnly && !m.pinned) && cq.tags.every((t) => m.tags.includes(t)) && cq.apps.every((a) => m.app.includes(a));
}

/** A parsed ClipQuery (core/clips.js parseClipQuery) as an index query: its words, `-word` excluded.
 *  Search it with `prefixAll: true` (every word may be the start of one) and `filter: clipFilter(cq)`. */
export function clipIndexQuery(cq) {
  const q = parseQuery("");
  const words = [];
  for (const w of cq.words) { if (w.length > 1 && w.startsWith("-")) q.exclude.push(...terms(w.slice(1))); else words.push(w); }
  q.text = words.join(" ");
  return q;
}

// ---------- filters ----------

/** Folder `in:` matching: the item's folder or one it's inside has that id or name. */
function inFolder(value, folderId, folders) {
  if (!folderId || !folders) return false;
  const want = terms(value).join(" ");
  let id = folderId;
  for (let depth = 0; id && depth < 32; depth++) {
    const f = folders.get(id);
    if (id === value) return true;
    if (!f) return false;
    if (want && terms(f.name).join(" ") === want) return true;
    id = f.parent;
  }
  return false;
}

/** Whether an item doc's meta passes the query's filters (SearchQuery.matches). */
export function matchesFilters(q, m, folders = null) {
  if (q.kinds.length && !q.kinds.includes(m.kind)) return false;
  if (q.categories.length && !q.categories.includes(m.category)) return false;
  if (q.tags.length && !q.tags.every((t) => m.tags.includes(t))) return false;
  if (q.sources.length && !m.sources.some((s) => q.sources.includes(s))) return false;
  if (q.collection && !m.collections.includes(q.collection) && !inFolder(q.collection, m.folder, folders)) return false;
  if (q.pinnedOnly && !m.pinned) return false;
  if (q.unreadOnly && !m.unread) return false;
  if (q.after !== null && m.createdAt < q.after) return false;
  if (q.before !== null && m.createdAt >= q.before) return false;
  if (q.has.length && !q.has.every((x) => m.has.includes(x))) return false;
  return true;
}

/** Whether the query narrows by anything but words. */
export const hasFilters = (q) => Boolean(q.kinds.length || q.categories.length || q.tags.length || q.sources.length || q.collection || q.has.length ||
  q.pinnedOnly || q.unreadOnly || q.after !== null || q.before !== null);

/** `[{id, name, parent}]` → the Map `matchesFilters` wants. */
export const folderMap = (list) => new Map((list ?? []).map((f) => [f.id, { name: f.name, parent: f.parent ?? null }]));

// ---------- typo tolerance ----------

/** Whether two strings are at most one edit apart (insert, delete, substitute or swap two neighbours). */
export function withinOneEdit(a, b) {
  const x = [...a], y = [...b];
  if (Math.abs(x.length - y.length) > 1) return false;
  let i = 0;
  while (i < x.length && i < y.length && x[i] === y[i]) i++;
  const rest = (p, q) => { for (let k = 0; p + k < x.length || q + k < y.length; k++) if (x[p + k] !== y[q + k]) return false; return true; };
  if (x.length === y.length) {
    if (i === x.length) return true;
    if (rest(i + 1, i + 1)) return true;
    return i + 1 < x.length && x[i] === y[i + 1] && x[i + 1] === y[i] && rest(i + 2, i + 2);
  }
  return x.length < y.length ? rest(i, i + 1) : rest(i + 1, i);
}

// ---------- ranking ----------

/** Reciprocal rank fusion: each list adds 1/(k + rank); ties keep the order first seen. */
export function rrf(lists, k = 60) {
  const score = new Map(), order = [];
  for (const list of lists) {
    list.forEach((id, i) => {
      if (!score.has(id)) { score.set(id, 0); order.push(id); }
      score.set(id, score.get(id) + 1 / (k + i + 1));
    });
  }
  const seen = new Map(order.map((id, i) => [id, i]));
  return order.sort((a, b) => score.get(b) - score.get(a) || seen.get(a) - seen.get(b));
}

/** The best `k` of `items` by `better(a, b) < 0`, in order, without sorting everything. */
export function topK(items, k, cmp) {
  if (items.length <= k * 2) return items.sort(cmp).slice(0, k);
  // A max-heap (by cmp) of the best k so far: the root is the worst kept.
  const heap = [];
  const up = (i) => { while (i > 0) { const p = (i - 1) >> 1; if (cmp(heap[i], heap[p]) <= 0) break; [heap[i], heap[p]] = [heap[p], heap[i]]; i = p; } };
  const down = (i) => {
    for (;;) {
      const l = 2 * i + 1, r = l + 1;
      let m = i;
      if (l < heap.length && cmp(heap[l], heap[m]) > 0) m = l;
      if (r < heap.length && cmp(heap[r], heap[m]) > 0) m = r;
      if (m === i) return;
      [heap[i], heap[m]] = [heap[m], heap[i]];
      i = m;
    }
  };
  for (const it of items) {
    if (heap.length < k) { heap.push(it); up(heap.length - 1); } else if (cmp(it, heap[0]) < 0) { heap[0] = it; down(0); }
  }
  return heap.sort(cmp);
}

// ---------- the index ----------

/** At most this many longer words stand in for a prefix (the most common ones). */
export const MAX_PREFIX_TERMS = 64;


export class TermIndex {
  /** `fields`: [[name, weight]] in scoring order. */
  constructor(fields = ITEM_FIELDS) {
    this.fields = fields;
    this.docs = new Map();      // id → { id, v, fields, meta, terms, tfs, length, num, titleTerms }
    this.slots = [];            // doc number → doc, or null once removed (numbers are reused only by compact())
    this.postings = new Map();  // term → { df, docs: [doc number], tfs: [weighted frequency] } (removed docs linger until compact())
    this.dead = 0;
    this.totalLength = 0;
    this.vocab = [];
    this.byLength = null;
    this.stale = false;
  }

  get size() { return this.docs.size; }
  version(id) { return this.docs.get(id)?.v; }
  versions() { return [...this.docs.values()].map((d) => [d.id, d.v]); }

  update(doc) {
    const tf = new Map();
    for (const [name, w] of this.fields) for (const t of terms(doc.fields[name] ?? "")) tf.set(t, (tf.get(t) ?? 0) + w);
    this.insert(doc, tf);
  }

  insert(doc, tf) {
    this.remove(doc.id);
    let length = 0;
    for (const w of tf.values()) length += w;
    const entry = { id: doc.id, v: doc.v, fields: doc.fields, meta: doc.meta, terms: [...tf.keys()], tfs: [...tf.values()], length, num: this.slots.length, titleTerms: null };
    this.docs.set(doc.id, entry);
    this.slots.push(entry);
    this.totalLength += length;
    entry.terms.forEach((t, i) => this.post(t, entry.num, entry.tfs[i]));
  }

  post(t, num, w) {
    let p = this.postings.get(t);
    if (!p) { p = { df: 0, docs: [], tfs: [] }; this.postings.set(t, p); this.stale = true; }
    p.df++;
    p.docs.push(num);
    p.tfs.push(w);
  }

  remove(id) {
    const old = this.docs.get(id);
    if (!old) return;
    this.docs.delete(id);
    this.slots[old.num] = null;
    this.dead++;
    this.totalLength -= old.length;
    for (const t of old.terms) {
      const p = this.postings.get(t);
      if (p && --p.df === 0) { this.postings.delete(t); this.stale = true; }
    }
    if (this.dead > 256 && this.dead * 4 > this.slots.length) this.compact();
  }

  /** Renumbers the docs and drops removed ones from the postings. */
  compact() {
    const live = this.slots.filter(Boolean);
    this.slots = live;
    this.dead = 0;
    this.postings = new Map();
    live.forEach((d, num) => { d.num = num; d.terms.forEach((t, i) => this.post(t, num, d.tfs[i])); });
    this.stale = true;
  }

  /** Sorts the vocabulary after changes (cheap when nothing changed). */
  prepare() {
    if (!this.stale) return;
    this.vocab = [...this.postings.keys()].sort();
    this.byLength = null;
    this.stale = false;
  }

  /** Vocabulary terms starting with `prefix`, without `prefix` itself, in order. */
  withPrefix(prefix) {
    let lo = 0, hi = this.vocab.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (this.vocab[mid] < prefix) lo = mid + 1; else hi = mid; }
    const out = [];
    for (; lo < this.vocab.length && this.vocab[lo].startsWith(prefix); lo++) if (this.vocab[lo] !== prefix) out.push(this.vocab[lo]);
    return out;
  }

  /** Vocabulary terms one edit from `word`, in order. */
  nearby(word) {
    if (!this.byLength) {
      this.byLength = new Map();
      for (const t of this.vocab) { const n = cpLength(t); if (!this.byLength.has(n)) this.byLength.set(n, []); this.byLength.get(n).push(t); }
    }
    const n = cpLength(word), out = [];
    for (const len of [n - 1, n, n + 1]) for (const t of this.byLength.get(len) ?? []) if (withinOneEdit(word, t)) out.push(t);
    return out.sort();
  }

  /** What a query word can match: itself, longer words (`prefix`), or words one typo away. */
  matcher(word, { prefix = false, fuzzy = true } = {}) {
    const exact = this.postings.has(word);
    let pre = prefix && cpLength(word) >= 2 ? this.withPrefix(word) : [];
    if (pre.length > MAX_PREFIX_TERMS) {
      // A short start of a word ("re") could be thousands of words: the most common ones stand in for them.
      pre = pre.map((t) => [t, this.postings.get(t).df]).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
        .slice(0, MAX_PREFIX_TERMS).map(([t]) => t).sort();
    }
    const near = fuzzy && !exact && !pre.length && cpLength(word) >= 5 ? this.nearby(word) : [];
    return { word, exact, prefix: pre, prefixSet: new Set(pre), near, nearSet: new Set(near) };
  }

  /** The terms of `doc` a matcher matched, with their weight (1 exact, 0.7 prefix, 0.5 typo), in order. */
  matched(doc, m) {
    const has = new Set(doc.terms);
    if (m.exact && has.has(m.word)) return [[m.word, 1]];
    const out = [];
    for (const t of m.prefix) if (has.has(t)) out.push([t, 0.7]);
    if (out.length) return out;
    for (const t of m.near) if (has.has(t)) out.push([t, 0.5]);
    return out;
  }

  titleTerms(doc) {
    if (!doc.titleTerms) doc.titleTerms = new Set(terms(doc.fields.title ?? ""));
    return doc.titleTerms;
  }

  inTitle(doc, m) {
    for (const t of this.titleTerms(doc)) if (t === m.word || m.prefixSet.has(t) || m.nearSet.has(t)) return true;
    return false;
  }

  /** Whether `phrase` (terms) appears word for word in one of the doc's fields. */
  hasPhrase(doc, phrase) {
    for (const [name] of this.fields) {
      const seq = terms(doc.fields[name] ?? "");
      outer: for (let i = 0; i + phrase.length <= seq.length; i++) {
        for (let j = 0; j < phrase.length; j++) if (seq[i + j] !== phrase[j]) continue outer;
        return true;
      }
    }
    return false;
  }

  /** The words of a parsed query as matchers: free words (last one a prefix), phrase words, title words (30 at most). */
  plan(q, { prefixAll = false } = {}) {
    this.prepare();
    const words = terms(q.text);
    const ms = words.map((w, i) => ({ m: this.matcher(w, { prefix: prefixAll || i === words.length - 1 }), title: false }));
    for (const phrase of q.phrases) for (const w of phrase) ms.push({ m: this.matcher(w, { fuzzy: false }), title: false });
    for (const w of q.title) ms.push({ m: this.matcher(w, { prefix: true }), title: true });
    return { q, ms: ms.slice(0, 30), exclude: q.exclude ?? [], excludePhrases: q.excludePhrases ?? [], phrases: q.phrases ?? [] };
  }

  /**
   * Searches, scoring only the docs that contain every word. Options: `filter(meta)` (defaults to the
   * item filters), `folders` (for in:), `scope` (Set of ids), `limit`, `now`, `prefixAll`, and `semantic`
   * ([[id, score]] best first, already thresholded) to fuse with reciprocal rank fusion.
   * Returns `{ hits: [{id, score}], total, plan }`.
   */
  search(q, o = {}) {
    const plan = this.plan(q, o);
    const filter = o.filter ?? (hasFilters(q) ? (m) => matchesFilters(q, m, o.folders ?? null) : null);
    const scope = o.scope ?? null, limit = o.limit ?? 100, now = o.now ?? Date.now();
    const { ms } = plan;
    const slots = this.slots, N = slots.length;
    const n = Math.max(this.docs.size, 1), avg = Math.max(this.totalLength / n, 1);

    // Excluded words: their docs are marked once, from the postings.
    let excluded = null;
    for (const t of plan.exclude) {
      const p = this.postings.get(t);
      if (!p) continue;
      excluded ??= new Uint8Array(N);
      for (const num of p.docs) excluded[num] = 1;
    }
    const passes = (doc) => {
      if (excluded && excluded[doc.num]) return false;
      if (scope && !scope.has(doc.id)) return false;
      if (filter && !filter(doc.meta)) return false;
      for (const p of plan.excludePhrases) if (this.hasPhrase(doc, p)) return false;
      return true;
    };

    let found = []; // doc numbers
    let acc = null;
    if (!ms.length) {
      for (let num = 0; num < N; num++) { const doc = slots[num]; if (doc && passes(doc)) found.push(num); }
    } else if (ms.every(({ m }) => m.exact || m.prefix.length || m.near.length)) {
      // Term at a time: each word's postings add to every doc's score, in word order (as SearchIndex.swift
      // adds them doc by doc), and set that word's bit. Docs with every bit are the candidates.
      acc = new Float64Array(N);
      const mask = new Uint32Array(N), exactOf = new Uint8Array(N);
      const touched = [];
      ms.forEach(({ m }, i) => {
        const bit = 1 << i, before = bit - 1;
        const add = (t, mult, skipExact) => {
          const p = this.postings.get(t);
          const idf = Math.log(1 + (n - p.df + 0.5) / (p.df + 0.5));
          const { docs, tfs } = p;
          for (let k = 0; k < docs.length; k++) {
            const num = docs[k], doc = slots[num];
            if (!doc || (mask[num] & before) !== before || (skipExact && exactOf[num] === i + 1)) continue;
            const tf = tfs[k] * mult;
            acc[num] += idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * doc.length / avg));
            if (!(mask[num] & bit)) { mask[num] |= bit; if (i === 0) touched.push(num); }
            if (!skipExact && mult === 1) exactOf[num] = i + 1;
          }
        };
        if (m.exact) add(m.word, 1, false);
        for (const t of m.prefix) add(t, 0.7, true);
        for (const t of m.near) add(t, 0.5, true);
      });
      const full = ms.length === 32 ? 0xffffffff : (1 << ms.length) - 1;
      for (const num of touched) {
        if (mask[num] !== full) continue;
        const doc = slots[num];
        if (!passes(doc)) continue;
        if (ms.some((x) => x.title && !this.inTitle(doc, x.m))) continue;
        if (plan.phrases.length && !plan.phrases.every((p) => p.length < 2 || this.hasPhrase(doc, p))) continue;
        if (doc.meta.pinned) acc[num] += 0.25;
        acc[num] += Math.max(0, 0.5 - (now - doc.meta.createdAt) / 86_400_000 / 60);
        found.push(num);
      }
    }
    const date = (num) => slots[num].meta.createdAt;
    const idOrder = (a, b) => { const x = slots[a].id, y = slots[b].id; return x < y ? -1 : x > y ? 1 : 0; };
    const cmp = acc ? (a, b) => acc[b] - acc[a] || date(b) - date(a) || idOrder(a, b) : (a, b) => date(b) - date(a) || idOrder(a, b);
    const hit = (num) => ({ id: slots[num].id, score: acc ? acc[num] : 0 });
    if (o.semantic?.length) {
      const keyword = topK(found, Math.max(limit, 200), cmp).map((num) => slots[num].id);
      const meaning = [];
      for (const [id] of o.semantic) { const doc = this.docs.get(id); if (doc && passes(doc)) meaning.push(id); if (meaning.length >= 200) break; }
      const fused = rrf([keyword, meaning]);
      const all = new Set(meaning);
      for (const num of found) all.add(slots[num].id);
      return { hits: fused.slice(0, limit).map((id) => ({ id, score: 0 })), total: all.size, plan };
    }
    return { hits: topK(found, limit, cmp).map(hit), total: found.length, plan };
  }

  /** The matching words of one result, shown in a few lines of its text: `{ field, text, ranges: [[start, end]] }` or null. */
  snippet(id, plan, { width = 160, fields = SNIPPET_FIELDS } = {}) {
    const doc = this.docs.get(id);
    if (!doc) return null;
    const words = new Set();
    for (const { m } of plan.ms) for (const [t] of this.matched(doc, m)) words.add(t);
    if (!words.size) return null;
    for (const field of fields) {
      const s = snippet(doc.fields[field] ?? "", words, width);
      if (s) return { field, ...s };
    }
    return null;
  }

  toJSON() {
    return { fields: this.fields.map(([f]) => f), docs: [...this.docs.values()].map((d) => [d.id, d.v, d.fields, d.meta, d.terms.map((t, i) => [t, d.tfs[i]])]) };
  }

  /** Loads a saved index without tokenizing anything again. */
  static fromJSON(json, fields) {
    const index = new TermIndex(fields);
    if (json?.fields?.join() !== fields.map(([f]) => f).join()) return index;
    for (const [id, v, f, meta, tf] of json.docs ?? []) index.insert({ id, v, fields: f, meta }, new Map(tf));
    return index;
  }
}

// ---------- snippets ----------

/** The words of `text` with where they are (UTF-16 offsets) and their search term. */
function* wordSpans(text) {
  for (const m of text.matchAll(/[\p{L}\p{N}]+/gu)) {
    const t = terms(m[0])[0];
    yield { start: m.index, end: m.index + m[0].length, term: t ?? null };
  }
}

/**
 * A short passage of `text` around the first word whose term is in `words`, with every such word
 * marked: `{ text, ranges: [[start, end]] }` (UTF-16 offsets into the returned text), or null.
 * Whitespace runs become one space; "…" marks cut ends.
 */
export function snippet(text, words, width = 160) {
  if (!text) return null;
  let first = null;
  for (const w of wordSpans(text)) if (w.term && words.has(w.term)) { first = w; break; }
  if (!first) return null;
  const isWord = (c) => c !== undefined && /[\p{L}\p{N}]/u.test(c);
  // Start at a whole word up to 40 characters before the match.
  let start = Math.max(0, first.start - 40);
  if (start > 0) {
    if (isWord(text[start - 1])) while (start < first.start && isWord(text[start])) start++;
    while (start < first.start && !isWord(text[start])) start++;
  }
  // End before a word that would be cut.
  let end = Math.min(text.length, start + width);
  if (end < text.length) while (end > first.end && isWord(text[end]) && isWord(text[end - 1])) end--;
  const raw = text.slice(start, end);
  // Collapse whitespace, keeping a map from the new offsets back to `raw`.
  let out = "";
  let lastSpace = false;
  const map = []; // raw offset → out offset
  for (let i = 0; i < raw.length; i++) {
    map[i] = out.length;
    const c = raw[i];
    if (/\s/.test(c)) { if (!lastSpace) out += " "; lastSpace = true; } else { out += c; lastSpace = false; }
  }
  map[raw.length] = out.length;
  const lead = out.length - out.trimStart().length;
  out = out.trim();
  const ranges = [];
  for (const w of wordSpans(raw)) if (w.term && words.has(w.term)) ranges.push([map[w.start] - lead, map[w.end] - lead]);
  const before = start > 0 ? "…" : "", after = end < text.length ? "…" : "";
  return { text: before + out + after, ranges: ranges.map(([a, b]) => [a + before.length, b + before.length]) };
}
