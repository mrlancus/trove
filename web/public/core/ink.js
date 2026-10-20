// Drawing (PROTOCOL.md §10): a port of Ink.swift. Every stroke is its own `stroke` record on an
// item: a sketch's own pages (layer "") or a file it's drawn on (layer = the attachment id). Both
// sides check Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-cases.json.
import { b64uDecode, b64uEncode } from "./bytes.js";

export const InkField = { on: "on", layer: "layer", page: "page", tool: "tool", color: "color", width: "width", points: "points", createdAt: "createdAt", device: "device" };
export const TOOLS = ["pen", "pencil", "marker", "highlighter"];
export const PAPERS = ["blank", "lined", "grid", "dotted"];
/** Line spacing of lined, squared and dotted paper, in page points. */
export const PAPER_SPACING = 32;
export const SKETCH_SIZE = [768, 1024];

export const toolOpacity = (tool) => ({ pencil: 0.85, highlighter: 0.35 })[tool] ?? 1;
export const usesPressure = (tool) => tool === "pen" || tool === "pencil";

/** The width at a point: pressure thins pens and pencils (35 % of `width` at no pressure). */
export const widthAt = (width, tool, pressure) => (usesPressure(tool) ? width * (0.35 + 0.65 * Math.min(1, Math.max(0, pressure))) : width);

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

/** A read-only view of a stroke record. */
export function strokeView(record) {
  const f = record.fields;
  return {
    id: record.id, on: typeof f.on === "string" ? f.on : "", layer: typeof f.layer === "string" ? f.layer : "",
    page: typeof f.page === "number" ? f.page : 0, tool: TOOLS.includes(f.tool) ? f.tool : "pen",
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
  } else if (!usesPressure(s.tool) || s.tool === "pencil") {
    ctx.lineWidth = s.tool === "pencil" ? widthAt(s.width, s.tool, average(pts)) : s.width;
    ctx.beginPath();
    smoothPath(ctx, pts);
    ctx.stroke();
  } else {
    // Each piece from the middle of one segment to the middle of the next, at that point's width.
    for (let i = 0; i < pts.length - 1; i++) {
      const a = i === 0 ? pts[0] : mid(pts[i - 1], pts[i]);
      const b = i === pts.length - 2 ? pts[i + 1] : mid(pts[i], pts[i + 1]);
      ctx.lineWidth = widthAt(s.width, s.tool, pts[i].p);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, b.x, b.y);
      ctx.stroke();
    }
  }
  ctx.restore();
}

const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const average = (pts) => pts.reduce((n, p) => n + p.p, 0) / pts.length;

function smoothPath(ctx, pts) {
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length - 1; i++) { const m = mid(pts[i], pts[i + 1]); ctx.quadraticCurveTo(pts[i].x, pts[i].y, m.x, m.y); }
  ctx.lineTo(pts.at(-1).x, pts.at(-1).y);
}

/** Lined, squared or dotted paper on a page of `w` × `h` points. */
export function drawPaper(ctx, paper, w, h) {
  ctx.save();
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, w, h);
  const s = PAPER_SPACING;
  ctx.strokeStyle = "rgba(90, 130, 200, 0.28)";
  ctx.fillStyle = "rgba(90, 110, 140, 0.45)";
  ctx.lineWidth = 1;
  if (paper === "lined") for (let y = s * 3; y < h; y += s) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }
  if (paper === "grid") {
    for (let y = s; y < h; y += s) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }
    for (let x = s; x < w; x += s) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
  }
  if (paper === "dotted") for (let y = s; y < h; y += s) for (let x = s; x < w; x += s) { ctx.beginPath(); ctx.arc(x, y, 1.3, 0, Math.PI * 2); ctx.fill(); }
  ctx.restore();
}

/** True if the point is within `radius` of the stroke's line (for the stroke eraser). */
export function hits(s, x, y, radius) {
  const r = radius + s.width / 2;
  const pts = s.points;
  if (pts.length === 1) return Math.hypot(pts[0].x - x, pts[0].y - y) <= r;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1], dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy;
    const t = len ? Math.max(0, Math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / len)) : 0;
    if (Math.hypot(a.x + t * dx - x, a.y + t * dy - y) <= r) return true;
  }
  return false;
}
