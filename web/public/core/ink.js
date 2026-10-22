// Drawing (PROTOCOL.md §10): a port of Ink.swift. Every stroke is its own `stroke` record on an
// item: a sketch's own pages (layer "") or a file it's drawn on (layer = the attachment id). Both
// sides check Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-cases.json.
import { b64uDecode, b64uEncode } from "./bytes.js";

export const InkField = { on: "on", layer: "layer", page: "page", tool: "tool", color: "color", width: "width", points: "points", points2: "points2",
  createdAt: "createdAt", device: "device", shape: "shape", fill: "fill", dash: "dash", arrow: "arrow", nib: "nib", group: "group", from: "from", to: "to" };
/** Shapes that close on themselves (they can be filled). The last four come from the shape picker (core/inkedit.js). */
export const CLOSED_SHAPES = ["triangle", "rectangle", "polygon", "circle", "ellipse", "diamond", "star", "heart", "bubble"];
export const DASHES = ["dash", "dot"];
export const ARROWS = ["end", "start", "both"];
/** Pen tools. `ballpoint` keeps one thickness; its points are stored at pressure 1, so a client that
 * doesn't know it (and draws it as a `pen`) draws it full and even (PROTOCOL.md §10). */
export const TOOLS = ["pen", "ballpoint", "pencil", "marker", "highlighter", "fountain", "brush"];
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
export const usesPressure = (tool) => tool !== "marker" && tool !== "highlighter" && tool !== "ballpoint";
/** The points as stored (InkTool.stored): a ballpoint's at pressure 1, the rest as drawn. */
export const storedPoints = (tool, points) => (tool === "ballpoint" ? points.map((p) => ({ ...p, p: 1 })) : points);

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

/** Points [{x, y, p, t}] as little-endian float32 quadruples, in base64url. */
export function encodePoints(points) {
  const buf = new DataView(new ArrayBuffer(points.length * 16));
  points.forEach((pt, i) => { [pt.x, pt.y, pt.p, pt.t].forEach((v, k) => buf.setFloat32(i * 16 + k * 4, v ?? 0, true)); });
  return b64uEncode(new Uint8Array(buf.buffer));
}

export function decodePoints(text) {
  let bytes;
  try { bytes = b64uDecode(text ?? ""); } catch { return []; }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = [];
  for (let i = 0; i + 16 <= bytes.length; i += 16) out.push({ x: dv.getFloat32(i, true), y: dv.getFloat32(i + 4, true), p: dv.getFloat32(i + 8, true), t: dv.getFloat32(i + 12, true) });
  return out;
}

/** A stroke's points: `points2` (compact) when it has them, else `points` (PROTOCOL.md §10). */
export function strokePoints(fields) {
  return typeof fields.points2 === "string" && fields.points2 ? decodePoints2(fields.points2) : decodePoints(fields.points);
}

/**
 * The fields that store points: `points2` when the vault writes compact points (settings.ink
 * `compactPoints`), else `points`. `had` (the record's fields) empties the other one if it was set.
 */
export function pointFields(points, compact, had = null) {
  const out = compact ? { points2: encodePoints2(points) } : { points: encodePoints(points) };
  if (had && compact && typeof had.points === "string" && had.points) out.points = "";
  if (had && !compact && typeof had.points2 === "string" && had.points2) out.points2 = "";
  return out;
}

/** A read-only view of a stroke record. `cache` holds its outline and Path2D once drawn. */
export function strokeView(record) {
  const f = record.fields;
  const hex = (v) => (typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v) ? v : null);
  return {
    id: record.id, on: typeof f.on === "string" ? f.on : "", layer: typeof f.layer === "string" ? f.layer : "",
    page: typeof f.page === "number" ? f.page : Number(f.page) || 0, pageKey: pageKey(f.page), tool: TOOLS.includes(f.tool) ? f.tool : "pen",
    shape: typeof f.shape === "string" ? f.shape : null,
    color: typeof f.color === "string" ? f.color : "#000000", width: typeof f.width === "number" ? f.width : 2,
    points: strokePoints(f), createdAt: typeof f.createdAt === "number" ? f.createdAt : 0,
    fill: hex(f.fill), dash: DASHES.includes(f.dash) ? f.dash : null, arrow: ARROWS.includes(f.arrow) ? f.arrow : null,
    nib: typeof f.nib === "number" && Number.isFinite(f.nib) ? f.nib : null,
    group: typeof f.group === "string" ? f.group : "", from: typeof f.from === "string" ? f.from : "", to: typeof f.to === "string" ? f.to : "",
    cache: {},
  };
}

/** The look of a stroke beyond tool, colour and width, copied along with it (duplicate, paste, erased pieces). */
export function strokeStyle(s) {
  const out = {};
  if (s.fill) out.fill = s.fill;
  if (s.dash) out.dash = s.dash;
  if (s.arrow) out.arrow = s.arrow;
  if (typeof s.nib === "number") out.nib = s.nib;
  return out;
}

/**
 * Draws strokes on a 2D canvas context already scaled to page points. Pens, pencils, fountain pens
 * and brushes are one filled outline each (`strokeOutline`, cached as a Path2D per stroke version);
 * markers, highlighters, clean shapes and dashed lines are one even line, highlighters blended
 * under the ink. Closed shapes with `fill` are filled underneath; line shapes get `arrow` heads.
 */
export function drawStrokes(ctx, strokes) {
  for (const s of strokes) drawStroke(ctx, s);
}

export function drawStroke(ctx, s) {
  const pts = s.points;
  if (!pts.length) return;
  ctx.save();
  ctx.globalAlpha = toolOpacity(s.tool);
  if (s.tool === "highlighter") ctx.globalCompositeOperation = "multiply";
  if (s.fill && s.shape && CLOSED_SHAPES.includes(s.shape) && pts.length > 2) {
    ctx.fillStyle = s.fill;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    ctx.closePath();
    ctx.fill();
  }
  const outline = outlineOf(s);
  if (outline) {
    ctx.fillStyle = s.tool === "pencil" ? pencilFill(ctx, s.color) : s.color;
    fillOutline(ctx, s, outline);
  } else {
    ctx.strokeStyle = s.color;
    ctx.fillStyle = s.color;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    const w = lineWidthOf(s);
    if (pts.length === 1) {
      ctx.beginPath();
      ctx.arc(pts[0].x, pts[0].y, w / 2, 0, Math.PI * 2);
      ctx.fill();
    } else {
      const heads = arrowHeads(s);
      const line = heads.length ? trimForArrows(s, w) : pts;
      if (s.dash) ctx.setLineDash?.(dashPattern(s.dash, w));
      ctx.lineWidth = w;
      ctx.beginPath();
      if (s.shape) { ctx.moveTo(line[0].x, line[0].y); for (let i = 1; i < line.length; i++) ctx.lineTo(line[i].x, line[i].y); } else smoothPath(ctx, line);
      ctx.stroke();
      ctx.setLineDash?.([]);
      for (const tri of heads) {
        ctx.beginPath();
        ctx.moveTo(tri[0].x, tri[0].y); ctx.lineTo(tri[1].x, tri[1].y); ctx.lineTo(tri[2].x, tri[2].y);
        ctx.closePath();
        ctx.fill();
      }
    }
  }
  ctx.restore();
}

/** The width an even line is drawn at: markers and highlighters their width, the rest at their average pressure. */
export function lineWidthOf(s) {
  if (!usesPressure(s.tool)) return s.width;
  return widthAt(s.width, s.tool, s.points.length ? average(s.points) : 0.5);
}

/** Dashes three widths long with two-width gaps; dots two widths apart (round caps make them round). */
export const dashPattern = (dash, w) => (dash === "dot" ? [0.001, Math.max(2 * w, 2)] : [Math.max(3 * w, 3), Math.max(2 * w, 2)]);

/** The outline of a stroke, cached on its view; null when it's drawn as an even line. */
function outlineOf(s) {
  if (s.cache && s.cache.outline !== undefined) return s.cache.outline;
  const o = strokeOutline(s);
  if (s.cache) s.cache.outline = o;
  return o;
}

/** Fills an outline: a Path2D made once per stroke version on a real canvas, else traced (PDF export). */
function fillOutline(ctx, s, outline) {
  if (typeof Path2D !== "undefined" && ctx.canvas) {
    let path = s.cache?.path;
    if (!path) {
      path = new Path2D();
      traceOutline(path, outline);
      if (s.cache) s.cache.path = path;
    }
    ctx.fill(path);
    return;
  }
  ctx.beginPath();
  traceOutline(ctx, outline);
  ctx.fill();
}

/** A closed outline as quadratic curves through the midpoints of its corners (smooth, like perfect-freehand). */
export function traceOutline(path, o) {
  const n = o.length;
  if (n < 3) return;
  path.moveTo((o[n - 1].x + o[0].x) / 2, (o[n - 1].y + o[0].y) / 2);
  for (let i = 0; i < n; i++) {
    const b = o[(i + 1) % n];
    path.quadraticCurveTo(o[i].x, o[i].y, (o[i].x + b.x) / 2, (o[i].y + b.y) / 2);
  }
  path.closePath();
}

/** A pencil's colour with grain: `grainTile` as a repeating pattern, one texel per half page point. */
const grainPatterns = new Map();
function pencilFill(ctx, color) {
  if (typeof ctx.createPattern !== "function" || (typeof document === "undefined" && typeof OffscreenCanvas === "undefined")) return color;
  let pattern = grainPatterns.get(color);
  if (!pattern) {
    const size = GRAIN_SIZE, alpha = grainTile();
    const c = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(size, size) : Object.assign(document.createElement("canvas"), { width: size, height: size });
    const g = c.getContext("2d");
    const img = g.createImageData(size, size);
    const [r, gr, b] = rgb(color).map((v) => Math.round(v * 255));
    for (let i = 0; i < size * size; i++) { img.data[i * 4] = r; img.data[i * 4 + 1] = gr; img.data[i * 4 + 2] = b; img.data[i * 4 + 3] = alpha[i]; }
    g.putImageData(img, 0, 0);
    pattern = ctx.createPattern(c, "repeat");
    if (!pattern) return color;
    try { pattern.setTransform(new DOMMatrix([GRAIN_TEXEL, 0, 0, GRAIN_TEXEL, 0, 0])); } catch { /* a texel per point */ }
    if (grainPatterns.size > 32) grainPatterns.clear();
    grainPatterns.set(color, pattern);
  }
  return pattern;
}

/** A pen's width at its i-th point: fountain pens follow their direction and nib, brushes taper at the ends. */
export function pointWidth(s, pts, i) {
  const p = pts[i];
  if (s.tool === "fountain") {
    const q = pts[Math.min(pts.length - 1, i + 1)], o = pts[Math.max(0, i - 1)];
    return fountainWidth(s.width, p.p, q.x - o.x, q.y - o.y, nibAt(s, p));
  }
  if (s.tool === "brush") return widthAt(s.width, s.tool, p.p) * brushTaper(i, pts.length);
  return widthAt(s.width, s.tool, p.p);
}

/** The fountain nib's angle at a point: its own (barrel roll, in `points2`), the stroke's `nib`, else 45°. */
export const nibAt = (s, p) => (typeof p.a === "number" ? p.a : typeof s.nib === "number" ? s.nib : NIB_ANGLE);

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

/**
 * Scale about (ox, oy), turn by `r` radians (clockwise on the page, optional) about it too, then
 * move: x' = ox + cos r·(x − ox)·sx − sin r·(y − oy)·sy + dx (and y' likewise). A point's nib
 * angle turns with it (`transformAngle`).
 */
export const transformPoint = (t, p) => {
  if (!t.r) {
    const out = { ...p, x: t.ox + (p.x - t.ox) * t.sx + t.dx, y: t.oy + (p.y - t.oy) * t.sy + t.dy };
    if (typeof p.a === "number" && (t.sx !== t.sy || t.sx < 0)) out.a = transformAngle(t, p.a);
    return out;
  }
  const x = (p.x - t.ox) * t.sx, y = (p.y - t.oy) * t.sy, c = Math.cos(t.r), s = Math.sin(t.r);
  const out = { ...p, x: t.ox + c * x - s * y + t.dx, y: t.oy + s * x + c * y + t.dy };
  if (typeof p.a === "number") out.a = transformAngle(t, p.a);
  return out;
};
/** A nib angle (radians, in [0, π)) after the transform: its direction scaled and turned. */
export function transformAngle(t, a) {
  const x = Math.cos(a) * t.sx, y = Math.sin(a) * t.sy, r = t.r ?? 0;
  const turned = Math.atan2(Math.sin(r) * x + Math.cos(r) * y, Math.cos(r) * x - Math.sin(r) * y);
  const out = ((turned % Math.PI) + Math.PI) % Math.PI;
  return out >= Math.PI - 1e-12 ? 0 : out;
}
export const widthScale = (t) => Math.sqrt(Math.abs(t.sx) * Math.abs(t.sy));
export const moveBy = (dx, dy) => ({ sx: 1, sy: 1, ox: 0, oy: 0, dx, dy });
/** The box around a transformed box (its four corners when turned). */
export function transformRect(t, r) {
  if (t.r) return bounds([[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h], [r.x, r.y + r.h]].map(([x, y]) => transformPoint(t, { x, y })));
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
      const q = { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, p: a.p + (b.p - a.p) * f, t: a.t + (b.t - a.t) * f };
      if (typeof a.a === "number") q.a = a.a;
      out.push(q);
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

/** Fountain pens write like a nib held at 45° (or `nib`, radians): thin along it, broad across it. */
export function fountainWidth(width, pressure, dx, dy, nib = NIB_ANGLE) {
  const p = Math.min(1, Math.max(0, pressure));
  const across = dx === 0 && dy === 0 ? 0.5 : Math.abs(Math.sin(Math.atan2(dy, dx) - nib));
  return width * (0.25 + 0.75 * across) * (0.6 + 0.4 * p);
}

/** A brush's ends taper over the first and last 15 % of its points. */
export function brushTaper(index, count) {
  if (count <= 2) return 1;
  const edge = Math.max(1, count * 0.15);
  return Math.min(1, Math.max(0.15, Math.min(index + 1, count - index) / edge));
}

// ---------- shapes (InkShapes.swift) ----------

export const SHAPES = ["line", "polyline", "triangle", "rectangle", "polygon", "circle", "ellipse", "curve", "diamond", "star", "heart", "bubble"];

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
  color: "color", image: "image", createdAt: "createdAt", device: "device", rotate: "rotate", flip: "flip", font: "font", bold: "bold", italic: "italic",
  group: "group", quote: "quote", rects: "rects", name: "name", value: "value" };
/** Text box typefaces (`font`; unknown or unset is `sans`). */
export const TEXT_FONTS = ["sans", "serif", "mono", "rounded"];

export function elementView(record) {
  const f = record.fields, num = (v, d) => (typeof v === "number" ? v : d);
  return {
    id: record.id, on: typeof f.on === "string" ? f.on : "", layer: typeof f.layer === "string" ? f.layer : "", pageKey: pageKey(f.page),
    type: ELEMENT_TYPES.includes(f.type) ? f.type : "text", x: num(f.x, 0), y: num(f.y, 0), w: Math.max(1, num(f.w, 200)), h: Math.max(1, num(f.h, 40)),
    text: typeof f.text === "string" ? f.text : "", size: num(f.size, 20), color: typeof f.color === "string" ? f.color : "#000000",
    image: f.image && typeof f.image.id === "string" ? f.image : null, createdAt: num(f.createdAt, 0),
    rotate: typeof f.rotate === "number" && Number.isFinite(f.rotate) ? f.rotate : 0, flip: f.flip === true,
    font: TEXT_FONTS.includes(f.font) ? f.font : "sans", bold: f.bold === true, italic: f.italic === true,
    group: typeof f.group === "string" ? f.group : "",
    // Text highlights and form values on a PDF (core/pdfmarks.js).
    quote: typeof f.quote === "string" ? f.quote : "", rects: Array.isArray(f.rects) ? f.rects : null,
    name: typeof f.name === "string" ? f.name : "", value: f.value ?? null,
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

/** Text boxes, pictures, tape (a strip that hides what's under it until tapped), text highlights and form values (PDFs). */
export const ELEMENT_TYPES = ["text", "image", "tape", "highlight", "field"];
export const TAPE_COLORS = ["#f2c94c", "#9ad0f5", "#f5a3b8", "#a8dba8", "#c7b8f5", "#b0b0b5"];

/**
 * Tape: the colour with faint diagonal stripes, hiding what's under it. Peeked (tapped open, which
 * each device keeps to itself), it's a faint outline so the answer shows through.
 */
export function drawTapeElement(ctx, e, peeked = false) {
  if (e.rotate) { withElementTransform(ctx, e, () => drawTapeElement(ctx, { ...e, rotate: 0 }, peeked)); return; }
  const r = Math.min(4, e.w / 4, e.h / 4);
  const path = () => {
    ctx.beginPath();
    ctx.moveTo(e.x + r, e.y);
    ctx.lineTo(e.x + e.w - r, e.y); ctx.quadraticCurveTo(e.x + e.w, e.y, e.x + e.w, e.y + r);
    ctx.lineTo(e.x + e.w, e.y + e.h - r); ctx.quadraticCurveTo(e.x + e.w, e.y + e.h, e.x + e.w - r, e.y + e.h);
    ctx.lineTo(e.x + r, e.y + e.h); ctx.quadraticCurveTo(e.x, e.y + e.h, e.x, e.y + e.h - r);
    ctx.lineTo(e.x, e.y + r); ctx.quadraticCurveTo(e.x, e.y, e.x + r, e.y);
    ctx.closePath();
  };
  ctx.save();
  ctx.fillStyle = e.color;
  ctx.strokeStyle = e.color;
  if (peeked) {
    ctx.globalAlpha = 0.16;
    path(); ctx.fill();
    ctx.globalAlpha = 0.7;
    ctx.lineWidth = 1;
    ctx.setLineDash?.([4, 3]);
    path(); ctx.stroke();
    ctx.restore();
    return;
  }
  path(); ctx.fill();
  // Stripes, a little darker, across the strip.
  path(); ctx.clip();
  ctx.globalAlpha = 0.1;
  ctx.fillStyle = "#000000";
  const step = 8;
  ctx.beginPath();
  for (let x = e.x - e.h; x < e.x + e.w; x += step * 2) {
    ctx.moveTo(x, e.y); ctx.lineTo(x + step, e.y); ctx.lineTo(x + step + e.h, e.y + e.h); ctx.lineTo(x + e.h, e.y + e.h); ctx.closePath();
  }
  ctx.fill();
  ctx.restore();
}

/** The box a tape strip covers when dragged from `a` to `b`: at least `thick` points in each direction. */
export function tapeBox(a, b, thick) {
  let x = Math.min(a.x, b.x), y = Math.min(a.y, b.y), w = Math.abs(b.x - a.x), h = Math.abs(b.y - a.y);
  if (w < thick) { x -= (thick - w) / 2; w = thick; }
  if (h < thick) { y -= (thick - h) / 2; h = thick; }
  return { x, y, w, h };
}

const FONT_STACKS = {
  sans: '-apple-system, "Segoe UI", system-ui, sans-serif', serif: '"New York", Georgia, "Times New Roman", serif',
  mono: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', rounded: 'ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", system-ui, sans-serif',
};
/** The CSS font of a text box at `size` (with its `font`, `bold` and `italic` when given). */
export const textFont = (size, e = null) =>
  `${e?.italic ? "italic " : ""}${e?.bold ? "bold " : ""}${size}px ${FONT_STACKS[e?.font] ?? FONT_STACKS.sans}`;

/**
 * Runs `draw` with the context turned about the element's centre by its `rotate` (and, for a
 * picture, mirrored left to right when it has `flip`), so `draw` works in the unturned box.
 */
export function withElementTransform(ctx, e, draw) {
  if (!e.rotate && !(e.flip && e.type === "image")) { draw(); return; }
  const cx = e.x + e.w / 2, cy = e.y + e.h / 2;
  ctx.save();
  ctx.translate(cx, cy);
  if (e.rotate) ctx.rotate(e.rotate);
  if (e.flip && e.type === "image") ctx.scale(-1, 1);
  ctx.translate(-cx, -cy);
  draw();
  ctx.restore();
}

/** Draws a text box: wrapped lines, 1.25 × size apart. */
export function drawTextElement(ctx, e) {
  if (e.rotate) { withElementTransform(ctx, e, () => drawTextElement(ctx, { ...e, rotate: 0 })); return; }
  ctx.save();
  ctx.font = textFont(e.size, e);
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

// ---------- outlines, compact points, pen settings, the page grid and pencil grain ----------
// InkOutline.swift does the same; both check Fixtures/ink-outline.json (web/test/make-outline-fixture.mjs).

/** How far each point moves towards the pen (1 = raw), the closest two kept points get, and a half circle's steps. */
export const OUTLINE_STREAMLINE = 0.75, OUTLINE_MIN_GAP = 0.2, OUTLINE_CAP_STEPS = 8, OUTLINE_MIN_RADIUS = 0.15;

/**
 * A stroke as one filled outline (the perfect-freehand method): the points are streamlined a
 * little (the last stays where the pen lifted), each gets its width (`pointWidth`: pressure,
 * fountain direction and nib, brush taper), and the outline runs down the left side at half that
 * width, round the end in a half circle, back along the right side and round the start. Sharp
 * turns get a round corner. Returns the corners [{x, y}] (drawn with `traceOutline`), or null for
 * strokes drawn as an even line: markers, highlighters, clean shapes and dashed lines.
 */
export function strokeOutline(s) {
  if (s.shape || s.dash || !usesPressure(s.tool)) return null;
  const raw = s.points;
  if (!raw.length) return [];
  const pts = [];
  for (const p of raw) {
    const last = pts[pts.length - 1];
    if (!last) { pts.push({ x: p.x, y: p.y, p: p.p, a: p.a }); continue; }
    const x = last.x + (p.x - last.x) * OUTLINE_STREAMLINE, y = last.y + (p.y - last.y) * OUTLINE_STREAMLINE;
    if (Math.hypot(x - last.x, y - last.y) < OUTLINE_MIN_GAP) continue;
    pts.push({ x, y, p: p.p, a: p.a });
  }
  // The line ends where the pen lifted.
  const end = raw[raw.length - 1], tail = pts[pts.length - 1];
  if (raw.length > 1) {
    if (Math.hypot(end.x - tail.x, end.y - tail.y) >= OUTLINE_MIN_GAP) pts.push({ x: end.x, y: end.y, p: end.p, a: end.a });
    else if (pts.length > 1) { tail.x = end.x; tail.y = end.y; }
  }
  const n = pts.length;
  const r = pts.map((_, i) => Math.max(OUTLINE_MIN_RADIUS, pointWidth(s, pts, i) / 2));
  if (n === 1) {
    const out = [];
    for (let k = 0; k < OUTLINE_CAP_STEPS * 2; k++) {
      const a = (Math.PI * k) / OUTLINE_CAP_STEPS;
      out.push({ x: pts[0].x + r[0] * Math.cos(a), y: pts[0].y + r[0] * Math.sin(a) });
    }
    return out;
  }
  const dirs = [];
  for (let i = 0; i < n - 1; i++) {
    const dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y, len = Math.hypot(dx, dy);
    dirs.push(len > 0 ? { x: dx / len, y: dy / len } : i > 0 ? dirs[i - 1] : { x: 1, y: 0 });
  }
  const left = [], right = [];
  const arc = (side, c, radius, from, to) => {
    let delta = to - from;
    while (delta > Math.PI) delta -= 2 * Math.PI;
    while (delta <= -Math.PI) delta += 2 * Math.PI;
    const steps = Math.max(1, Math.ceil(Math.abs(delta) / (Math.PI / OUTLINE_CAP_STEPS)));
    for (let k = 0; k <= steps; k++) { const a = from + (delta * k) / steps; side.push({ x: c.x + radius * Math.cos(a), y: c.y + radius * Math.sin(a) }); }
  };
  for (let i = 0; i < n; i++) {
    const din = dirs[Math.max(0, i - 1)], dout = dirs[Math.min(n - 2, i)], p = pts[i];
    if (i > 0 && i < n - 1 && din.x * dout.x + din.y * dout.y < 0) {
      // A sharp turn: round the corner on both sides.
      const a0 = Math.atan2(din.y, din.x) + Math.PI / 2, a1 = Math.atan2(dout.y, dout.x) + Math.PI / 2;
      arc(left, p, r[i], a0, a1);
      arc(right, p, r[i], a0 + Math.PI, a1 + Math.PI);
      continue;
    }
    let tx = din.x + dout.x, ty = din.y + dout.y, len = Math.hypot(tx, ty);
    if (len < 1e-9) { tx = dout.x; ty = dout.y; len = 1; }
    const nx = -ty / len, ny = tx / len;
    left.push({ x: p.x + nx * r[i], y: p.y + ny * r[i] });
    right.push({ x: p.x - nx * r[i], y: p.y - ny * r[i] });
  }
  const out = [...left];
  const e = dirs[n - 2], ae = Math.atan2(e.y, e.x), last = pts[n - 1];
  for (let k = 1; k < OUTLINE_CAP_STEPS; k++) {
    const a = ae + Math.PI / 2 - (Math.PI * k) / OUTLINE_CAP_STEPS;
    out.push({ x: last.x + r[n - 1] * Math.cos(a), y: last.y + r[n - 1] * Math.sin(a) });
  }
  for (let i = right.length - 1; i >= 0; i--) out.push(right[i]);
  const b = dirs[0], ab = Math.atan2(b.y, b.x), first = pts[0];
  for (let k = 1; k < OUTLINE_CAP_STEPS; k++) {
    const a = ab - Math.PI / 2 - (Math.PI * k) / OUTLINE_CAP_STEPS;
    out.push({ x: first.x + r[0] * Math.cos(a), y: first.y + r[0] * Math.sin(a) });
  }
  return out;
}

/** Arrowheads on a `line` or `polyline` shape with `arrow`: triangles [tip, left, right] in page points. */
export function arrowHeads(s) {
  const pts = s.points;
  if (!s.arrow || (s.shape !== "line" && s.shape !== "polyline" && s.shape !== "curve") || pts.length < 2) return [];
  const w = lineWidthOf(s), length = 4 * w + 6, half = length * 0.45;
  const head = (tip, from) => {
    const dx = tip.x - from.x, dy = tip.y - from.y, d = Math.hypot(dx, dy);
    if (d < 1e-6) return null;
    const ux = dx / d, uy = dy / d, bx = tip.x - ux * length, by = tip.y - uy * length;
    return [{ x: tip.x, y: tip.y }, { x: bx - uy * half, y: by + ux * half }, { x: bx + uy * half, y: by - ux * half }];
  };
  const out = [];
  if (s.arrow === "end" || s.arrow === "both") { const t = head(pts[pts.length - 1], pts[pts.length - 2]); if (t) out.push(t); }
  if (s.arrow === "start" || s.arrow === "both") { const t = head(pts[0], pts[1]); if (t) out.push(t); }
  return out;
}

/** The line under arrowheads stops short of their tips, so its round end doesn't poke out. */
function trimForArrows(s, w) {
  const pts = s.points.map((p) => ({ ...p })), back = 2 * w + 3;
  const pull = (tip, from) => {
    const dx = tip.x - from.x, dy = tip.y - from.y, d = Math.hypot(dx, dy);
    if (d < 1e-6) return;
    const k = Math.min(back, d * 0.9) / d;
    tip.x -= dx * k; tip.y -= dy * k;
  };
  if (s.arrow === "end" || s.arrow === "both") pull(pts[pts.length - 1], pts[pts.length - 2]);
  if (s.arrow === "start" || s.arrow === "both") pull(pts[0], pts[1]);
  return pts;
}

/** The average nib angle of points that have one (a nib turned by π looks the same), in [0, π); null if none do. */
export function meanNib(points) {
  let sx = 0, sy = 0, n = 0;
  for (const p of points) if (typeof p.a === "number" && Number.isFinite(p.a)) { sx += Math.cos(2 * p.a); sy += Math.sin(2 * p.a); n++; }
  if (!n) return null;
  const a = Math.atan2(sy, sx) / 2;
  return a < 0 ? a + Math.PI : a;
}

// ----- compact points (`points2`, PROTOCOL.md §10) -----

/**
 * Positions are kept to 1/256 point: at the deepest zoom (10×) on a 3× screen a point is 30 pixels,
 * so a position is never more than 0.06 of a pixel off, whatever the zoom or size it was drawn at.
 * Pressure and the nib angle are kept to 1/4096 (of 1 and of π), times to a millisecond.
 */
export const POINTS2_SCALE = 256, POINTS2_LEVELS = 4096;
/** Version 1 (still read): 1/20 point, pressure and angle as one byte each. */
export const POINTS2_V1_SCALE = 20;
const roundHalfUp = (v) => Math.floor(v + 0.5);

function pushVarint(out, n) {
  while (n >= 128) { out.push((n % 128) + 128); n = Math.floor(n / 128); }
  out.push(n);
}
const zigzag = (n) => (n >= 0 ? 2 * n : -2 * n - 1);
const unzigzag = (z) => (z % 2 === 0 ? z / 2 : -(z + 1) / 2);
/** A nib angle in [0, π) as a whole number of π/4096 steps, 0…4095. */
const angleLevel = (a) => {
  let v = a % Math.PI;
  if (v < 0) v += Math.PI;
  return roundHalfUp((v / Math.PI) * POINTS2_LEVELS) % POINTS2_LEVELS;
};

/**
 * Points as `points2` (version 2): byte 2, a flags byte (1: each point has a nib angle), the count
 * as a varint, then per point zigzag varint steps from the last point: x and y in 1/256 points,
 * pressure in 1/4096, the time in ms (a plain varint, never negative) and, with angles, the angle in
 * π/4096 taken the short way round (−2048…2047). In base64url. About 6 bytes a point instead of 16.
 */
export function encodePoints2(points) {
  const angles = points.some((p) => typeof p.a === "number");
  const out = [2, angles ? 1 : 0];
  pushVarint(out, points.length);
  let px = 0, py = 0, pp = 0, pt = 0, pa = 0;
  const fin = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  // Far past any page; keeps the steps exact.
  const place = (v) => roundHalfUp(Math.min(1e9, Math.max(-1e9, fin(v))) * POINTS2_SCALE);
  for (const p of points) {
    const x = place(p.x), y = place(p.y);
    const pr = roundHalfUp(Math.min(1, Math.max(0, fin(p.p))) * POINTS2_LEVELS);
    const t = Math.max(pt, roundHalfUp(Math.max(0, fin(p.t))));
    pushVarint(out, zigzag(x - px));
    pushVarint(out, zigzag(y - py));
    pushVarint(out, zigzag(pr - pp));
    pushVarint(out, t - pt);
    if (angles) {
      const a = angleLevel(typeof p.a === "number" ? fin(p.a) : NIB_ANGLE);
      let d = (a - pa) % POINTS2_LEVELS;
      if (d >= POINTS2_LEVELS / 2) d -= POINTS2_LEVELS;
      else if (d < -POINTS2_LEVELS / 2) d += POINTS2_LEVELS;
      pushVarint(out, zigzag(d));
      pa = a;
    }
    px = x; py = y; pp = pr; pt = t;
  }
  return b64uEncode(new Uint8Array(out));
}

/** Reads `points2` version 2, and version 1 (1/20 point, one byte each for pressure and angle). */
export function decodePoints2(text) {
  let bytes;
  try { bytes = b64uDecode(text ?? ""); } catch { return []; }
  if (bytes.length < 3 || (bytes[0] !== 1 && bytes[0] !== 2)) return [];
  const v1 = bytes[0] === 1, angles = (bytes[1] & 1) === 1;
  const scale = v1 ? POINTS2_V1_SCALE : POINTS2_SCALE;
  let i = 2;
  const varint = () => {
    let n = 0, mul = 1;
    for (;;) {
      if (i >= bytes.length || mul > 2 ** 49) throw new Error("short");
      const b = bytes[i++];
      n += (b & 127) * mul;
      if (b < 128) return n;
      mul *= 128;
    }
  };
  const byte = () => { if (i >= bytes.length) throw new Error("short"); return bytes[i++]; };
  const out = [];
  try {
    const count = varint();
    let x = 0, y = 0, p = 0, t = 0, a = 0;
    for (let k = 0; k < count; k++) {
      x += unzigzag(varint());
      y += unzigzag(varint());
      p = v1 ? byte() : p + unzigzag(varint());
      t += varint();
      const pt = { x: x / scale, y: y / scale, p: Math.min(1, Math.max(0, v1 ? p / 255 : p / POINTS2_LEVELS)), t };
      if (angles) {
        if (v1) pt.a = (byte() * Math.PI) / 256;
        else {
          a = (((a + unzigzag(varint())) % POINTS2_LEVELS) + POINTS2_LEVELS) % POINTS2_LEVELS;
          pt.a = (a * Math.PI) / POINTS2_LEVELS;
        }
      }
      out.push(pt);
    }
  } catch { /* cut short: what was read */ }
  return out;
}

// ----- pen settings (settings.ink, PROTOCOL.md §10) -----

export const INK_SETTINGS_ID = "settings.ink";
export const PRESSURE_CURVES = ["soft", "normal", "firm"];
export const MAX_FAVOURITES = 10, MAX_PALETTE = 24;

const clampInt = (v, lo, hi, d) => (typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : d);
const isHex = (v) => typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v);

/** A pen's settings, cleaned: smoothing 0–100, pressure curve soft/normal/firm, minimum width 0–100 %. */
export function penSettingsOf(v) {
  const o = v && typeof v === "object" ? v : {};
  return { smoothing: clampInt(o.smoothing, 0, 100, 0), curve: PRESSURE_CURVES.includes(o.curve) ? o.curve : "normal", minWidth: clampInt(o.minWidth, 0, 100, 0) };
}

/**
 * The drawing settings every device follows, from the `settings.ink` record's fields: each pen's
 * settings (field `pen.<tool>`), up to 10 favourites ({tool, color, width}), a custom palette (up
 * to 24 colours) and `compactPoints` (write `points2`).
 */
export function inkSettingsOf(fields) {
  const f = fields ?? {};
  const pens = {};
  for (const t of TOOLS) pens[t] = penSettingsOf(f[`pen.${t}`]);
  const favourites = (Array.isArray(f.favourites) ? f.favourites : [])
    .filter((x) => x && TOOLS.includes(x.tool) && isHex(x.color) && typeof x.width === "number" && x.width > 0 && x.width <= 200)
    .slice(0, MAX_FAVOURITES).map((x) => ({ tool: x.tool, color: x.color.toLowerCase(), width: x.width }));
  const palette = (Array.isArray(f.palette) ? f.palette : []).filter(isHex).map((c) => c.toLowerCase()).slice(0, MAX_PALETTE);
  return { pens, favourites, palette, compactPoints: f.compactPoints === true };
}

/** Pressure after a pen's curve and minimum: m + (1 − m) · curve(p), with soft p^0.6 and firm p^1.6. */
export function pressureAfter(pressure, settings) {
  const p = Math.min(1, Math.max(0, pressure));
  const c = settings.curve === "soft" ? p ** 0.6 : settings.curve === "firm" ? p ** 1.6 : p;
  const m = settings.minWidth / 100;
  return m + (1 - m) * c;
}

/**
 * A pen's settings applied while points are captured, so the stored stroke is what was shown:
 * the pressure curve and minimum, and the stabiliser (each point moves k = 1 − 0.9 · smoothing/100
 * of the way from the last one to the pen; when the pen lifts, the line ends where it is).
 */
export class PenFilter {
  constructor(settings) { this.settings = penSettingsOf(settings); this.k = 1 - 0.9 * (this.settings.smoothing / 100); this.last = null; }
  add(p) {
    const q = { x: p.x, y: p.y, p: pressureAfter(p.p, this.settings), t: p.t };
    if (typeof p.a === "number") q.a = p.a;
    if (this.last) { q.x = this.last.x + (p.x - this.last.x) * this.k; q.y = this.last.y + (p.y - this.last.y) * this.k; }
    this.last = q;
    return q;
  }
  /** Where the pen lifted, when smoothing left the line short of it (else null). */
  end(p) {
    if (!this.last || this.settings.smoothing === 0 || Math.hypot(p.x - this.last.x, p.y - this.last.y) < 0.5) return null;
    const q = { x: p.x, y: p.y, p: pressureAfter(p.p, this.settings), t: p.t };
    if (typeof p.a === "number") q.a = p.a;
    return q;
  }
}

export function filterPoints(raw, settings) {
  const f = new PenFilter(settings);
  const out = raw.map((p) => f.add(p));
  if (raw.length > 1) { const e = f.end(raw[raw.length - 1]); if (e) out.push(e); }
  return out;
}

// ----- the page grid: strokes near a point without testing them all -----

/** Boxes in a grid of 256-point cells, so the eraser, lasso and scribble-to-erase test only nearby strokes. */
export class InkGrid {
  constructor(cell = 256) { this.cell = cell; this.cells = new Map(); this.boxes = new Map(); this.big = new Set(); }
  span(r) {
    const c = this.cell;
    return [Math.floor(r.x / c), Math.floor(r.y / c), Math.floor((r.x + r.w) / c), Math.floor((r.y + r.h) / c)];
  }
  add(id, r) {
    this.remove(id);
    if (!r || ![r.x, r.y, r.w, r.h].every(Number.isFinite)) return;
    this.boxes.set(id, r);
    const [i0, j0, i1, j1] = this.span(r);
    // Huge strokes (a whiteboard's frame) go in one list every query looks at.
    if ((i1 - i0 + 1) * (j1 - j0 + 1) > 64) { this.big.add(id); return; }
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
      const k = `${i},${j}`;
      let set = this.cells.get(k);
      if (!set) this.cells.set(k, set = new Set());
      set.add(id);
    }
  }
  remove(id) {
    const r = this.boxes.get(id);
    if (!r) return;
    this.boxes.delete(id);
    if (this.big.delete(id)) return;
    const [i0, j0, i1, j1] = this.span(r);
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) this.cells.get(`${i},${j}`)?.delete(id);
  }
  /** Ids whose box touches `r`, sorted. */
  query(r) {
    const out = new Set();
    const hit = (id) => { const b = this.boxes.get(id); if (b && b.x <= r.x + r.w && r.x <= b.x + b.w && b.y <= r.y + r.h && r.y <= b.y + b.h) out.add(id); };
    for (const id of this.big) hit(id);
    const [i0, j0, i1, j1] = this.span(r);
    if ((i1 - i0 + 1) * (j1 - j0 + 1) > 4096) { for (const id of this.boxes.keys()) hit(id); }
    else for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) for (const id of this.cells.get(`${i},${j}`) ?? []) hit(id);
    return [...out].sort();
  }
}

/** The box a stroke covers as drawn: its points, half its width out (more with arrowheads). Cached on its view. */
export function strokeBounds(s) {
  if (s.cache && s.cache.bounds !== undefined) return s.cache.bounds;
  const b = bounds(s.points, s.width / 2 + (s.arrow ? 2 * s.width + 6 : 0) + 1);
  if (s.cache) s.cache.bounds = b;
  return b;
}

// ----- pencil grain -----

export const GRAIN_SIZE = 64, GRAIN_TEXEL = 0.5;

/** A well-mixed 32-bit hash of a cell (Swift does the same with UInt32 arithmetic). */
function grainHash(x, y, seed) {
  let h = Math.imul(x, 0x27d4eb2d) ^ Math.imul(y, 0x165667b1) ^ seed;
  h = Math.imul(h ^ (h >>> 15), 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0) & 255;
}

/**
 * The pencil's grain: a 64 × 64 tile of alpha values (150–255) that repeats seamlessly, fine
 * noise mixed with 2 × 2 specks, drawn a texel every half page point inside the outline.
 */
let grain = null;
export function grainTile() {
  if (grain) return grain;
  grain = new Uint8Array(GRAIN_SIZE * GRAIN_SIZE);
  for (let y = 0; y < GRAIN_SIZE; y++) for (let x = 0; x < GRAIN_SIZE; x++) {
    const n1 = grainHash(x, y, 1), n2 = grainHash(x >> 1, y >> 1, 2);
    grain[y * GRAIN_SIZE + x] = 150 + Math.floor(((6 * n1 + 4 * n2) * 105) / 2550);
  }
  return grain;
}
