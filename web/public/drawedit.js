// Pieces of the drawing editor's S3 tools (draw.js imports them): drawing the ruler and protractor,
// hit-testing their bodies and knobs, a selection as a PNG, and previews of library elements.
import { drawStroke, drawTapeElement, drawTextElement } from "./core/ink.js";
import { PROTRACTOR_RADIUS, protractorDegrees, RULER_LENGTH, RULER_WIDTH, toolDegrees } from "./core/inkedit.js";

const KNOB = 20; // points from a ruler's end to its turning knob

/** Runs `draw` in a tool's frame: origin at its centre, x along it. */
function framed(ctx, g, draw) {
  ctx.save();
  ctx.translate(g.x, g.y);
  ctx.rotate(g.angle);
  draw();
  ctx.restore();
}

/**
 * The ruler and protractor on a page's live layer (page points; `px` is one screen pixel). Each is
 * see-through with ticks, its angle in the middle and round knobs to turn it.
 */
export function drawGuides(ctx, guides, px) {
  const { ruler, protractor } = guides;
  ctx.save();
  ctx.lineWidth = px;
  ctx.font = `600 ${12 * px}px system-ui, sans-serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  if (ruler) {
    const L = ruler.length ?? RULER_LENGTH, W = ruler.width ?? RULER_WIDTH;
    framed(ctx, ruler, () => {
      ctx.fillStyle = "rgba(200, 205, 215, 0.55)";
      ctx.strokeStyle = "rgba(60, 64, 72, 0.8)";
      ctx.fillRect(-L / 2, -W / 2, L, W);
      ctx.strokeRect(-L / 2, -W / 2, L, W);
      ctx.beginPath();
      for (let u = -L / 2 + 8, i = 1; u < L / 2; u += 8, i++) {
        const long = i % 5 === 0 ? 12 : 6;
        ctx.moveTo(u, -W / 2); ctx.lineTo(u, -W / 2 + long);
        ctx.moveTo(u, W / 2); ctx.lineTo(u, W / 2 - long);
      }
      ctx.stroke();
      for (const u of [-L / 2 + KNOB, L / 2 - KNOB]) {
        ctx.beginPath();
        ctx.arc(u, 0, 9 * px, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(255,255,255,0.9)";
        ctx.fill();
        ctx.stroke();
      }
      ctx.fillStyle = "rgba(30, 32, 36, 0.9)";
      ctx.fillText(`${Math.round(toolDegrees(ruler.angle))}°`, 0, 0);
    });
  }
  if (protractor) {
    const R = protractor.radius ?? PROTRACTOR_RADIUS;
    framed(ctx, protractor, () => {
      ctx.beginPath();
      ctx.moveTo(-R, 0);
      ctx.arc(0, 0, R, Math.PI, Math.PI * 2);
      ctx.closePath();
      ctx.fillStyle = "rgba(200, 205, 215, 0.5)";
      ctx.strokeStyle = "rgba(60, 64, 72, 0.8)";
      ctx.fill();
      ctx.stroke();
      ctx.beginPath();
      for (let d = 0; d <= 180; d += 5) {
        const a = -(d * Math.PI) / 180, long = d % 30 === 0 ? 16 : d % 10 === 0 ? 10 : 5;
        ctx.moveTo(R * Math.cos(a), R * Math.sin(a));
        ctx.lineTo((R - long) * Math.cos(a), (R - long) * Math.sin(a));
      }
      ctx.moveTo(-4, 0); ctx.lineTo(4, 0); ctx.moveTo(0, -4); ctx.lineTo(0, 4);
      ctx.stroke();
      ctx.fillStyle = "rgba(30, 32, 36, 0.8)";
      ctx.font = `${10 * px}px system-ui, sans-serif`;
      for (let d = 0; d <= 180; d += 30) { const a = -(d * Math.PI) / 180; ctx.fillText(String(d), (R - 28) * Math.cos(a), (R - 28) * Math.sin(a)); }
      ctx.beginPath();
      for (const u of [-R + KNOB, R - KNOB]) { ctx.moveTo(u + 9 * px, 10); ctx.arc(u, 10, 9 * px, 0, Math.PI * 2); }
      ctx.fillStyle = "rgba(255,255,255,0.9)";
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = "rgba(30, 32, 36, 0.9)";
      ctx.font = `600 ${13 * px}px system-ui, sans-serif`;
      const reading = protractor.reading ? protractorDegrees(protractor, protractor.reading) : toolDegrees(protractor.angle);
      ctx.fillText(`${Math.round(reading)}°`, 0, -R * 0.45);
    });
    if (protractor.reading) {
      // The line from the centre to the pen, whose angle is shown.
      ctx.strokeStyle = "rgba(10, 132, 255, 0.9)";
      ctx.lineWidth = 1.5 * px;
      ctx.beginPath();
      ctx.moveTo(protractor.x, protractor.y);
      ctx.lineTo(protractor.reading.x, protractor.reading.y);
      ctx.stroke();
    }
  }
  ctx.restore();
}

/** What a point (page points) is on: {kind: "ruler" | "protractor", turn: knob index (−1 | 1) or 0 to move it}, or null. */
export function guideHit(guides, p, px) {
  const local = (g) => {
    const c = Math.cos(g.angle), s = Math.sin(g.angle), dx = p.x - g.x, dy = p.y - g.y;
    return { u: dx * c + dy * s, v: -dx * s + dy * c };
  };
  const knob = 16 * px;
  const { ruler, protractor } = guides;
  if (protractor) {
    const R = protractor.radius ?? PROTRACTOR_RADIUS, { u, v } = local(protractor);
    for (const side of [-1, 1]) if (Math.hypot(u - side * (R - KNOB), v - 10) <= knob) return { kind: "protractor", turn: side };
    if (v <= 4 * px && Math.hypot(u, v) <= R - 18) return { kind: "protractor", turn: 0 };
  }
  if (ruler) {
    const L = ruler.length ?? RULER_LENGTH, W = ruler.width ?? RULER_WIDTH, { u, v } = local(ruler);
    for (const side of [-1, 1]) if (Math.hypot(u - side * (L / 2 - KNOB), v) <= knob) return { kind: "ruler", turn: side };
    if (Math.abs(u) <= L / 2 && Math.abs(v) <= W / 2 - 10) return { kind: "ruler", turn: 0 };
  }
  return null;
}

/** A PNG of `box` (page points) at `scale` pixels a point, drawn by `draw(ctx)` on a transparent background. */
export function renderSelectionPNG(box, scale, draw) {
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(box.w * scale));
  canvas.height = Math.max(1, Math.round(box.h * scale));
  const ctx = canvas.getContext("2d");
  ctx.setTransform(scale, 0, 0, scale, -box.x * scale, -box.y * scale);
  draw(ctx);
  return new Promise((done) => canvas.toBlob(done, "image/png"));
}

/** A small preview of a library element (pictures drawn by `drawPicture(ctx, e)` when given). */
export function stickerCanvas(sticker, size = 64, drawPicture = null) {
  const dpr = Math.min(globalThis.devicePixelRatio || 1, 2);
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = Math.round(size * dpr);
  canvas.className = "ink-sticker-canvas";
  const ctx = canvas.getContext("2d");
  const k = (Math.min(size / Math.max(sticker.w, 1), size / Math.max(sticker.h, 1), 1.5) * 0.9) * dpr;
  ctx.setTransform(k, 0, 0, k, (canvas.width - sticker.w * k) / 2, (canvas.height - sticker.h * k) / 2);
  for (const e of sticker.elements) if (e.type === "image") drawPicture?.(ctx, e);
  for (const s of sticker.strokes) drawStroke(ctx, s);
  for (const e of sticker.elements) if (e.type === "text") drawTextElement(ctx, e);
  for (const e of sticker.elements) if (e.type === "tape") drawTapeElement(ctx, e);
  return canvas;
}
