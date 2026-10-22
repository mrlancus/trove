// PDFs like a PDF app (PROTOCOL.md §10 "PDF text, highlights and forms"): the text of a PDF for
// search (`ocrText`, the same as the apps write), text highlights and form values saved as elements
// on the file's layer, and the mapping between PDF space and Trove's page points.
// TroveCore's PDFMarks.swift does the same; both are checked against Fixtures/pdf-cases.json.

/** `ocrText` from a PDF: shorter than this means "no text layer" (the apps then read the pages with OCR). */
export const PDF_TEXT_MIN = 40;
/** `ocrText` keeps at most this many characters (Unicode code points). */
export const PDF_TEXT_MAX = 50_000;
/** A highlight's `quote` keeps at most this many characters. */
export const QUOTE_MAX = 5_000;

/** Whitespace, the same set in Swift: tab, line breaks, space, NEL, no-break and the Unicode spaces, BOM. */
const WS = /[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+/g;

/** One page's text as pdf.js gives it (`getTextContent().items`): the strings, a line break after each `hasEOL`. */
export function pageTextFromItems(items) {
  let out = "";
  for (const item of items) {
    if (typeof item.str !== "string") continue;
    out += item.str;
    if (item.hasEOL) out += "\n";
  }
  return out;
}

/** A page's text tidied: line breaks as "\n", runs of spaces as one, lines trimmed, empty lines dropped. */
export function normalizePdfPage(text) {
  return String(text ?? "").replace(/\r\n?/g, "\n").split("\n")
    .map((line) => line.replace(WS, " ").trim()).filter(Boolean).join("\n");
}

/**
 * A PDF's `ocrText` from its pages' text: tidied pages, blank ones skipped, a blank line between
 * pages. "" when there are 40 characters or fewer (a scan: no text layer); at most 50,000 characters.
 */
export function joinPdfText(pages) {
  const text = pages.map(normalizePdfPage).filter(Boolean).join("\n\n");
  const chars = Array.from(text);
  if (chars.length <= PDF_TEXT_MIN) return "";
  return chars.length > PDF_TEXT_MAX ? chars.slice(0, PDF_TEXT_MAX).join("") : text;
}

/** A highlight's quote: whitespace (line breaks too) as single spaces, trimmed, at most 5,000 characters. */
export function cleanQuote(text) {
  const s = String(text ?? "").replace(WS, " ").trim();
  const chars = Array.from(s);
  return chars.length > QUOTE_MAX ? chars.slice(0, QUOTE_MAX).join("") : s;
}

const round = (v, k) => Math.floor(v * k + 0.5) / k;

/**
 * A text highlight from the boxes of the selected text (page points): boxes on the same line
 * (overlapping by at least half the smaller height) join, pieces of a line closer than a line's
 * height join, and the result is the box round them all (`x`, `y`, `w`, `h`, to 1/100 point) plus
 * each piece as fractions of that box (`rects`, to 1/10,000), so moving or resizing the box moves
 * them. Null when nothing is left (boxes under half a point are dropped).
 */
export function highlightGeometry(boxes) {
  const ok = boxes.filter((b) => [b.x, b.y, b.w, b.h].every(Number.isFinite) && b.w >= 0.5 && b.h >= 0.5)
    .map((b) => ({ x: b.x, y: b.y, w: b.w, h: b.h }))
    .sort((a, b) => (a.y + a.h / 2) - (b.y + b.h / 2) || a.x - b.x);
  const lines = [];
  for (const b of ok) {
    const line = lines.find((l) => Math.min(l.y + l.h, b.y + b.h) - Math.max(l.y, b.y) >= 0.5 * Math.min(l.h, b.h));
    if (line) { line.items.push(b); Object.assign(line, union(line, b)); } else lines.push({ ...b, items: [b] });
  }
  lines.sort((a, b) => a.y - b.y || a.x - b.x);
  const pieces = [];
  for (const line of lines) {
    const items = line.items.sort((a, b) => a.x - b.x);
    let cur = { ...items[0] };
    for (const b of items.slice(1)) {
      if (b.x - (cur.x + cur.w) <= Math.max(cur.h, b.h)) cur = union(cur, b);
      else { pieces.push(cur); cur = { ...b }; }
    }
    pieces.push(cur);
  }
  if (!pieces.length) return null;
  let box = pieces[0];
  for (const p of pieces) box = union(box, p);
  const x = round(box.x, 100), y = round(box.y, 100), w = Math.max(0.01, round(box.w, 100)), h = Math.max(0.01, round(box.h, 100));
  const rects = pieces.map((p) => [round((p.x - x) / w, 1e4), round((p.y - y) / h, 1e4), round(p.w / w, 1e4), round(p.h / h, 1e4)]);
  return { x, y, w, h, rects };
}

function union(a, b) {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

/** A highlight element's pieces in page points (its whole box when it has no `rects`). */
export function highlightRects(e) {
  const rects = Array.isArray(e.rects) ? e.rects.filter((r) => Array.isArray(r) && r.length === 4 && r.every(Number.isFinite)) : [];
  if (!rects.length) return [{ x: e.x, y: e.y, w: e.w, h: e.h }];
  return rects.map(([fx, fy, fw, fh]) => ({ x: e.x + fx * e.w, y: e.y + fy * e.h, w: fw * e.w, h: fh * e.h }));
}

/** A highlight looks like the highlighter: its colour at 35 %, blended under the ink. */
export function drawHighlightElement(ctx, e) {
  ctx.save();
  ctx.globalAlpha = 0.35;
  ctx.globalCompositeOperation = "multiply";
  ctx.fillStyle = e.color;
  ctx.beginPath();
  for (const r of highlightRects(e)) ctx.rect(r.x, r.y, r.w, r.h);
  ctx.fill();
  ctx.restore();
}

export const HIGHLIGHT_COLORS = ["#ffd60a", "#34c759", "#0a84ff", "#ff6fae", "#ff9500"];

/**
 * A form field's value element id: one record per field (item, file, field name), so two devices
 * filling the same field write the same record (last writer wins).
 */
export const fieldElementId = (itemId, layer, name) => `pdffield:${itemId}:${layer}:${name}`;

/** A field's value as stored: text (text fields, choices, the chosen radio button's value), true/false (check boxes) or a list (multiple choice). */
export function fieldValue(v) {
  if (typeof v === "string" || typeof v === "boolean") return v;
  if (Array.isArray(v) && v.every((x) => typeof x === "string")) return v;
  return null;
}

/**
 * A PDF page's box: `view` [x1, y1, x2, y2] (its crop box) and `rotate` (0, 90, 180, 270). Page
 * points are what pdf.js shows at scale 1 and the apps draw: top-left origin, y down, rotated.
 */
export function pdfPageBox(view, rotate = 0) {
  const [x1, y1, x2, y2] = [Math.min(view[0], view[2]), Math.min(view[1], view[3]), Math.max(view[0], view[2]), Math.max(view[1], view[3])];
  const r = ((Math.round(rotate / 90) * 90) % 360 + 360) % 360;
  const turned = r === 90 || r === 270;
  return {
    width: turned ? y2 - y1 : x2 - x1, height: turned ? x2 - x1 : y2 - y1, rotate: r,
    /** PDF space → page points. */
    toPage([x, y]) {
      if (r === 90) return [y - y1, x - x1];
      if (r === 180) return [x2 - x, y - y1];
      if (r === 270) return [y2 - y, x2 - x];
      return [x - x1, y2 - y];
    },
    /** Page points → PDF space. */
    toPdf([px, py]) {
      if (r === 90) return [x1 + py, y1 + px];
      if (r === 180) return [x2 - px, y1 + py];
      if (r === 270) return [x2 - py, y2 - px];
      return [x1 + px, y2 - py];
    },
  };
}

/** Where `query` is in `text`, ignoring case; whitespace in either matches any whitespace. [[start, end]] in UTF-16 units. */
export function findAll(text, query, limit = 5000) {
  const q = query.trim().replace(/\s+/g, " ");
  if (!q) return [];
  // Lower-case one character at a time so offsets stay the same.
  const fold = (s) => Array.from(s, (c) => { const l = c.toLowerCase(); return l.length === c.length ? l : c; }).join("").replace(/\s/g, " ");
  const hay = fold(text), needle = fold(q);
  const out = [];
  for (let i = hay.indexOf(needle); i >= 0 && out.length < limit; i = hay.indexOf(needle, i + needle.length)) out.push([i, i + needle.length]);
  return out;
}
