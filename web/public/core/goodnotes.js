// Reads the handwriting inside a GoodNotes 5/6 notebook (.goodnotes), so it can be shown without
// GoodNotes. Port of GoodNotesInk.swift; both follow docs/GOODNOTES.md and are checked against the
// same fixtures. The format is undocumented: what's here was worked out by the MIT-licensed
// "Document Parser for GoodNotes" project (github.com/Kaih1825/parser-for-goodnotes), and covers
// pens, highlighters, pencils, erasing, moved ink, images and PDF/template backgrounds.
//
//   .goodnotes = zip: notes/<page> (protobuf records), index.notes.pb (pages),
//   index.events.pb (page order, templates), index.attachments.pb (attachment ids → files),
//   attachments/<id> (PDFs and images).
//   A stroke = a protobuf field holding Apple-LZ4 ("bv41"…"bv4$") → a TPL image (Troy Hanson's tpl
//   format) with the points, followed by a protobuf trailer with the colour and any move offset.
import { readZip } from "./importer.js";

/** GoodNotes works at 132 dots per inch; PDF pages are in points (72 per inch). */
export const GN_SCALE = 72 / 132;

// ---------- protobuf wire format ----------

function varint(b, pos) {
  let value = 0, mult = 1;
  for (let i = 0; i < 10; i++) {
    if (pos >= b.length) throw new Error("truncated varint");
    const byte = b[pos++];
    value += (byte & 0x7f) * mult;
    if (!(byte & 0x80)) return [value, pos];
    mult *= 128;
  }
  throw new Error("varint too long");
}

/** One message: [{n, wt, v}] where v is a number (varint / fixed bits) or bytes. Throws if malformed. */
export function decodeMessage(b) {
  const fields = [];
  let pos = 0;
  while (pos < b.length) {
    let key;
    [key, pos] = varint(b, pos);
    const n = Math.floor(key / 8), wt = key % 8;
    if (n === 0) throw new Error("field 0");
    let v;
    if (wt === 0) [v, pos] = varint(b, pos);
    else if (wt === 1) { if (pos + 8 > b.length) throw new Error("truncated"); v = b.subarray(pos, pos + 8); pos += 8; }
    else if (wt === 5) { if (pos + 4 > b.length) throw new Error("truncated"); v = new DataView(b.buffer, b.byteOffset + pos, 4).getUint32(0, true); pos += 4; }
    else if (wt === 2) {
      let len;
      [len, pos] = varint(b, pos);
      if (pos + len > b.length) throw new Error("truncated");
      v = b.subarray(pos, pos + len); pos += len;
    } else throw new Error("unsupported wire type");
    fields.push({ n, wt, v });
  }
  return fields;
}

export function tryMessage(b) {
  if (!b?.length) return null;
  try { return decodeMessage(b); } catch { return null; }
}

function delimited(b) {
  const out = [];
  let pos = 0;
  while (pos < b.length) {
    let len;
    [len, pos] = varint(b, pos);
    if (pos + len > b.length) throw new Error("truncated record");
    out.push(decodeMessage(b.subarray(pos, pos + len)));
    pos += len;
  }
  return out;
}

/**
 * A member's records. GoodNotes writes length-prefixed records; some members are one message whose
 * field-7 entries are the records. The length-prefixed reading is tried first, since a short
 * record stream can also happen to parse as one message.
 */
export function records(b) {
  if (!b?.length) return [];
  try { return delimited(b); } catch { /* not length-prefixed */ }
  const msg = tryMessage(b);
  if (!msg) return [];
  const nested = msg.filter((f) => f.n === 7 && f.v instanceof Uint8Array).map((f) => tryMessage(f.v)).filter(Boolean);
  return nested.length ? nested : [msg];
}

const get = (msg, n) => msg?.find((f) => f.n === n)?.v;
const utf8 = new TextDecoder("utf-8", { fatal: false });
const asText = (v) => (v instanceof Uint8Array ? utf8.decode(v) : null);
const isUUID = (s) => typeof s === "string" && s.length === 36 && s[8] === "-" && /^[0-9A-Fa-f-]+$/.test(s);
const uuidField = (msg, n) => { const s = asText(get(msg, n)); return isUUID(s) ? s : null; };
/** GoodNotes bumps a page id's last character per revision: compare without it. */
const pageKey = (u) => u.slice(0, 32);

const f32buf = new DataView(new ArrayBuffer(4));
export function f32(u) { f32buf.setUint32(0, u >>> 0, true); return f32buf.getFloat32(0, true); }
/** A fixed32 field as a float. */
function fixedFloat(msg, n) {
  const f = msg?.find((x) => x.n === n && x.wt === 5);
  return f ? f32(f.v) : null;
}

// ---------- Apple LZ4 ----------

export function appleLZ4(b) {
  let out = new Uint8Array(Math.max(1024, b.length * 4)), size = 0, pos = 0;
  const ensure = (extra) => {
    if (size + extra <= out.length) return;
    const bigger = new Uint8Array(Math.max(out.length * 2, size + extra));
    bigger.set(out.subarray(0, size));
    out = bigger;
  };
  const magic = (p) => String.fromCharCode(b[p], b[p + 1], b[p + 2], b[p + 3]);
  for (;;) {
    if (pos + 4 > b.length) throw new Error("no LZ4 end marker");
    const m = magic(pos); pos += 4;
    if (m === "bv4$") return { bytes: out.subarray(0, size), used: pos };
    if (m !== "bv41" && m !== "bv4-") throw new Error("bad LZ4 block");
    const dv = new DataView(b.buffer, b.byteOffset + pos, 8);
    const rawSize = dv.getUint32(0, true), stored = dv.getUint32(4, true);
    pos += 8;
    if (pos + stored > b.length) throw new Error("truncated LZ4 block");
    const src = b.subarray(pos, pos + stored);
    pos += stored;
    ensure(rawSize);
    if (m === "bv4-") { out.set(src, size); size += src.length; continue; }
    const end = size + rawSize;
    let i = 0;
    while (i < src.length) {
      const token = src[i++];
      let lit = token >> 4;
      if (lit === 15) { let x; do { x = src[i++]; lit += x; } while (x === 255); }
      out.set(src.subarray(i, i + lit), size); size += lit; i += lit;
      if (i >= src.length) break;
      const offset = src[i] | (src[i + 1] << 8); i += 2;
      if (!offset || offset > size) throw new Error("bad LZ4 offset");
      let len = token & 15;
      if (len === 15) { let x; do { x = src[i++]; len += x; } while (x === 255); }
      len += 4;
      for (let k = 0; k < len; k++) { out[size] = out[size - offset]; size++; }
    }
    if (size !== end) throw new Error("LZ4 size mismatch");
  }
}

// ---------- TPL ----------

function parseFormat(s) {
  let pos = 0;
  const group = (closing) => {
    const nodes = [];
    while (pos < s.length) {
      const c = s[pos++];
      if (c === ")") return nodes;
      if (c === "A" || c === "S") { pos++; nodes.push({ kind: c, children: group(true) }); }
      else nodes.push(c);
    }
    if (closing) throw new Error("unclosed TPL group");
    return nodes;
  };
  return group(false);
}

/** A TPL image: {format, values}. `u` values stay raw 32-bit words (often float bits). */
export function decodeTPL(b) {
  if (b.length < 9 || b[0] !== 0x74 || b[1] !== 0x70 || b[2] !== 0x6c) throw new Error("not TPL");
  const dv = new DataView(b.buffer, b.byteOffset, b.length);
  let end = 8;
  while (end < b.length && b[end] !== 0) end++;
  const format = String.fromCharCode(...b.subarray(8, end));
  let pos = end + 1;
  const u32 = () => { const v = dv.getUint32(pos, true); pos += 4; return v; };
  const read = (node) => {
    if (typeof node !== "string") {
      if (node.kind === "S") return node.children.map(read);
      const count = u32();
      const list = new Array(count);
      for (let i = 0; i < count; i++) list[i] = node.children.length === 1 ? read(node.children[0]) : node.children.map(read);
      return list;
    }
    switch (node) {
      case "c": return dv.getInt8(pos++);
      case "j": { const v = dv.getInt16(pos, true); pos += 2; return v; }
      case "v": { const v = dv.getUint16(pos, true); pos += 2; return v; }
      case "i": { const v = dv.getInt32(pos, true); pos += 4; return v; }
      case "u": return u32();
      case "I": case "U": { const lo = dv.getUint32(pos, true), hi = dv.getUint32(pos + 4, true); pos += 8; return hi * 2 ** 32 + lo; }
      case "f": { const v = dv.getFloat64(pos, true); pos += 8; return v; }
      case "s": { const n = u32(); const t = utf8.decode(b.subarray(pos, pos + Math.max(n - 1, 0))); pos += Math.max(n - 1, 0); return t; }
      case "B": { const n = u32(); const t = b.subarray(pos, pos + n); pos += n; return t; }
      default: throw new Error(`TPL type ${node}`);
    }
  };
  return { format, values: parseFormat(format).map(read) };
}

// ---------- strokes ----------

const okCoord = (v) => Number.isFinite(v) && Math.abs(v) <= 20000;
const okRadius = (r) => Number.isFinite(r) && r >= 0.001 && r <= 100;

/** Point runs [[x, y, r]…] from a stroke's TPL values, and its nominal width. */
export function strokePoints({ format, values }) {
  const width = typeof values[1] === "number" && values[1] > 1000 ? f32(values[1]) : 0;
  const nominal = width >= 0.05 && width <= 100 ? width : 1;
  const runs = [];
  let run = [];
  const add = (x, y, r) => {
    if (!okCoord(x) || !okCoord(y)) return;
    const last = run[run.length - 1];
    if (!last || Math.hypot(x - last[0], y - last[1]) >= 1e-3) run.push([x, y, okRadius(r) ? r : nominal / 2]);
  };
  const cut = () => { if (run.length) runs.push(run); run = []; };

  if (format.includes("A(S(uuuuuuuuuuu")) {
    // Pencil: a start (x, y, ?, ?, r) and 11-word segments (?, x1, y1, ?, ?, r1, x2, y2, ?, ?, r2).
    for (const p of values[3] ?? []) if (p.length >= 5) add(f32(p[0]), f32(p[1]), f32(p[4]));
    for (const s of values[4] ?? []) if (s.length >= 11) { add(f32(s[1]), f32(s[2]), f32(s[5])); add(f32(s[6]), f32(s[7]), f32(s[10])); }
  } else if (format.includes("A(S(uuuu))")) {
    // Pens and highlighters: a start (x, y) and segments of two points; a 0 in values[2] lifts the pen.
    const flags = Array.isArray(values[2]) && values[2].every((f) => f === 0 || f === 1) ? values[2] : [];
    for (const p of values[3] ?? []) if (p.length >= 2) add(f32(p[0]), f32(p[1]), nominal / 2);
    (values[4] ?? []).forEach((q, i) => {
      if (q.length < 4) return;
      if (flags[i + 1] === 0) cut();
      add(f32(q[0]), f32(q[1]), nominal / 2);
      add(f32(q[2]), f32(q[3]), nominal / 2);
    });
  } else {
    // GoodNotes 6: flat word arrays after the flags. The first holds the start point (x, y, r[, 0]),
    // the second the rest as (x, y, r), with (0, 0, r) markers between curve segments, skipped.
    const at = format.startsWith("vu") ? 3 : 2;
    const triples = (list, max = Infinity) => {
      const out = [];
      if (!Array.isArray(list) || typeof list[0] !== "number") return out;
      for (let i = 0; i + 2 < list.length && out.length < max; i += 3) {
        const x = f32(list[i]), y = f32(list[i + 1]), r = f32(list[i + 2]);
        if (Math.abs(x) < 10 && Math.abs(y) < 10) continue;
        out.push([x, y, r]);
      }
      return out;
    };
    for (const [x, y, r] of [...triples(values[at], 1), ...triples(values[at + 1])]) add(x, y, r);
  }
  cut();
  return { runs, width: nominal };
}

/** Colour, opacity and move offset from the protobuf after the ink. */
function trailerStyle(b) {
  const msg = tryMessage(b) ?? [];
  const colour = tryMessage(get(msg, 4));
  const channel = (n, fallback) => { const v = fixedFloat(colour, n); return v == null || !Number.isFinite(v) ? fallback : Math.min(1, Math.max(0, v)); };
  const offset = tryMessage(get(msg, 6));
  return {
    rgb: colour ? [channel(1, 0), channel(2, 0), channel(3, 0)] : [0, 0, 0],
    alpha: colour ? channel(4, 1) : 1,
    dx: fixedFloat(offset, 1) ?? 0,
    dy: fixedFloat(offset, 2) ?? 0,
  };
}

/** A stroke payload (`\n$<uuid>…bv41…bv4$<trailer>`) as {id, color, alpha, width, runs}. */
export function parseStroke(v) {
  const start = indexOf(v, BV41);
  if (start < 0) return null;
  try {
    const { bytes, used } = appleLZ4(v.subarray(start));
    if (bytes[0] !== 0x74) return null;
    const tpl = decodeTPL(bytes);
    const { runs, width } = strokePoints(tpl);
    if (!runs.length) return null;
    const style = trailerStyle(v.subarray(start + used));
    if (style.dx || style.dy) for (const run of runs) for (const p of run) { p[0] += style.dx; p[1] += style.dy; }
    const id = v[0] === 0x0a && v[1] === 0x24 ? utf8.decode(v.subarray(2, 38)) : null;
    return { id, rgb: style.rgb, alpha: style.alpha, width, runs, pencil: tpl.format.includes("A(S(uuuuuuuuuuu") };
  } catch {
    return null;
  }
}

const BV41 = [0x62, 0x76, 0x34, 0x31];
function indexOf(b, pat) {
  outer: for (let i = 0; i <= b.length - pat.length; i++) {
    for (let k = 0; k < pat.length; k++) if (b[i + k] !== pat[k]) continue outer;
    return i;
  }
  return -1;
}

// ---------- shapes (lines, arrows, ellipses, rectangles made with the shape tool) ----------

/** The first two fixed32 floats of a message (by field number), looking one level down if needed. */
function pointOf(msg) {
  const direct = msg.filter((f) => f.wt === 5).sort((a, b) => a.n - b.n);
  if (direct.length >= 2) return [f32(direct[0].v), f32(direct[1].v)];
  for (const f of [...msg].sort((a, b) => a.n - b.n)) {
    const sub = f.v instanceof Uint8Array ? tryMessage(f.v) : null;
    const pts = sub?.filter((x) => x.wt === 5).sort((a, b) => a.n - b.n);
    if (pts?.length >= 2) return [f32(pts[0].v), f32(pts[1].v)];
  }
  return null;
}

const bezier = (p0, cs, out) => {
  for (let j = 1; j <= 24; j++) {
    const t = j / 24, u = 1 - t;
    if (cs.length === 2) out.push([u * u * p0[0] + 2 * u * t * cs[0][0] + t * t * cs[1][0], u * u * p0[1] + 2 * u * t * cs[0][1] + t * t * cs[1][1]]);
    else out.push([u ** 3 * p0[0] + 3 * u * u * t * cs[0][0] + 3 * u * t * t * cs[1][0] + t ** 3 * cs[2][0],
      u ** 3 * p0[1] + 3 * u * u * t * cs[0][1] + 3 * u * t * t * cs[1][1] + t ** 3 * cs[2][1]]);
  }
};

/** A path container: line points, with commands 3 (quadratic) and 4 (cubic) flattened. */
function pathPoints(container) {
  const cmds = [];
  for (const f of container) {
    const item = f.v instanceof Uint8Array ? tryMessage(f.v) : null;
    if (!item?.length) continue;
    const pt = pointOf(item);
    if (pt) cmds.push([item[0].n >= 1 && item[0].n <= 5 ? item[0].n : f.n, pt]);
  }
  const pts = [];
  for (let i = 0; i < cmds.length; i++) {
    const [cmd, pt] = cmds[i];
    if (cmd === 3 && i + 1 < cmds.length) { bezier(pts.at(-1) ?? pt, [pt, cmds[i + 1][1]], pts); i += 1; }
    else if (cmd === 4 && i + 2 < cmds.length) { bezier(pts.at(-1) ?? pt, [pt, cmds[i + 1][1], cmds[i + 2][1]], pts); i += 2; }
    else pts.push(pt);
  }
  return pts;
}

/** A shape record (field 7 → {4: colour, 9: geometry, 14/6: move}) as a stroke-like {rgb, alpha, width, runs}. */
export function parseShape(rec) {
  const outer = tryMessage(get(rec, 7));
  const geo = tryMessage(get(outer, 9));
  if (!geo) return null;
  let pts = [];
  const container = tryMessage(get(geo, 1) ?? get(geo, 2));
  if (container) pts = pathPoints(container);
  if (pts.length < 2) {
    const ellipse = tryMessage(get(geo, 4)), rect = tryMessage(get(geo, 3));
    const pair = (m, n) => { const sub = tryMessage(get(m, n)); return sub ? pointOf(sub) : null; };
    if (ellipse) {
      const c = pair(ellipse, 1), r = pair(ellipse, 2), rot = fixedFloat(ellipse, 3) ?? 0;
      if (c && r) for (let i = 0; i <= 96; i++) {
        const t = (2 * Math.PI * i) / 96;
        pts.push([c[0] + r[0] * Math.cos(t) * Math.cos(rot) - r[1] * Math.sin(t) * Math.sin(rot), c[1] + r[0] * Math.cos(t) * Math.sin(rot) + r[1] * Math.sin(t) * Math.cos(rot)]);
      }
    } else if (rect) {
      const c = pair(rect, 1), sz = pair(rect, 2);
      if (c && sz) { const [l, t, r, b] = [c[0] - sz[0] / 2, c[1] - sz[1] / 2, c[0] + sz[0] / 2, c[1] + sz[1] / 2]; pts = [[l, t], [r, t], [r, b], [l, b], [l, t]]; }
    }
  }
  if (pts.length < 2) return null;
  let dx = 0, dy = 0;
  for (const m of [outer, rec]) {
    const off = tryMessage(get(m, 14)) ?? tryMessage(get(m, 6));
    if (off && (fixedFloat(off, 1) || fixedFloat(off, 2))) { dx = fixedFloat(off, 1) ?? 0; dy = fixedFloat(off, 2) ?? 0; break; }
  }
  const width = fixedFloat(geo, 15) ?? 1;
  const style = trailerStyle(new Uint8Array(0));
  const colour = tryMessage(get(outer, 4));
  if (colour) {
    style.rgb = [1, 2, 3].map((n) => Math.min(1, Math.max(0, fixedFloat(colour, n) ?? 0)));
    style.alpha = fixedFloat(colour, 4) ?? 1;
  }
  return { id: uuidField(outer, 1), rgb: style.rgb, alpha: style.alpha, width, shape: true, runs: [pts.map(([x, y]) => [x + dx, y + dy, width / 2])] };
}

// ---------- typed text boxes ----------

/**
 * A text box record (field 21 → {20: position, 32: {1: {2: LZ4 rich text}, 2: size, 5: font, 10: inset}})
 * as {x, y, w, h, runs: [{text, size, rgb, bold, italic}]}.
 */
export function parseTextBox(rec) {
  const msg = tryMessage(get(rec, 21));
  const box = tryMessage(get(msg, 32));
  const payload = get(tryMessage(get(box, 1)), 2);
  if (!(payload instanceof Uint8Array) || indexOf(payload, BV41) < 0) return null;
  const xy = (m) => { const sub = tryMessage(get(m, 1)); return sub ? [fixedFloat(sub, 1) ?? 0, fixedFloat(sub, 2) ?? 0] : null; };
  const size = tryMessage(get(box, 2)), inset = tryMessage(get(box, 10));
  let [x, y] = xy(tryMessage(get(msg, 20))) ?? [0, 0];
  if (!x && !y) { x = fixedFloat(size, 1) ?? 0; y = fixedFloat(size, 2) ?? 0; }
  const w = (fixedFloat(size, 1) ?? 0) + 2 * (fixedFloat(inset, 1) ?? 0), h = (fixedFloat(size, 2) ?? 0) + 2 * (fixedFloat(inset, 2) ?? 0);
  const font = tryMessage(get(tryMessage(get(box, 5)), 1));
  const defaultSize = fixedFloat(font, 40) > 0 ? fixedFloat(font, 40) : 24;
  let rich;
  try { rich = tryMessage(appleLZ4(payload.subarray(indexOf(payload, BV41))).bytes); } catch { return null; }
  const runs = [];
  for (const f of rich ?? []) {
    const item = f.v instanceof Uint8Array ? tryMessage(f.v) : null;
    const text = asText(get(item, 1));
    if (!text) continue;
    const style = tryMessage(get(item, 2));
    const fontName = asText(get(style, 30)) ?? "";
    const c = tryMessage(get(style, 3));
    runs.push({
      text,
      size: fixedFloat(style, 40) > 0 ? fixedFloat(style, 40) : defaultSize,
      rgb: c ? [1, 2, 3].map((n) => Math.min(1, Math.max(0, fixedFloat(c, n) ?? 0))) : [0, 0, 0],
      bold: /bold/i.test(fontName),
      italic: get(style, 50) === 1 || /italic/i.test(fontName),
    });
  }
  return runs.length ? { id: uuidField(rec, 1), x, y, w, h, runs } : null;
}

/** All the typed words on a page, for search. */
export const pageText = (page) => page.texts.map((t) => t.runs.map((r) => r.text).join("")).join("\n");

// ---------- pages ----------

/**
 * Strokes, shapes, text boxes and images on one page's records; `layers` has them all in drawing
 * order. Erased things (field 3 = 1 on their element) are skipped.
 */
export function pageContent(recs, attachmentIds) {
  const erased = new Set();
  for (const r of recs) {
    const id = uuidField(r, 1);
    if (id && get(r, 3) === 1) erased.add(id);
  }
  const strokes = [], images = [], texts = [], layers = [], seen = new Set();
  const take = (v) => {
    if (indexOf(v, BV41) < 0) return;
    const s = parseStroke(v);
    if (!s || (s.id && (seen.has(s.id) || erased.has(s.id)))) return;
    if (s.id) seen.add(s.id);
    strokes.push(s);
    layers.push({ kind: "ink", ...s });
  };
  recs.forEach((r, i) => {
    for (const f of r) if (f.v instanceof Uint8Array) take(f.v);
    const f7 = get(r, 7);
    if (f7 instanceof Uint8Array && indexOf(f7, BV41) < 0) {
      const sub = tryMessage(f7);
      for (const f of sub ?? []) if (f.v instanceof Uint8Array) take(f.v);
    }
    const text = parseTextBox(r);
    if (text && !(text.id && erased.has(text.id))) { texts.push(text); layers.push({ kind: "text", ...text }); }
    const shape = text ? null : parseShape(r);
    if (shape && !(shape.id && erased.has(shape.id))) { strokes.push(shape); layers.push({ kind: "ink", ...shape }); }
    const att = uuidField(r, 7) ?? uuidField(r, 4);
    if (att && attachmentIds.has(att) && get(r, 3) !== 1) {
      const box = imageBox(r) ?? (recs[i + 1] ? imageBox(recs[i + 1]) : null);
      if (box) { images.push({ attachment: att, ...box }); layers.push({ kind: "image", attachment: att, ...box }); }
    }
  });
  return { strokes, images, texts, layers };
}

/** An image's frame: {x, y, w, h} (crop applied), from a nested {2: {1: {x, y}, 2: {w, h}}, 3: crop}. */
function imageBox(rec) {
  for (const f of rec) {
    const msg = f.v instanceof Uint8Array ? tryMessage(f.v) : null;
    const frame = tryMessage(get(msg, 2));
    const xy = tryMessage(get(frame, 1)), wh = tryMessage(get(frame, 2));
    const w = fixedFloat(wh, 1), h = fixedFloat(wh, 2);
    if (!(w > 0 && h > 0)) continue;
    const box = { x: fixedFloat(xy, 1) ?? 0, y: fixedFloat(xy, 2) ?? 0, w, h };
    const crop = tryMessage(get(msg, 3));
    const c = tryMessage(get(crop, 1)), cs = tryMessage(get(crop, 2));
    const cw = fixedFloat(cs, 1), ch = fixedFloat(cs, 2), cx = fixedFloat(c, 1), cy = fixedFloat(c, 2);
    if (cw > 0 && ch > 0 && cx > 0) return { x: cx - cw / 2, y: cy - ch / 2, w: cw, h: ch };
    return box;
  }
  return null;
}

function pdfSize(bytes) {
  const text = utf8.decode(bytes.subarray(0, Math.min(bytes.length, 4 * 1024 * 1024)));
  const m = /\/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]/.exec(text);
  if (!m) return null;
  const w = Math.abs(m[3] - m[1]), h = Math.abs(m[4] - m[2]);
  return w > 0 && h > 0 ? { width: w, height: h } : null;
}

/**
 * Everything needed to draw a notebook: pages in order, each with its size in points, background
 * (a PDF page or an image from `attachments`), strokes and images (in GoodNotes units; multiply by
 * GN_SCALE for points). `attachments` maps attachment ids to {path, bytes, mime}.
 */
export async function readNotebook(bytes) {
  const zip = readZip(bytes);
  const entry = (path) => zip.entries.find((e) => e.path === path);
  const data = async (path) => { const e = entry(path); return e ? zip.data(e) : null; };

  // Attachments: id → file.
  const attachments = new Map();
  const attIndex = await data("index.attachments.pb");
  for (const r of attIndex ? records(attIndex) : []) {
    let id = null, path = null;
    for (const f of r) { const s = asText(f.v); if (s?.startsWith("attachments/")) path = s; else if (isUUID(s)) id = s; }
    if (id && path && entry(path)) attachments.set(id, { path });
  }
  for (const e of zip.entries) {
    if (!e.path.startsWith("attachments/") || e.isDirectory) continue;
    const id = e.path.slice("attachments/".length);
    if (![...attachments.values()].some((a) => a.path === e.path)) attachments.set(id, { path: e.path });
  }
  for (const a of attachments.values()) {
    a.bytes = await data(a.path);
    a.mime = sniffMime(a.bytes);
  }

  // Events: deleted pages, page order, templates (backgrounds).
  const deleted = new Set(), order = new Map(), templates = new Map(), pageTemplate = new Map(), direct = new Map();
  const events = await data("index.events.pb");
  for (const r of events ? records(events) : []) {
    for (const f of r) {
      if (f.n === 56) { const m = tryMessage(f.v); const id = uuidField(m, 2); if (id) deleted.add(pageKey(id)); }
      if (f.n === 54 || f.n === 55) {
        const m = tryMessage(f.v), id = uuidField(m, 2), key = asText(get(tryMessage(get(m, f.n === 54 ? 4 : 3)), 1));
        const ts = typeof get(r, 14) === "number" ? get(r, 14) : 0;
        if (id && key != null) { const prior = order.get(pageKey(id)); if (!prior || ts >= prior.ts) order.set(pageKey(id), { ts, key }); }
      }
      if (f.n === 2) {
        const m = tryMessage(f.v), t = asText(get(m, 2)), a = asText(get(m, 4)), p = get(m, 5);
        if (t && a) templates.set(t, { attachment: a, page: typeof p === "number" ? p : 1 });
      }
      if (f.n === 54 || f.n === 3) {
        const m = tryMessage(f.v), id = uuidField(m, 2), t = asText(get(tryMessage(get(m, 3)), 1));
        if (id && t) pageTemplate.set(pageKey(id), t);
      }
    }
    let page = null, att = null;
    for (const f of r) { const s = asText(f.v); if (isUUID(s)) { if (attachments.has(s)) att = s; else page = s; } }
    if (page && att) direct.set(pageKey(page), att);
  }

  // Pages.
  let list = [];
  const notesIndex = await data("index.notes.pb");
  for (const r of notesIndex ? records(notesIndex) : []) {
    let id = null, path = null;
    for (const f of r) { const s = asText(f.v); if (s?.startsWith("notes/")) path = s; else if (isUUID(s)) id = s; }
    if (path && entry(path) && !deleted.has(pageKey(id ?? path.slice(6)))) list.push({ id: id ?? path.slice(6), path });
  }
  if (!list.length) list = zip.entries.filter((e) => e.path.startsWith("notes/") && !e.isDirectory).map((e) => ({ id: e.path.slice(6), path: e.path })).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  if (order.size) {
    const pos = new Map(list.map((p, i) => [p.id, i]));
    list.sort((a, b) => {
      const ka = order.get(pageKey(a.id)), kb = order.get(pageKey(b.id));
      if (ka && kb) return ka.key < kb.key ? -1 : ka.key > kb.key ? 1 : 0;
      return ka ? -1 : kb ? 1 : pos.get(a.id) - pos.get(b.id);
    });
  }
  const pdfs = [...attachments.values()].filter((a) => a.mime === "application/pdf").sort((a, b) => b.bytes.length - a.bytes.length);
  const pages = [], sizes = new Map();
  for (const [index, p] of list.entries()) {
    const recs = records(await data(p.path));
    let background = null;
    const directAtt = direct.get(pageKey(p.id));
    const template = templates.get(pageTemplate.get(pageKey(p.id)));
    if (directAtt) background = { attachment: directAtt, page: 1 };
    else if (template && attachments.has(template.attachment)) background = { attachment: template.attachment, page: template.page };
    else if (pdfs.length) {
      const id = [...attachments].find(([, a]) => a === pdfs[Math.min(index, pdfs.length - 1)])[0];
      background = { attachment: id, page: index + 1 };
    }
    const bg = background && attachments.get(background.attachment);
    if (bg?.mime === "application/pdf" && !sizes.has(background.attachment)) sizes.set(background.attachment, pdfSize(bg.bytes));
    const size = (bg?.mime === "application/pdf" && sizes.get(background.attachment)) || { width: 612, height: 792 };
    pages.push({ id: p.id, ...size, background, ...pageContent(recs, attachments) });
  }
  return { pages, attachments };
}

function sniffMime(b) {
  if (!b || b.length < 4) return "application/octet-stream";
  if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return "application/pdf";
  if (b[0] === 0x89 && b[1] === 0x50) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b[0] === 0x47 && b[1] === 0x49) return "image/gif";
  return "application/octet-stream";
}

/** SVG path data for a run: a smooth line through the points (quadratic midpoints), or straight for shapes. */
export function runPath(run, scale = 1, straight = false) {
  const p = (pt) => `${(pt[0] * scale).toFixed(2)} ${(pt[1] * scale).toFixed(2)}`;
  if (run.length === 1) return `M${p(run[0])}l0.01 0`;
  if (straight) return `M${run.map(p).join("L")}`;
  let d = `M${p(run[0])}`;
  for (let i = 1; i < run.length - 1; i++) {
    const mid = [(run[i][0] + run[i + 1][0]) / 2, (run[i][1] + run[i + 1][1]) / 2];
    d += `Q${p(run[i])} ${p(mid)}`;
  }
  return d + `L${p(run[run.length - 1])}`;
}

/** The ink line width for a stroke, in GoodNotes units. */
export function strokeWidth(s) {
  if (s.shape) return Math.max(0.5, s.width);
  if (s.pencil) return Math.max(0.5, s.width * 0.45);
  const radii = s.runs.flat().map((p) => p[2]).sort((a, b) => a - b);
  const median = radii[Math.floor(radii.length / 2)] ?? s.width / 2;
  return Math.max(0.5, median * 2);
}

export const isHighlighter = (s) => s.alpha < 0.95;
/** How opaque to draw a stroke: GoodNotes' pencil is grainy and light. */
export const strokeOpacity = (s) => (s.pencil ? Math.min(s.alpha, 0.5) : s.alpha);
export const cssColor = (s) => `rgb(${s.rgb.map((c) => Math.round(c * 255)).join(",")})`;
