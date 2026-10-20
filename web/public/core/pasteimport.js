// Import from Paste (pasteapp.io), which has no export: its Core Data database, read directly
// (sqlite.js, bplist.js). Newer Paste keeps `db.sqlite` (ZITEMENTITY rows, ZITEMDATAENTITY
// pasteboard blobs, ZAPPLICATIONENTITY apps, ZLISTENTITY pinboards); older Paste `Paste.db`
// (ZSNIPPET). Neither layout is documented, so tables and columns are found by their names and
// contents, and anything that can't be read is skipped and counted.
import { decodeBlob } from "./bplist.js";
import { SQLiteFile } from "./sqlite.js";

const utf8 = new TextDecoder("utf-8", { fatal: true }), utf16le = new TextDecoder("utf-16le");

/** Core Data dates are seconds since 2001; Unix seconds and milliseconds are taken too. */
export function paperDate(v) {
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) return null;
  if (v > 1e12) return Math.round(v); // Unix ms
  if (v > 1.5e9) return Math.round(v * 1000); // Unix seconds (2017 on)
  return Math.round((v + 978307200) * 1000);
}

const PNG = [0x89, 0x50, 0x4e, 0x47], JPEG = [0xff, 0xd8, 0xff], GIF = [0x47, 0x49, 0x46];
const starts = (b, sig) => b.length >= sig.length && sig.every((x, i) => b[i] === x);
export function imageMime(b) {
  if (!(b instanceof Uint8Array)) return null;
  if (starts(b, PNG)) return "image/png";
  if (starts(b, JPEG)) return "image/jpeg";
  if (starts(b, GIF)) return "image/gif";
  return null;
}

const TEXT_TYPES = ["public.utf8-plain-text", "public.plain-text", "nsstringpboardtype", "public.text", "public.utf16-plain-text", "public.utf16-external-plain-text"];
const URL_TYPES = ["public.url", "public.url-name", "nsurlpboardtype", "public.file-url", "nsfilenamespboardtype"];
const IMAGE_TYPES = ["public.png", "public.jpeg", "apple png pasteboard type", "public.tiff", "nstiffpboardtype"];
const looksLikeType = (k) => typeof k === "string" && k.length < 120 && (/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(k) || /pboardtype$/i.test(k) || /pasteboard type/i.test(k));

function asText(v, type = "") {
  if (typeof v === "string") return v;
  if (v instanceof Uint8Array) {
    if (/utf16/.test(type)) return utf16le.decode(v).replace(/^﻿/, "");
    try { return utf8.decode(v); } catch { return null; }
  }
  return null;
}

/** Every (pasteboard type, value) pair found anywhere in a decoded value, and every string. */
function flavours(value) {
  const pairs = [], strings = [];
  const seen = new Set();
  const walk = (v, depth) => {
    if (v == null || depth > 40) return;
    if (typeof v === "string") { strings.push(v); return; }
    if (v instanceof Uint8Array) {
      const inner = decodeBlob(v);
      if (inner !== v) walk(inner, depth + 1);
      return;
    }
    if (typeof v !== "object" || seen.has(v)) return;
    seen.add(v);
    const entries = v instanceof Map ? [...v.entries()] : Array.isArray(v) ? null : Object.entries(v);
    if (Array.isArray(v)) {
      // [type, data, type, data…]
      for (let i = 0; i + 1 < v.length; i += 2) if (looksLikeType(v[i]) && !looksLikeType(v[i + 1])) pairs.push([v[i].toLowerCase(), v[i + 1]]);
      for (const x of v) walk(x, depth + 1);
      return;
    }
    let typeField = null, dataField = null;
    for (const [k, x] of entries) {
      if (k === "$class") continue;
      if (looksLikeType(k)) pairs.push([String(k).toLowerCase(), x]);
      if (/^(type|uti|identifier|pasteboardtype)$/i.test(k) && looksLikeType(x)) typeField = x;
      if (/^(data|value|content|rawdata)$/i.test(k)) dataField = x;
      walk(x, depth + 1);
    }
    if (typeField && dataField != null) pairs.push([typeField.toLowerCase(), dataField]);
  };
  walk(value, 0);
  return { pairs, strings };
}

/** What one pasteboard payload holds: {text?, image?: {bytes, mime}, url?}. */
export function readPayload(blob) {
  if (blob == null) return {};
  if (typeof blob === "string") return blob.trim() ? { text: blob } : {};
  const mime = imageMime(blob);
  if (mime) return { image: { bytes: blob, mime } };
  const decoded = decodeBlob(blob);
  if (decoded === blob) {
    const t = asText(blob);
    return t && t.trim() && !/[\u0000-\u0008\u000e-\u001f]/.test(t) ? { text: t } : {};
  }
  const { pairs, strings } = flavours(decoded);
  const out = {};
  for (const want of TEXT_TYPES) {
    const hit = pairs.find(([t, x]) => t === want && asText(x, t)?.trim());
    if (hit) { out.text = asText(hit[1], hit[0]); break; }
  }
  for (const want of URL_TYPES) {
    const hit = pairs.find(([t, x]) => t === want && asText(x)?.trim());
    if (hit) { out.url = asText(hit[1]).trim(); break; }
  }
  for (const want of IMAGE_TYPES) {
    const hit = pairs.find(([t, x]) => t === want && imageMime(x));
    if (hit) { out.image = { bytes: hit[1], mime: imageMime(hit[1]) }; break; }
  }
  if (!out.image) { const any = pairs.find(([, x]) => imageMime(x)); if (any) out.image = { bytes: any[1], mime: imageMime(any[1]) }; }
  if (!out.text && !out.url && !out.image) {
    // No pasteboard types: the longest string that isn't a class or type name.
    const best = strings.filter((s) => s.trim() && !looksLikeType(s) && !/^(NS|\$)/.test(s)).sort((a, b) => b.length - a.length)[0];
    if (best) out.text = best;
  }
  if (!out.text && out.url) out.text = out.url;
  return out;
}

const col = (row, re) => Object.keys(row).find((k) => re.test(k));
const findTable = (db, re, not = null) => db.tables().filter((t) => re.test(t.name) && !(not && not.test(t.name)))
  .sort((a, b) => b.columns.length - a.columns.length)[0] ?? null;

/**
 * Everything in a Paste database, oldest first: [{text?, image?, createdAt, app, bundle, title,
 * pinboards: [names]}], and how many rows couldn't be read.
 */
export function readPasteDatabase(bytes, wal = null) {
  const db = new SQLiteFile(bytes, wal);
  const itemsTable = findTable(db, /^Z(ITEM(ENTITY)?|SNIPPET|CLIP(ENTITY)?|ENTRY(ENTITY)?)$/i) ?? findTable(db, /^Z.*(ITEM|SNIPPET|CLIP)/i, /DATA|LIST|APP|^Z_/i);
  if (!itemsTable) throw new Error("This doesn't look like Paste's database (no items table)");
  const dataTable = findTable(db, /^Z.*DATA/i, /^Z_/);
  const appTable = findTable(db, /^Z.*APP/i, /^Z_/);
  const listTable = findTable(db, /^Z.*(LIST|PINBOARD|BOARD)/i, /^Z_/);

  const apps = new Map();
  for (const r of appTable ? db.rows(appTable) : []) {
    const name = r[col(r, /NAME/i)], bundle = r[col(r, /BUNDLE|IDENTIFIER/i)];
    apps.set(r.Z_PK ?? r.rowid, { name: typeof name === "string" ? name : null, bundle: typeof bundle === "string" ? bundle : null });
  }
  const lists = new Map();
  for (const r of listTable ? db.rows(listTable) : []) {
    const name = r[col(r, /NAME|TITLE/i)];
    if (typeof name === "string" && name.trim()) lists.set(r.Z_PK ?? r.rowid, name.trim());
  }
  const blobsByItem = new Map();
  if (dataTable) for (const r of db.rows(dataTable)) {
    const ref = r[col(r, /^Z.*ITEM|^ZSNIPPET|^ZOWNER|^ZPARENT/i) ?? ""];
    if (typeof ref !== "number") continue;
    if (!blobsByItem.has(ref)) blobsByItem.set(ref, []);
    for (const [k, v] of Object.entries(r)) if (v instanceof Uint8Array && !/^Z_/.test(k)) blobsByItem.get(ref).push(v);
  }
  // Pinboards joined through a many-to-many table (Z_<n>ITEMS-style: two integer columns).
  const boardsByItem = new Map();
  for (const t of db.tables().filter((x) => /^Z_\d/.test(x.name))) {
    const rows = db.rows(t);
    if (!rows.length) continue;
    const keys = Object.keys(rows[0]).filter((k) => k !== "rowid");
    const listKey = keys.find((k) => /LIST|BOARD/i.test(k)), itemKey = keys.find((k) => /ITEM|SNIPPET|CLIP/i.test(k));
    if (!listKey || !itemKey) continue;
    for (const r of rows) {
      const name = lists.get(r[listKey]);
      if (!name) continue;
      if (!boardsByItem.has(r[itemKey])) boardsByItem.set(r[itemKey], new Set());
      boardsByItem.get(r[itemKey]).add(name);
    }
  }

  const out = [];
  let skipped = 0;
  for (const r of db.rows(itemsTable)) {
    const pk = r.Z_PK ?? r.rowid;
    const dateKey = Object.keys(r).filter((k) => /DATE|TIME/i.test(k) && typeof r[k] === "number")
      .sort((a, b) => (/CREAT|COPY|ADD/i.test(b) ? 1 : 0) - (/CREAT|COPY|ADD/i.test(a) ? 1 : 0))[0];
    const appRef = r[col(r, /^ZAPP|APPLICATION|^ZSOURCE$/i) ?? ""];
    const app = typeof appRef === "number" ? apps.get(appRef) : null;
    const bundleCol = r[col(r, /BUNDLE/i) ?? ""];
    const appName = r[col(r, /APP.*NAME|SOURCE.*NAME/i) ?? ""];
    const titleCol = col(r, /^ZTITLE$|^ZNAME$|^ZCUSTOMTITLE$/i);
    const listRef = r[col(r, /^Z(LIST|PINBOARD|BOARD)/i) ?? ""];
    const pinboards = new Set(boardsByItem.get(pk) ?? []);
    if (typeof listRef === "number" && lists.get(listRef)) pinboards.add(lists.get(listRef));

    // What was copied: text columns, then pasteboard blobs (own and in the data table).
    let payload = {};
    for (const k of Object.keys(r).filter((k) => /TEXT|STRING|CONTENT|PLAIN|PREVIEW|VALUE/i.test(k))) {
      const p = readPayload(r[k]);
      if (p.text || p.image) { payload = { ...p, ...payload }; if (payload.text) break; }
    }
    for (const blob of [...Object.entries(r).filter(([k, v]) => v instanceof Uint8Array && !/^Z_|ICON|THUMB/i.test(k)).map(([, v]) => v), ...(blobsByItem.get(pk) ?? [])]) {
      if (payload.text && payload.image) break;
      const p = readPayload(blob);
      if (!payload.text && p.text) payload.text = p.text;
      if (!payload.image && p.image) payload.image = p.image;
      if (!payload.url && p.url) payload.url = p.url;
    }
    if (!payload.text && !payload.image) { skipped++; continue; }
    out.push({
      text: payload.text ?? null, image: payload.text ? null : payload.image ?? null, url: payload.url ?? null,
      createdAt: paperDate(r[dateKey]) ?? null,
      app: app?.name ?? (typeof appName === "string" ? appName : null), bundle: app?.bundle ?? (typeof bundleCol === "string" ? bundleCol : null),
      title: typeof r[titleCol] === "string" && r[titleCol].trim() ? r[titleCol].trim() : null,
      pinboards: [...pinboards].filter((n) => !/^clipboard( history)?$/i.test(n)),
    });
  }
  out.sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0));
  return { entries: out, skipped, tables: db.tables().map((t) => t.name) };
}
