// Import routing for the web app: a port of TroveCore's FileImport, ZipArchive and importers
// (Import/FileImport.swift, Zip.swift, Importers.swift, ObsidianMirror.parse). Keep them in step;
// web/test runs the same zip fixture as FileImportTests.swift.
import { cleanURL, dedupeKey, hashtags } from "./items.js";
import { hex, utf8 } from "./bytes.js";

export const MAX_NESTING = 3;
export const MAX_UNZIPPED = 2_000_000_000;
const MAX_TEXT_NOTE = 1_000_000;

/**
 * What to do with one file: `{type: "items", items}`, `{type: "note", title, body, tags}` or
 * `{type: "file", name, bytes, mime}`. Zips (and zips inside zips) are opened.
 */
export async function importActions(name, bytes) {
  const budget = { left: MAX_UNZIPPED };
  return actionsFor(name, bytes, 0, budget);
}

async function actionsFor(name, bytes, depth, budget) {
  const ext = extension(name);
  const base = ext ? name.slice(0, -(ext.length + 1)) : name;
  const file = { type: "file", name, bytes, mime: mimeFor(ext) };
  const text = () => new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  switch (ext) {
    case "zip": {
      if (depth >= MAX_NESTING) return [file];
      let zip;
      try { zip = readZip(bytes); } catch { return [file]; }
      const out = [];
      for (const entry of zip.entries) {
        if (entry.isDirectory || entry.encrypted || isJunk(entry.path) || entry.size > budget.left) continue;
        let contents;
        try { contents = await zip.data(entry); } catch { continue; }
        budget.left -= contents.length;
        out.push(...await actionsFor(entry.name, contents, depth + 1, budget));
      }
      return out;
    }
    case "txt": {
      let t;
      try { t = text(); } catch { return [file]; }
      if (name.toLowerCase().includes("clippings")) {
        const highlights = await kindleClippings(t);
        if (highlights.length) return [{ type: "items", items: highlights }];
      }
      if (bytes.length > MAX_TEXT_NOTE || !t.trim()) return [file];
      return [{ type: "note", title: base, body: t, tags: [] }];
    }
    case "md": case "markdown": {
      let t;
      try { t = text(); } catch { return [file]; }
      const note = parseMarkdownNote(t, name);
      return [{ type: "note", title: note.title, body: note.body, tags: note.tags }];
    }
    case "html": case "htm": {
      const marks = netscapeBookmarks(new TextDecoder().decode(bytes));
      return marks.length ? [{ type: "items", items: marks }] : [file];
    }
    case "csv": {
      const links = csvLinks(new TextDecoder().decode(bytes));
      return links.length ? [{ type: "items", items: links }] : [file];
    }
    case "json": {
      try {
        const highlights = readwiseExport(JSON.parse(new TextDecoder().decode(bytes)));
        if (highlights.length) return [{ type: "items", items: highlights }];
      } catch { /* not Readwise */ }
      return [file];
    }
    default:
      return [file];
  }
}

/** How many things a list of actions adds. */
export function countActions(actions) {
  return actions.reduce((n, a) => n + (a.type === "items" ? a.items.length : 1), 0);
}

export function isJunk(path) {
  const parts = path.split("/").filter(Boolean);
  if (parts.some((p) => p === "__MACOSX" || p.startsWith("."))) return true;
  return ["Thumbs.db", "desktop.ini"].includes(parts.at(-1) ?? "");
}

const extension = (name) => { const m = /\.([^./]+)$/.exec(name); return m ? m[1].toLowerCase() : ""; };

const MIME = {
  pdf: "application/pdf", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", heic: "image/heic", gif: "image/gif",
  webp: "image/webp", svg: "image/svg+xml", m4a: "audio/m4a", mp3: "audio/mpeg", wav: "audio/wav", mov: "video/quicktime",
  mp4: "video/mp4", txt: "text/plain", md: "text/markdown", markdown: "text/markdown", html: "text/html", htm: "text/html",
  csv: "text/csv", json: "application/json", zip: "application/zip", epub: "application/epub+zip", doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  key: "application/vnd.apple.keynote", pages: "application/vnd.apple.pages", numbers: "application/vnd.apple.numbers",
};
export const mimeFor = (ext) => MIME[ext.toLowerCase()] ?? "application/octet-stream";

// ---------- Zip ----------

export function isZip(bytes) {
  return bytes[0] === 0x50 && bytes[1] === 0x4b && (bytes[2] === 3 || bytes[2] === 5);
}

/** Reads the central directory; `data(entry)` inflates one entry and checks its CRC. */
export function readZip(bytes) {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u16 = (i) => v.getUint16(i, true), u32 = (i) => v.getUint32(i, true);
  const u64 = (i) => Number(v.getBigUint64(i, true));
  if (bytes.length < 22) throw new Error("not a zip");
  let eocd = bytes.length - 22;
  const floor = Math.max(0, bytes.length - 65_557);
  while (eocd >= floor && u32(eocd) !== 0x06054b50) eocd--;
  if (eocd < floor) throw new Error("not a zip");
  let count = u16(eocd + 10), offset = u32(eocd + 16);
  if (count === 0xffff || offset === 0xffffffff) {
    const locator = eocd - 20;
    if (locator < 0 || u32(locator) !== 0x07064b50) throw new Error("corrupt zip");
    const end = u64(locator + 8);
    if (end + 56 > bytes.length || u32(end) !== 0x06064b50) throw new Error("corrupt zip");
    count = u64(end + 32);
    offset = u64(end + 48);
  }
  const entries = [];
  let p = offset;
  for (let n = 0; n < count; n++) {
    if (p + 46 > bytes.length || u32(p) !== 0x02014b50) throw new Error("corrupt zip");
    const flags = u16(p + 8), nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32);
    const raw = bytes.subarray(p + 46, p + 46 + nameLen);
    let path;
    try { path = new TextDecoder("utf-8", { fatal: true }).decode(raw); } catch { path = new TextDecoder("latin1").decode(raw); }
    let csize = u32(p + 20), size = u32(p + 24), local = u32(p + 42);
    for (let e = p + 46 + nameLen, end = e + extraLen; e + 4 <= end; e += 4 + u16(e + 2)) {
      if (u16(e) !== 0x0001) continue;
      let q = e + 4;
      if (size === 0xffffffff && q + 8 <= end) { size = u64(q); q += 8; }
      if (csize === 0xffffffff && q + 8 <= end) { csize = u64(q); q += 8; }
      if (local === 0xffffffff && q + 8 <= end) local = u64(q);
    }
    entries.push({ path, name: path.split("/").filter(Boolean).at(-1) ?? path, method: u16(p + 10), crc: u32(p + 16), csize, size,
      encrypted: (flags & 1) !== 0, isDirectory: path.endsWith("/"), local });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return {
    entries,
    async data(entry) {
      const h = entry.local;
      if (h + 30 > bytes.length || u32(h) !== 0x04034b50) throw new Error("corrupt zip");
      const start = h + 30 + u16(h + 26) + u16(h + 28);
      const raw = bytes.subarray(start, start + entry.csize);
      let out;
      if (entry.method === 0) out = raw.slice();
      else if (entry.method === 8) out = await inflateRaw(raw);
      else throw new Error(`compression method ${entry.method}`);
      if (out.length !== entry.size || crc32(out) !== entry.crc) throw new Error("corrupt zip entry");
      return out;
    },
  };
}

async function inflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// ---------- Importers (Importers.swift) ----------

const item = (fields) => ({ body: "", url: null, tags: [], createdAt: null, author: null, collection: null, externalId: null, ...fields });

async function sha256Hex(text) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8.encode(text))));
}

/** Kindle "My Clippings.txt": highlights and notes, grouped by book; bookmarks skipped, repeats de-duped. */
export async function kindleClippings(text) {
  const clean = text.replaceAll("﻿", "").replaceAll("\r\n", "\n");
  const items = [], seen = new Set();
  for (const entry of clean.split("==========")) {
    const lines = entry.split("\n").map((l) => l.trim());
    const start = lines.findIndex((l) => l !== "");
    if (start < 0) continue;
    const content = lines.slice(start);
    if (content.length < 2) continue;
    const [header, info] = content;
    const body = content.slice(2).filter(Boolean).join("\n");
    if (!body || info.toLowerCase().includes("bookmark")) continue;
    const [book, author] = splitAuthor(header);
    const isNote = info.toLowerCase().includes("your note");
    const location = /(?:Location|location|Loc\.)\s*([0-9-]+)/i.exec(info)?.[1];
    const page = /[Pp]age\s*([0-9ivxlc-]+)/i.exec(info)?.[1];
    const added = info.includes("Added on") ? kindleDate(info.split("Added on").at(-1).trim()) : null;
    const key = `${book}|${body}`;
    if (seen.has(key)) continue;
    seen.add(key);
    let ref = [page && `p. ${page}`, location && `loc. ${location}`].filter(Boolean).join(", ");
    if (ref) ref = ` (${ref})`;
    items.push(item({ kind: "highlight", source: "kindle", title: book,
      body: isNote ? `Note: ${body}` : `> ${body}\n\n— ${author ?? book}${ref}`, tags: isNote ? ["kindle", "note"] : ["kindle"],
      createdAt: added, author, collection: book, externalId: `kindle:${(await sha256Hex(key)).slice(0, 16)}` }));
  }
  return items;
}

function splitAuthor(header) {
  const open = header.lastIndexOf("(");
  if (!header.endsWith(")") || open < 0) return [header, null];
  const title = header.slice(0, open).trim(), author = header.slice(open + 1, -1).trim();
  return [title || header, author || null];
}

const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

function kindleDate(s) {
  const m = /^\w+, (?:(\d{1,2}) (\w+)|(\w+) (\d{1,2}),) (\d{4}) (\d{1,2}):(\d{2}):(\d{2})(?: ([AP]M))?$/i.exec(s);
  if (!m) return null;
  const month = MONTHS.indexOf((m[2] ?? m[3]).toLowerCase());
  if (month < 0) return null;
  let hour = Number(m[6]);
  if (m[9]) hour = (hour % 12) + (m[9].toUpperCase() === "PM" ? 12 : 0);
  return new Date(Number(m[5]), month, Number(m[1] ?? m[4]), hour, Number(m[7]), Number(m[8])).getTime();
}

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, name) => {
    if (name.startsWith("#x")) return String.fromCodePoint(parseInt(name.slice(2), 16));
    if (name.startsWith("#")) return String.fromCodePoint(Number(name.slice(1)));
    return ENTITIES[name.toLowerCase()] ?? whole;
  });
}

function attributes(tag) {
  const out = {};
  for (const m of tag.matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/g)) {
    out[m[1].toLowerCase()] = m[3] ?? m[4] ?? m[5] ?? "";
  }
  return out;
}

const epoch = (n) => (n > 1e11 ? n : n * 1000);

/** Browser bookmarks (Netscape HTML: Safari, Chrome, Firefox, Pocket, Raindrop exports). */
export function netscapeBookmarks(html) {
  const items = [], folders = [];
  for (const m of html.matchAll(/<DT><H3[^>]*>([\s\S]*?)<\/H3>|<\/DL>|<DT><A\b([^>]*)>([\s\S]*?)<\/A>/gi)) {
    if (m[1] !== undefined) folders.push(decodeEntities(m[1]).trim());
    else if (m[0].toLowerCase() === "</dl>") folders.pop();
    else if (m[2] !== undefined) {
      const attrs = attributes(`<a ${m[2]}>`);
      const href = attrs.href;
      if (!href?.startsWith("http")) continue;
      const title = decodeEntities(m[3]).trim();
      const added = attrs.add_date && !Number.isNaN(Number(attrs.add_date)) ? epoch(Number(attrs.add_date)) : null;
      const tags = (attrs.tags ?? "").split(",").map((t) => t.trim().toLowerCase()).filter(Boolean);
      items.push(item({ kind: "link", source: "import", title: title || href, url: href, tags, createdAt: added,
        collection: folders.at(-1) ?? null, externalId: `url:${safeKey(href)}` }));
    }
  }
  return items;
}

function safeKey(url) {
  try { return dedupeKey(cleanURL(url).toString()); } catch { return url; }
}

/** RFC 4180 rows: quoted fields, escaped quotes, newlines inside quotes. */
export function csvRows(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  const s = text.replaceAll("\r\n", "\n").replace(/^﻿/, "");
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quoted) {
      if (c === "\"") { if (s[i + 1] === "\"") { field += "\""; i++; } else quoted = false; } else field += c;
    } else if (c === "\"") quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
    else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => !(r.length === 1 && r[0] === ""));
}

/** Links from Raindrop, Pocket and similar CSV exports (column names as in CSVImport.importLinks). */
export function csvLinks(text) {
  const all = csvRows(text);
  const header = all[0]?.map((h) => h.trim().toLowerCase());
  if (!header) return [];
  const col = (...names) => names.map((n) => header.indexOf(n)).find((i) => i >= 0);
  const urlCol = col("url", "link", "href");
  if (urlCol === undefined) return [];
  const titleCol = col("title", "name"), noteCol = col("note", "excerpt", "description", "content");
  const tagsCol = col("tags", "tag"), folderCol = col("folder", "collection", "list");
  const dateCol = col("created", "time_added", "date", "created_at", "added");
  const out = [];
  for (const r of all.slice(1)) {
    const value = (i) => (i !== undefined && i < r.length ? r[i].trim() : "");
    const url = value(urlCol);
    if (!url.startsWith("http")) continue;
    const tags = value(tagsCol).split(/[,|]/).map((t) => t.trim().toLowerCase()).filter(Boolean);
    const raw = value(dateCol);
    const date = raw && !Number.isNaN(Number(raw)) ? epoch(Number(raw)) : (raw && /^\d{4}-\d{2}-\d{2}T/.test(raw) ? Date.parse(raw) || null : null);
    out.push(item({ kind: "link", source: "import", title: value(titleCol) || url, body: value(noteCol), url, tags, createdAt: date,
      collection: value(folderCol) || null, externalId: `url:${safeKey(url)}` }));
  }
  return out;
}

/** Readwise export API (v2 /export) JSON. */
export function readwiseExport(page) {
  if (!Array.isArray(page?.results)) return [];
  return page.results.flatMap((book) => (book.highlights ?? []).map((h) => {
    let body = `> ${h.text}`;
    if (h.note) body += `\n\n${h.note}`;
    body += `\n\n— ${book.author ?? book.title ?? ""}`;
    return item({ kind: "highlight", source: "readwise", title: book.title ?? "Highlight", body, url: book.source_url ?? null,
      tags: ["readwise", ...(h.tags ?? []).map((t) => t.name.toLowerCase())],
      createdAt: h.highlighted_at ? Date.parse(h.highlighted_at) || null : null, author: book.author ?? null,
      collection: book.title ?? null, externalId: `readwise:${h.id}` });
  }));
}

// ---------- Markdown notes (Markdown.parse + ObsidianMirror.parse) ----------

const unquote = (s) => (s.length >= 2 && ((s[0] === "\"" && s.at(-1) === "\"") || (s[0] === "'" && s.at(-1) === "'")) ? s.slice(1, -1) : s);

export function parseFrontMatter(text) {
  const s = text.replaceAll("\r\n", "\n");
  if (!s.startsWith("---\n")) return { fm: {}, body: s };
  const rest = s.slice(4);
  let end = rest.indexOf("\n---\n"), skip = 5;
  if (end < 0 && rest.endsWith("\n---")) { end = rest.length - 4; skip = 4; }
  if (end < 0) return { fm: {}, body: s };
  let body = rest.slice(end + skip);
  if (body.startsWith("\n")) body = body.slice(1);
  const fm = {};
  let current = null;
  for (const line of rest.slice(0, end).split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    if (t.startsWith("- ") && current) { fm[current] = [...asList(fm[current]), unquote(t.slice(2))]; continue; }
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = line.slice(0, colon).trim(), value = line.slice(colon + 1).trim();
    current = key;
    if (!value) fm[key] = [];
    else if (value.startsWith("[") && value.endsWith("]")) fm[key] = value.slice(1, -1).split(",").map((v) => unquote(v.trim())).filter(Boolean);
    else fm[key] = unquote(value);
  }
  return { fm, body };
}

const asList = (v) => (Array.isArray(v) ? v : typeof v === "string" ? v.split(",").map((x) => x.trim()).filter(Boolean) : []);

export function parseMarkdownNote(text, fileName) {
  const { fm, body: raw } = parseFrontMatter(text);
  let body = raw;
  let title = typeof fm.title === "string" ? fm.title : "";
  const first = body.split("\n").find((l) => l !== "");
  const heading = first?.startsWith("# ") ? first.slice(2).trim() : null;
  if (heading) {
    if (!title) title = heading;
    const at = body.indexOf(`# ${heading}`);
    if (heading === title && at >= 0) body = (body.slice(0, at) + body.slice(at + heading.length + 2)).replace(/^\n+/, "");
  }
  if (!title) title = fileName.endsWith(".md") ? fileName.slice(0, -3) : fileName;
  const tags = asList(fm.tags).map((t) => t.toLowerCase().replaceAll("#", ""));
  for (const t of hashtags(body)) if (!tags.includes(t)) tags.push(t);
  if (body.endsWith("\n")) body = body.slice(0, -1);
  return { title, tags, body };
}
