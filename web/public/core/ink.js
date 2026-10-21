// Drawing (PROTOCOL.md §10): a port of Ink.swift. Every stroke is its own `stroke` record on an
// item: a sketch's own pages (layer "") or a file it's drawn on (layer = the attachment id). Both
// sides check Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-cases.json.
import { b64uDecode, b64uEncode } from "./bytes.js";

export const InkField = { on: "on", layer: "layer", page: "page", tool: "tool", color: "color", width: "width", points: "points", createdAt: "createdAt", device: "device", shape: "shape" };
export const TOOLS = ["pen", "pencil", "marker", "highlighter", "fountain", "brush"];
export const PAPERS = ["blank", "lined", "narrow", "wide", "margin", "grid", "smallgrid", "graph", "dotted", "smalldots", "isometric",
  "cornell", "todo", "planner", "storyboard", "music", "calligraphy"];
export const PAPER_TITLES = {
  blank: "Blank", lined: "Lined", narrow: "Narrow lined", wide: "Wide lined", margin: "Lined with margin", grid: "Squared",
  smallgrid: "Small squares", graph: "Graph paper", dotted: "Dotted", smalldots: "Small dots", isometric: "Isometric dots",
  cornell: "Cornell notes", todo: "To-do list", planner: "Week planner", storyboard: "Storyboard", music: "Music", calligraphy: "Handwriting guides",
};
/** Papers grouped for pickers. */
export const PAPER_GROUPS = [
  ["Plain", ["blank"]], ["Lines", ["lined", "narrow", "wide", "margin", "calligraphy"]], ["Grids", ["grid", "smallgrid", "graph"]],
  ["Dots", ["dotted", "smalldots", "isometric"]], ["Layouts", ["cornell", "todo", "planner", "storyboard", "music"]],
];
/** Colours offered for pages (InkPage.colors). */
export const PAGE_COLORS = ["#ffffff", "#fbf6e9", "#fff7c2", "#fde8ec", "#eef5ec", "#eaf1fb", "#f2f2f2", "#3a3d42", "#26282c", "#121212"];
export const PAGE_COLOR_TITLES = { "#ffffff": "White", "#fbf6e9": "Cream", "#fff7c2": "Yellow", "#fde8ec": "Pink", "#eef5ec": "Green", "#eaf1fb": "Blue",
  "#f2f2f2": "Grey", "#3a3d42": "Slate", "#26282c": "Dark", "#121212": "Black" };
/** Line spacing of lined, squared and dotted paper, in page points. */
export const PAPER_SPACING = 32;
export const paperSpacing = (paper) => ({ narrow: 24, wide: 40, smallgrid: 16, graph: 8, smalldots: 16, isometric: 24, todo: 40, music: 8 })[paper] ?? PAPER_SPACING;
/**
 * Page sizes, in page points (real sizes scaled so a page is about as wide as the first sketches,
 * 768 points, and pens look the same on each). Portrait; landscape swaps them.
 */
export const PAGE_SIZES = {
  tablet: { title: "iPad", size: [768, 1024] }, a4: { title: "A4", size: [768, 1086] }, a5: { title: "A5", size: [543, 768] },
  letter: { title: "US Letter", size: [791, 1024] }, legal: { title: "US Legal", size: [791, 1303] }, square: { title: "Square", size: [768, 768] },
  wide: { title: "Widescreen 16:9", size: [576, 1024] }, phone: { title: "Phone", size: [473, 1024] },
};
/** The named size and orientation of a page size, or null for a custom one. */
export function pageSizeName(size) {
  for (const [name, { size: [a, b] }] of Object.entries(PAGE_SIZES)) {
    if (size[0] === a && size[1] === b) return { name, landscape: false };
    if (size[0] === b && size[1] === a) return { name, landscape: a !== b };
  }
  return null;
}
export const SKETCH_SIZE = [768, 1024];

export const toolOpacity = (tool) => ({ pencil: 0.85, highlighter: 0.35 })[tool] ?? 1;
export const usesPressure = (tool) => tool !== "marker" && tool !== "highlighter";

/** The width at a point (InkStroke.width): pens and pencils 35–100 % with pressure, brushes 15–100 %,
 * fountain pens 60–100 % (and their direction: `fountainWidth`). */
export function widthAt(width, tool, pressure) {
  const p = Math.min(1, Math.max(0, pressure));
  if (tool === "pen" || tool === "pencil") return width * (0.35 + 0.65 * p);
  if (tool === "brush") return width * (0.15 + 0.85 * p);
  if (tool === "fountain") return width * (0.6 + 0.4 * p);
  return width;
}

/** A stroke's or element's `page` as a page id: numbers are the old page indexes (InkPage.key). */
export const pageKey = (v) => (typeof v === "string" ? v : typeof v === "number" ? String(Math.trunc(v)) : "0");

/** A sketch's pages in order: `pageList`, or "0", "1", … for sketches made before page ids. */
export function pageListOf(fields) {
  const list = Array.isArray(fields.pageList) ? fields.pageList.filter((p) => p && typeof p.id === "string" && p.id)
    .map((p) => ({ id: p.id, paper: PAPERS.includes(p.paper) ? p.paper : null, color: typeof p.color === "string" ? p.color : null, size: validSize(p.size) })) : [];
  if (list.length) return list;
  const n = Math.max(1, typeof fields.pages === "number" ? Math.floor(fields.pages) : 1);
  return Array.from({ length: n }, (_, i) => ({ id: String(i), paper: null, color: null, size: null }));
}

/** [w, h] if it's a usable page size (36 to 4000 points a side). */
export const validSize = (v) => (Array.isArray(v) && v.length === 2 && v.every((n) => typeof n === "number" && n >= 36 && n <= 4000) ? [v[0], v[1]] : null);

export const isDarkColor = (hex) => {
  if (!hex) return false;
  const [r, g, b] = rgb(hex);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.4;
};
export function rgb(hex) {
  const s = hex.startsWith("#") ? hex.slice(1) : hex;
  if (!/^[0-9a-fA-F]{6}$/.test(s)) return [0, 0, 0];
  const v = parseInt(s, 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

/**
 * Whether new strokes are written in the compact `points2` format (PROTOCOL.md §10). Every reader
 * accepts both; writers switch once every client the user runs reads `points2` (InkPoints.writeCompact
 * in Swift).
 */
export const WRITE_COMPACT_POINTS = false;
/** A `points` value in the compact format starts with this (":" never appears in base64url). */
export const POINTS2_PREFIX = "2:";

/** Points [{x, y, p, t}] as little-endian float32 quadruples in base64url, or `points2` when `compact`. */
export function encodePoints(points, compact = WRITE_COMPACT_POINTS) {
  if (compact) return encodePoints2(points);
  const buf = new DataView(new ArrayBuffer(points.length * 16));
  points.forEach((pt, i) => { [pt.x, pt.y, pt.p, pt.t].forEach((v, k) => buf.setFloat32(i * 16 + k * 4, v ?? 0, true)); });
  return b64uEncode(new Uint8Array(buf.buffer));
}

export function decodePoints(text) {
  if (typeof text === "string" && text.startsWith(POINTS2_PREFIX)) return decodePoints2(text);
  let bytes;
  try { bytes = b64uDecode(text ?? ""); } catch { return []; }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = [];
  for (let i = 0; i + 16 <= bytes.length; i += 16) out.push({ x: dv.getFloat32(i, true), y: dv.getFloat32(i + 4, true), p: dv.getFloat32(i + 8, true), t: dv.getFloat32(i + 12, true) });
  return out;
}

// ---------- points2: about 4–6 bytes a point instead of 16 ----------

/** Rounds half up (the same in Swift: floor(v + 0.5)); NaN and infinities are 0. */
const quantise = (v, scale) => (Number.isFinite(v) ? Math.floor(v * scale + 0.5) : 0);
/** Zigzag (0, -1, 1, -2 … → 0, 1, 2, 3 …) with arithmetic, not 32-bit bit operations. */
const zigzag = (n) => (n >= 0 ? 2 * n : -2 * n - 1);
const unzigzag = (z) => (z % 2 === 0 ? z / 2 : -(z + 1) / 2);

function pushVarint(out, n) {
  while (n >= 128) { out.push((n % 128) + 128); n = Math.floor(n / 128); }
  out.push(n);
}

/**
 * Per point: zigzag varints of Δx and Δy in 1/20 point, one byte of pressure (0…255), and a zigzag
 * varint of Δt in whole milliseconds. Deltas are from the previous point (the first from 0).
 */
export function encodePoints2(points) {
  const out = [];
  let px = 0, py = 0, pt = 0;
  for (const p of points) {
    const x = quantise(p.x ?? 0, 20), y = quantise(p.y ?? 0, 20), t = quantise(p.t ?? 0, 1);
    const pressure = Math.min(255, Math.max(0, quantise(p.p ?? 0, 255)));
    pushVarint(out, zigzag(x - px));
    pushVarint(out, zigzag(y - py));
    out.push(pressure);
    pushVarint(out, zigzag(t - pt));
    px = x; py = y; pt = t;
  }
  return POINTS2_PREFIX + b64uEncode(Uint8Array.from(out));
}

export function decodePoints2(text) {
  let bytes;
  try { bytes = b64uDecode(text.slice(POINTS2_PREFIX.length)); } catch { return []; }
  const out = [];
  let i = 0, x = 0, y = 0, t = 0;
  const varint = () => {
    let n = 0, mul = 1;
    for (;;) {
      if (i >= bytes.length) return null;
      const b = bytes[i++];
      n += (b & 127) * mul;
      if (b < 128) return n;
      mul *= 128;
      if (mul > 2 ** 49) return null; // longer than any coordinate needs: corrupt
    }
  };
  while (i < bytes.length) {
    const dx = varint(), dy = varint();
    if (dx === null || dy === null || i >= bytes.length) break;
    const p = bytes[i++];
    const dt = varint();
    if (dt === null) break;
    x += unzigzag(dx); y += unzigzag(dy); t += unzigzag(dt);
    out.push({ x: x / 20, y: y / 20, p: p / 255, t });
  }
  return out;
}

/** A read-only view of a stroke record. */
export function strokeView(record) {
  const f = record.fields;
  return {
    id: record.id, on: typeof f.on === "string" ? f.on : "", layer: typeof f.layer === "string" ? f.layer : "",
    page: typeof f.page === "number" ? f.page : Number(f.page) || 0, pageKey: pageKey(f.page), tool: TOOLS.includes(f.tool) ? f.tool : "pen",
    shape: typeof f.shape === "string" ? f.shape : null,
    color: typeof f.color === "string" ? f.color : "#000000", width: typeof f.width === "number" ? f.width : 2,
    points: decodePoints(f.points), createdAt: typeof f.createdAt === "number" ? f.createdAt : 0,
  };
}

/**
 * Draws strokes on a 2D canvas context already scaled to page points. Pens and pencils vary in
 * width with pressure (drawn segment by segment with round ends); markers and highlighters are one
 * even line, highlighters blended under the ink.
 */
export function drawStrokes(ctx, strokes) {
  for (const s of strokes) drawStroke(ctx, s);
}

export function drawStroke(ctx, s) {
  const pts = s.points;
  if (!pts.length) return;
  ctx.save();
  ctx.strokeStyle = s.color;
  ctx.fillStyle = s.color;
  ctx.globalAlpha = toolOpacity(s.tool);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  if (s.tool === "highlighter") ctx.globalCompositeOperation = "multiply";
  if (pts.length === 1) {
    ctx.beginPath();
    ctx.arc(pts[0].x, pts[0].y, widthAt(s.width, s.tool, pts[0].p) / 2, 0, Math.PI * 2);
    ctx.fill();
  } else if (!usesPressure(s.tool) || s.tool === "pencil" || s.shape) {
    ctx.lineWidth = s.tool === "pencil" || s.shape ? widthAt(s.width, s.tool, average(pts)) : s.width;
    ctx.beginPath();
    if (s.shape) { ctx.moveTo(pts[0].x, pts[0].y); for (const p of pts.slice(1)) ctx.lineTo(p.x, p.y); } else smoothPath(ctx, pts);
    ctx.stroke();
  } else {
    // Each piece from the middle of one segment to the middle of the next, at that point's width.
    for (let i = 0; i < pts.length - 1; i++) {
      const a = i === 0 ? pts[0] : mid(pts[i - 1], pts[i]);
      const b = i === pts.length - 2 ? pts[i + 1] : mid(pts[i], pts[i + 1]);
      ctx.lineWidth = pointWidth(s, pts, i);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, b.x, b.y);
      ctx.stroke();
    }
  }
  ctx.restore();
}

/** A pen's width at its i-th point: fountain pens follow their direction, brushes taper at the ends. */
export function pointWidth(s, pts, i) {
  const p = pts[i];
  if (s.tool === "fountain") {
    const q = pts[Math.min(pts.length - 1, i + 1)], o = pts[Math.max(0, i - 1)];
    return fountainWidth(s.width, p.p, q.x - o.x, q.y - o.y);
  }
  if (s.tool === "brush") return widthAt(s.width, s.tool, p.p) * brushTaper(i, pts.length);
  return widthAt(s.width, s.tool, p.p);
}

const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const average = (pts) => pts.reduce((n, p) => n + p.p, 0) / pts.length;

function smoothPath(ctx, pts) {
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length - 1; i++) { const m = mid(pts[i], pts[i + 1]); ctx.quadraticCurveTo(pts[i].x, pts[i].y, m.x, m.y); }
  ctx.lineTo(pts.at(-1).x, pts.at(-1).y);
}

/**
 * The lines and dots of a paper on a page of `w` × `h` points, as shapes (InkPaperShapes.swift makes
 * the same; both check Fixtures/ink-papers.json): {k: "h", y, x0, x1, r}, {k: "v", x, y0, y1, r},
 * {k: "dot", x, y, d} and {k: "box", x, y, w, h, r}. `r` is the role: "line", "bold" or "accent".
 * `area` ({x, y, w, h}) limits them to what's on screen, for the endless canvas; there the papers
 * that lay out a page (Cornell, planner, storyboard) are plain lined.
 */
export function paperShapes(paper, w, h, area = null) {
  const out = [];
  const endless = Boolean(area);
  const x0 = area ? area.x : 0, y0 = area ? area.y : 0, x1 = area ? area.x + area.w : w, y1 = area ? area.y + area.h : h;
  if (endless && (paper === "cornell" || paper === "planner" || paper === "storyboard")) paper = "lined";
  const s = paperSpacing(paper);
  const first = (start, step, offset = 0) => Math.ceil((start - offset) / step) * step + offset;
  const hline = (y, r = "line", a = x0, b = x1) => out.push({ k: "h", y, x0: a, x1: b, r });
  const vline = (x, r = "line", a = y0, b = y1) => out.push({ k: "v", x, y0: a, y1: b, r });
  const ruled = (step, top = step * 3, bottom = y1) => { for (let y = endless ? first(y0, step) : top; y < bottom; y += step) hline(y); };
  switch (paper) {
    case "lined": case "narrow": case "wide": ruled(s); break;
    case "margin":
      ruled(s);
      if (!endless) hline(s * 2, "accent");
      if (72 >= x0 && 72 <= x1) vline(72, "accent");
      break;
    case "grid": case "smallgrid": case "graph":
      for (let y = first(y0, s); y < y1; y += s) if (y !== 0 || endless) hline(y, paper === "graph" && Math.round(y / s) % 5 === 0 ? "bold" : "line");
      for (let x = first(x0, s); x < x1; x += s) if (x !== 0 || endless) vline(x, paper === "graph" && Math.round(x / s) % 5 === 0 ? "bold" : "line");
      break;
    case "dotted": case "smalldots":
      for (let y = first(y0, s); y < y1; y += s) for (let x = first(x0, s); x < x1; x += s) {
        if (!endless && (x === 0 || y === 0)) continue;
        out.push({ k: "dot", x, y, d: paper === "smalldots" ? 1.1 : 1.3 });
      }
      break;
    case "isometric": {
      // A triangular lattice: rows s·√3/2 apart, every other row half a step along.
      const row = s * Math.sqrt(3) / 2;
      for (let i = Math.ceil(y0 / row); i * row < y1; i++) {
        const y = i * row, shift = Math.abs(i) % 2 ? s / 2 : 0;
        if (!endless && y === 0) continue;
        for (let x = first(x0, s, shift); x < x1; x += s) if (endless || x > 0) out.push({ k: "dot", x, y, d: 1.2 });
      }
      break;
    }
    case "cornell": {
      const bottom = h * 0.8, cue = w * 0.28;
      for (let y = PAPER_SPACING * 3; y < bottom; y += PAPER_SPACING) hline(y);
      vline(cue, "accent", PAPER_SPACING * 2, bottom);
      hline(bottom, "accent");
      hline(PAPER_SPACING * 2, "accent");
      break;
    }
    case "todo":
      // A box to tick at the start of every line.
      for (let y = endless ? first(y0, s) : s * 2; y < y1; y += s) {
        hline(y);
        if (40 + 16 >= x0 && 40 <= x1) out.push({ k: "box", x: 40, y: y - 24, w: 16, h: 16, r: "bold" });
      }
      break;
    case "planner": {
      // A header, then the seven days as bands, each lined.
      const top = 96, band = (h - top - 24) / 7;
      hline(top - 16, "bold");
      for (let d = 0; d < 7; d++) {
        const y = top + d * band;
        hline(y, "accent");
        for (let l = y + 40; l < y + band - 8; l += PAPER_SPACING) hline(l, "line", 120, x1);
        vline(108, "line", y, y + band);
      }
      hline(top + 7 * band, "accent");
      break;
    }
    case "storyboard": {
      // Two columns of three 4:3 frames, each with two lines for notes.
      const pad = 40, gap = 32, fw = (w - pad * 2 - gap) / 2, fh = fw * 3 / 4, block = (h - pad * 2) / 3;
      for (let r = 0; r < 3; r++) for (let c = 0; c < 2; c++) {
        const x = pad + c * (fw + gap), y = pad + r * block;
        out.push({ k: "box", x, y, w: fw, h: fh, r: "bold" });
        for (const dy of [fh + 28, fh + 56]) if (y + dy < pad + (r + 1) * block) hline(y + dy, "line", x, x + fw);
      }
      break;
    }
    case "music":
      // Five-line staves, 8 points apart, one every 80 points.
      for (let top = first(y0, 80, 40); top < y1; top += 80) for (let k = 0; k < 5; k++) hline(top + k * s);
      break;
    case "calligraphy":
      // Groups of four guides: ascender, x-height (light), baseline (bold), descender; 96 points apart.
      for (let top = endless ? first(y0, 96) : 64; top < y1; top += 96) {
        hline(top); hline(top + 24); hline(top + 48, "bold"); hline(top + 68);
      }
      break;
    default: break;
  }
  return out;
}

/** The colours paper lines are drawn in, on a light or dark page. */
export function paperInk(dark) {
  return dark
    ? { line: "rgba(200, 215, 240, 0.22)", bold: "rgba(200, 215, 240, 0.4)", accent: "rgba(240, 150, 150, 0.5)", dot: "rgba(210, 220, 235, 0.4)" }
    : { line: "rgba(90, 130, 200, 0.28)", bold: "rgba(90, 130, 200, 0.5)", accent: "rgba(220, 90, 90, 0.55)", dot: "rgba(90, 110, 140, 0.45)" };
}

/**
 * Paper on a page of `w` × `h` points, in the page's colour (white by default). `area` limits the
 * drawing to what's on screen, for the endless canvas: {x, y, w, h} in page points.
 */
export function drawPaper(ctx, paper, w, h, color = null, area = null) {
  const x0 = area ? area.x : 0, y0 = area ? area.y : 0, x1 = area ? area.x + area.w : w, y1 = area ? area.y + area.h : h;
  ctx.save();
  ctx.fillStyle = color || "#fff";
  ctx.fillRect(x0, y0, x1 - x0, y1 - y0);
  const ink = paperInk(isDarkColor(color));
  ctx.lineWidth = 1;
  for (const role of ["line", "bold", "accent"]) {
    ctx.strokeStyle = ink[role];
    ctx.beginPath();
    let any = false;
    for (const sh of paperShapes(paper, w, h, area)) {
      if (sh.r !== role) continue;
      any = true;
      if (sh.k === "h") { ctx.moveTo(sh.x0, sh.y); ctx.lineTo(sh.x1, sh.y); }
      else if (sh.k === "v") { ctx.moveTo(sh.x, sh.y0); ctx.lineTo(sh.x, sh.y1); }
      else if (sh.k === "box") ctx.rect(sh.x, sh.y, sh.w, sh.h);
    }
    if (any) ctx.stroke();
  }
  ctx.fillStyle = ink.dot;
  for (const sh of paperShapes(paper, w, h, area)) {
    if (sh.k !== "dot") continue;
    ctx.beginPath(); ctx.arc(sh.x, sh.y, sh.d, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}

/** True if the point is within `radius` of the stroke's line (for the stroke eraser). */
export const hits = (s, x, y, radius) => hitsPoints(s.points, s.width, x, y, radius);

// ---------- geometry (InkGeometry.swift; both check Fixtures/ink-geometry.json) ----------

export function hitsPoints(pts, width, x, y, radius) {
  const r = radius + width / 2;
  if (pts.length === 1) return Math.hypot(pts[0].x - x, pts[0].y - y) <= r;
  for (let i = 0; i < pts.length - 1; i++) if (segmentDistance({ x, y }, pts[i], pts[i + 1]) <= r) return true;
  return false;
}

export function segmentDistance(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy;
  const t = len > 0 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0;
  return Math.hypot(a.x + t * dx - p.x, a.y + t * dy - p.y);
}

/** {x, y, w, h} around the points, grown by `pad`; null for none. */
export function bounds(pts, pad = 0) {
  if (!pts.length) return null;
  let minX = pts[0].x, minY = pts[0].y, maxX = minX, maxY = minY;
  for (const p of pts) { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); }
  return { x: minX - pad, y: minY - pad, w: maxX - minX + 2 * pad, h: maxY - minY + 2 * pad };
}

export function unionRect(a, b) {
  if (!a) return b;
  if (!b) return a;
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

/** Even-odd rule; the polygon closes itself. */
export function inside(x, y, polygon) {
  let result = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i], b = polygon[j];
    if ((a.y > y) !== (b.y > y) && x < ((b.x - a.x) * (y - a.y)) / (b.y - a.y) + a.x) result = !result;
  }
  return result;
}

/** A stroke is picked up by the lasso when at least half its points are inside. */
export function lassoSelects(pts, lasso) {
  if (!pts.length || lasso.length < 3) return false;
  return pts.filter((p) => inside(p.x, p.y, lasso)).length * 2 >= pts.length;
}

/** A box (text, picture) is picked up when its centre is inside. */
export const lassoSelectsBox = (r, lasso) => lasso.length >= 3 && inside(r.x + r.w / 2, r.y + r.h / 2, lasso);

/** Scale about (ox, oy), then move: x' = ox + (x − ox)·sx + dx. */
export const transformPoint = (t, p) => ({ ...p, x: t.ox + (p.x - t.ox) * t.sx + t.dx, y: t.oy + (p.y - t.oy) * t.sy + t.dy });
export const widthScale = (t) => Math.sqrt(Math.abs(t.sx) * Math.abs(t.sy));
export const moveBy = (dx, dy) => ({ sx: 1, sy: 1, ox: 0, oy: 0, dx, dy });
export function transformRect(t, r) {
  const a = transformPoint(t, { x: r.x, y: r.y }), b = transformPoint(t, { x: r.x + r.w, y: r.y + r.h });
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) };
}

/** Extra points so no two neighbours are further apart than `spacing`. */
export function resample(pts, spacing) {
  if (pts.length < 2 || spacing <= 0) return pts;
  const out = [pts[0]];
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i];
    const n = Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / spacing);
    for (let k = 1; k < n; k++) {
      const f = k / n;
      out.push({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, p: a.p + (b.p - a.p) * f, t: a.t + (b.t - a.t) * f });
    }
    out.push(b);
  }
  return out;
}

function touches(path, p, radius) {
  if (path.length === 1) return Math.hypot(path[0].x - p.x, path[0].y - p.y) <= radius;
  for (let i = 0; i < path.length - 1; i++) if (segmentDistance(p, path[i], path[i + 1]) <= radius) return true;
  return false;
}

/** The partial eraser: the pieces of a stroke outside a circle of `radius` moved along `path`, or null if it didn't touch. */
export function erase(pts, path, radius) {
  if (!pts.length || !path.length || radius <= 0) return null;
  const dense = resample(pts, radius / 2);
  const hit = dense.map((p) => touches(path, p, radius));
  if (!hit.includes(true)) return null;
  const pieces = [];
  let run = [];
  dense.forEach((p, i) => {
    if (hit[i]) { if (run.length >= 2) pieces.push(run); run = []; } else run.push(p);
  });
  if (run.length >= 2) pieces.push(run);
  return pieces;
}

export const NIB_ANGLE = Math.PI / 4;

/** Fountain pens write like a nib held at 45°: thin along it, broad across it. */
export function fountainWidth(width, pressure, dx, dy) {
  const p = Math.min(1, Math.max(0, pressure));
  const across = dx === 0 && dy === 0 ? 0.5 : Math.abs(Math.sin(Math.atan2(dy, dx) - NIB_ANGLE));
  return width * (0.25 + 0.75 * across) * (0.6 + 0.4 * p);
}

/** A brush's ends taper over the first and last 15 % of its points. */
export function brushTaper(index, count) {
  if (count <= 2) return 1;
  const edge = Math.max(1, count * 0.15);
  return Math.min(1, Math.max(0.15, Math.min(index + 1, count - index) / edge));
}

// ---------- shapes (InkShapes.swift) ----------

export const SHAPES = ["line", "polyline", "triangle", "rectangle", "polygon", "circle", "ellipse"];

/** A rough drawing as a clean shape, {shape, points}, or null when it isn't one. */
export function recognizeShape(raw) {
  if (raw.length < 2) return null;
  const box = bounds(raw);
  const diag = Math.hypot(box.w, box.h);
  if (diag < 12) return null;
  const first = raw[0], last = raw.at(-1);
  const pressure = raw.reduce((n, p) => n + p.p, 0) / raw.length;
  const duration = last.t - first.t;
  const ends = Math.hypot(last.x - first.x, last.y - first.y);

  if (ends > 0.2 * diag) {
    const deviation = Math.max(...raw.map((p) => segmentDistance(p, first, last)));
    if (deviation <= 0.08 * ends) return finish("line", [first, last], pressure, duration);
    const corners = simplify(raw, 0.08 * diag);
    return corners.length <= 4 ? finish("polyline", corners, pressure, duration) : null;
  }

  const cx = box.x + box.w / 2, cy = box.y + box.h / 2;
  const rx = Math.max(box.w / 2, 0.5), ry = Math.max(box.h / 2, 0.5);
  const error = raw.reduce((n, p) => n + Math.abs(Math.hypot((p.x - cx) / rx, (p.y - cy) / ry) - 1), 0) / raw.length;
  let corners = simplifyClosed(raw, 0.1 * diag);
  // Whichever fits closer: the ellipse, or the polygon through the corners.
  const polygonFit = corners.length >= 3 && corners.length <= 8
    ? raw.reduce((n, p) => n + polygonDistance(p, corners), 0) / raw.length / diag : Infinity;
  const ellipseFit = (error * (rx + ry)) / 2 / diag;
  if (error < 0.16 && ellipseFit <= polygonFit) {
    const round = Math.abs(rx - ry) <= 0.12 * Math.max(rx, ry);
    const r = (rx + ry) / 2;
    const points = Array.from({ length: 65 }, (_, i) => {
      const a = (i / 64) * 2 * Math.PI;
      return { x: cx + (round ? r : rx) * Math.cos(a), y: cy + (round ? r : ry) * Math.sin(a) };
    });
    return finish(round ? "circle" : "ellipse", points, pressure, duration);
  }
  if (polygonFit >= 0.05) return null;
  if (corners.length === 3) return finish("triangle", [...corners, corners[0]], pressure, duration);
  if (corners.length === 4) {
    if ([0, 1, 2, 3].every((i) => axisAligned(corners[i], corners[(i + 1) % 4]))) {
      const b = bounds(corners);
      corners = [{ x: b.x, y: b.y }, { x: b.x + b.w, y: b.y }, { x: b.x + b.w, y: b.y + b.h }, { x: b.x, y: b.y + b.h }];
    }
    return finish("rectangle", [...corners, corners[0]], pressure, duration);
  }
  if (corners.length >= 5 && corners.length <= 8 && polygonFit < 0.05) return finish("polygon", [...corners, corners[0]], pressure, duration);
  return null;
}

/** Distance from p to the closed polygon's edges. */
function polygonDistance(p, corners) {
  let best = Infinity;
  for (let i = 0; i < corners.length; i++) best = Math.min(best, segmentDistance(p, corners[i], corners[(i + 1) % corners.length]));
  return best;
}

function axisAligned(a, b) {
  const angle = Math.abs(Math.atan2(b.y - a.y, b.x - a.x)) % (Math.PI / 2);
  const limit = (12 * Math.PI) / 180;
  return angle <= limit || angle >= Math.PI / 2 - limit;
}

function finish(shape, points, pressure, duration) {
  const n = points.length;
  return { shape, points: points.map((p, i) => ({ x: p.x, y: p.y, p: pressure, t: n > 1 ? (duration * i) / (n - 1) : 0 })) };
}

/** Ramer–Douglas–Peucker: the corners of an open line. */
export function simplify(pts, epsilon) {
  if (pts.length < 3) return pts;
  const a = pts[0], b = pts.at(-1);
  let index = 0, far = 0;
  for (let i = 1; i < pts.length - 1; i++) { const d = segmentDistance(pts[i], a, b); if (d > far) { far = d; index = i; } }
  if (far <= epsilon) return [a, b];
  const left = simplify(pts.slice(0, index + 1), epsilon), right = simplify(pts.slice(index), epsilon);
  return [...left.slice(0, -1), ...right];
}

/** The corners of a closed loop (InkShapes.simplifyClosed). */
export function simplifyClosed(pts, epsilon) {
  const start = pts[0];
  let index = 0, far = 0;
  pts.forEach((p, i) => { const d = Math.hypot(p.x - start.x, p.y - start.y); if (d > far) { far = d; index = i; } });
  if (index === 0) return [start];
  const one = simplify(pts.slice(0, index + 1), epsilon);
  const two = simplify([...pts.slice(index), start], epsilon);
  const merged = [];
  for (const c of [...one.slice(0, -1), ...two.slice(0, -1)]) if (!merged.some((m) => Math.hypot(m.x - c.x, m.y - c.y) < epsilon)) merged.push(c);
  const corners = merged;
  let changed = true;
  while (changed && corners.length > 3) {
    changed = false;
    for (let i = 0; i < corners.length; i++) {
      const prev = corners[(i + corners.length - 1) % corners.length], next = corners[(i + 1) % corners.length];
      if (segmentDistance(corners[i], prev, next) < epsilon) { corners.splice(i, 1); changed = true; break; }
    }
  }
  return corners;
}

// ---------- elements: text boxes and pictures ----------

export const ElementField = { on: "on", layer: "layer", page: "page", type: "type", x: "x", y: "y", w: "w", h: "h", text: "text", size: "size",
  color: "color", image: "image", createdAt: "createdAt", device: "device" };

export function elementView(record) {
  const f = record.fields, num = (v, d) => (typeof v === "number" ? v : d);
  return {
    id: record.id, on: typeof f.on === "string" ? f.on : "", layer: typeof f.layer === "string" ? f.layer : "", pageKey: pageKey(f.page),
    type: f.type === "image" ? "image" : "text", x: num(f.x, 0), y: num(f.y, 0), w: Math.max(1, num(f.w, 200)), h: Math.max(1, num(f.h, 40)),
    text: typeof f.text === "string" ? f.text : "", size: num(f.size, 20), color: typeof f.color === "string" ? f.color : "#000000",
    image: f.image && typeof f.image.id === "string" ? f.image : null, createdAt: num(f.createdAt, 0),
  };
}

/** Lines of a text box wrapped to its width (a canvas context with the font set measures them). */
export function wrapText(ctx, text, width) {
  const out = [];
  for (const para of text.split("\n")) {
    let line = "";
    for (const word of para.split(/(\s+)/)) {
      const next = line + word;
      if (line && ctx.measureText(next.trimEnd()).width > width) { out.push(line.trimEnd()); line = word.trimStart(); } else line = next;
    }
    out.push(line.trimEnd());
  }
  return out;
}

export const textFont = (size) => `${size}px -apple-system, "Segoe UI", system-ui, sans-serif`;

/** Draws a text box: wrapped lines, 1.25 × size apart. */
export function drawTextElement(ctx, e) {
  ctx.save();
  ctx.font = textFont(e.size);
  ctx.fillStyle = e.color;
  ctx.textBaseline = "top";
  wrapText(ctx, e.text, e.w).forEach((line, i) => ctx.fillText(line, e.x, e.y + i * e.size * 1.25));
  ctx.restore();
}

// ---------- scribble to erase (InkScribble.swift; both check Fixtures/ink-scribble.json) ----------

/** How many times a line turns back along x or y (moves under 2 points are ignored), the larger. */
export function reversals(pts) {
  let best = 0;
  for (const axis of ["x", "y"]) {
    let dir = 0, count = 0, anchor = pts[0]?.[axis] ?? 0;
    for (const p of pts) {
      const d = p[axis] - anchor;
      if (Math.abs(d) < 2) continue;
      const s = Math.sign(d);
      if (dir && s !== dir) count++;
      dir = s;
      anchor = p[axis];
    }
    best = Math.max(best, count);
  }
  return best;
}

function segmentsCross(a, b, c, d) {
  const cross = (o, p, q) => (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
  const d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/** How many times two lines cross. */
export function crossings(a, b) {
  let n = 0;
  for (let i = 0; i < a.length - 1; i++) {
    const lo = { x: Math.min(a[i].x, a[i + 1].x), y: Math.min(a[i].y, a[i + 1].y) }, hi = { x: Math.max(a[i].x, a[i + 1].x), y: Math.max(a[i].y, a[i + 1].y) };
    for (let j = 0; j < b.length - 1; j++) {
      if (Math.max(b[j].x, b[j + 1].x) < lo.x || Math.min(b[j].x, b[j + 1].x) > hi.x || Math.max(b[j].y, b[j + 1].y) < lo.y || Math.min(b[j].y, b[j + 1].y) > hi.y) continue;
      if (segmentsCross(a[i], a[i + 1], b[j], b[j + 1])) n++;
    }
  }
  return n;
}

/**
 * Scribble to erase: is this new line a scratch-out over other strokes? A scratch-out turns back at
 * least 6 times, packs at least 3.5 times its longest side of ink, and crosses each stroke it
 * removes at least twice (once if 90 % of it is under the scribble), with 70 % of that stroke inside
 * its box, crossing them at least 4 times in all. Returns the ids it crosses out,
 * or null (then it's an ordinary line). `strokes`: [{id, points}].
 */
export function scribbleTargets(points, strokes) {
  if (points.length < 12) return null;
  const box = bounds(points);
  if (!box || Math.max(box.w, box.h) < 12) return null;
  let length = 0;
  for (let i = 1; i < points.length; i++) length += Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y);
  if (reversals(points) < 6 || length < 3.5 * Math.max(box.w, box.h)) return null;
  const pad = 4, x0 = box.x - pad, y0 = box.y - pad, x1 = box.x + box.w + pad, y1 = box.y + box.h + pad;
  const out = [];
  let total = 0;
  for (const s of strokes) {
    if (!s.points.length) continue;
    const b = bounds(s.points);
    if (b.x > x1 || b.x + b.w < x0 || b.y > y1 || b.y + b.h < y0) continue;
    const pts = resample(s.points, 4);
    const within = pts.filter((p) => p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1).length;
    if (within < 0.7 * pts.length) continue;
    // A dot or tiny mark can't be crossed twice: being under the scribble is enough.
    const n = Math.max(b.w, b.h) < 6 ? (hitsPoints(points, 2, b.x + b.w / 2, b.y + b.h / 2, 3) ? 2 : 0) : crossings(points, s.points);
    // Crossed twice, or once when it lies wholly under the scribble (an upright letter under an upright zigzag).
    if (n < (within >= 0.9 * pts.length ? 1 : 2)) continue;
    total += n;
    out.push(s.id);
  }
  return out.length && total >= 4 ? out : null;
}
