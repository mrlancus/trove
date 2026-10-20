// A small PDF writer for exporting drawings. `PdfContext` takes the subset of the canvas 2D API that
// core/ink.js draws with (paths, arcs, fills, strokes, alpha, multiply, text), so pages export as
// vectors with exactly the code that draws them on screen. Pictures go in as JPEG.

/** A PDF being built: add pages, then `bytes()`. */
export class PdfDocument {
  constructor() {
    this.objects = []; // [id] → Uint8Array | string body
    this.pages = [];
    this.catalog = this.reserve();
    this.pagesId = this.reserve();
    this.font = this.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
  }

  reserve() { this.objects.push(null); return this.objects.length; }
  add(body) { this.objects.push(body); return this.objects.length; }
  set(id, body) { this.objects[id - 1] = body; }

  stream(dict, data) {
    // Content is ASCII plus WinAnsi text bytes, so one byte per character.
    const bytes = typeof data === "string" ? latin1(data) : data;
    return this.add([`<< ${dict} /Length ${bytes.length} >>\nstream\n`, bytes, "\nendstream"]);
  }

  /** A page `w` × `h` points; returns its context (top-left origin, y down, like a canvas). */
  page(w, h) {
    const ctx = new PdfContext(this, w, h);
    this.pages.push(ctx);
    return ctx;
  }

  /** A JPEG as an image XObject. */
  jpeg(bytes, width, height) {
    return this.stream(`/Type /XObject /Subtype /Image /Width ${width} /Height ${height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode`, bytes);
  }

  bytes() {
    const kids = [];
    for (const page of this.pages) {
      const content = this.stream("", page.ops.join("\n"));
      const gs = [...page.states.entries()].map(([name, id]) => `/${name} ${id} 0 R`).join(" ");
      const xo = [...page.images.entries()].map(([name, id]) => `/${name} ${id} 0 R`).join(" ");
      kids.push(this.add(`<< /Type /Page /Parent ${this.pagesId} 0 R /MediaBox [0 0 ${num(page.width)} ${num(page.height)}] /Contents ${content} 0 R `
        + `/Resources << /Font << /F1 ${this.font} 0 R >> /ExtGState << ${gs} >> /XObject << ${xo} >> >> >>`));
    }
    this.set(this.pagesId, `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`);
    this.set(this.catalog, `<< /Type /Catalog /Pages ${this.pagesId} 0 R >>`);
    const parts = ["%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"];
    const offsets = [];
    let length = 0;
    const push = (p) => { const b = typeof p === "string" ? latin1(p) : p; parts.push(b); length += b.length; };
    parts[0] = latin1(parts[0]);
    length = parts[0].length;
    this.objects.forEach((body, i) => {
      offsets.push(length);
      push(`${i + 1} 0 obj\n`);
      for (const piece of Array.isArray(body) ? body : [body]) push(piece);
      push("\nendobj\n");
    });
    const xref = length;
    push(`xref\n0 ${this.objects.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`);
    push(`trailer\n<< /Size ${this.objects.length + 1} /Root ${this.catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
    const out = new Uint8Array(length);
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  }
}

const num = (v) => (Math.abs(v) < 1e-6 ? "0" : (Math.round(v * 1000) / 1000).toString());
const latin1 = (s) => Uint8Array.from(s, (c) => c.charCodeAt(0) & 0xff);

/** "#rrggbb", "#rgb", "rgb(…)" or "rgba(…)" → [r, g, b, a] in 0…1. */
export function parseColor(c) {
  if (typeof c !== "string") return [0, 0, 0, 1];
  let m = /^#([0-9a-f]{6})$/i.exec(c);
  if (m) { const v = parseInt(m[1], 16); return [(v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255, 1]; }
  m = /^#([0-9a-f]{3})$/i.exec(c);
  if (m) return [...m[1]].map((x) => parseInt(x + x, 16) / 255).concat(1);
  m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/.exec(c);
  if (m) return [m[1] / 255, m[2] / 255, m[3] / 255, m[4] === undefined ? 1 : Number(m[4])];
  return [0, 0, 0, 1];
}

/** WinAnsi text for Helvetica: characters it can't show become "?". */
function pdfText(s) {
  let out = "";
  for (const ch of s) {
    const code = ch.codePointAt(0);
    const c = code < 256 && code >= 32 ? String.fromCharCode(code) : { 0x2019: "\x92", 0x2018: "\x91", 0x201C: "\x93", 0x201D: "\x94", 0x2013: "\x96", 0x2014: "\x97", 0x2026: "\x85", 0x20AC: "\x80" }[code] ?? "?";
    out += c === "(" || c === ")" || c === "\\" ? "\\" + c : c;
  }
  return out;
}

const measurer = typeof document !== "undefined" ? document.createElement("canvas").getContext("2d") : null;

/** The canvas calls ink.js makes, written as PDF operators on a page. */
export class PdfContext {
  constructor(doc, width, height) {
    this.doc = doc;
    this.width = width;
    this.height = height;
    // Flip once so the page draws top-down, like a canvas.
    this.ops = [`1 0 0 -1 0 ${num(height)} cm`];
    this.states = new Map();
    this.images = new Map();
    this.path = [];
    this.stack = [];
    Object.assign(this, { fillStyle: "#000", strokeStyle: "#000", lineWidth: 1, globalAlpha: 1, lineCap: "butt", lineJoin: "miter",
      globalCompositeOperation: "source-over", font: "10px sans-serif", textBaseline: "alphabetic" });
  }

  save() { this.stack.push(this.snapshot()); this.ops.push("q"); }
  restore() { const s = this.stack.pop(); if (s) Object.assign(this, s); this.ops.push("Q"); }
  snapshot() {
    const { fillStyle, strokeStyle, lineWidth, globalAlpha, lineCap, lineJoin, globalCompositeOperation, font, textBaseline } = this;
    return { fillStyle, strokeStyle, lineWidth, globalAlpha, lineCap, lineJoin, globalCompositeOperation, font, textBaseline };
  }
  setTransform() { /* drawings are already in page points */ }

  beginPath() { this.path = []; this.last = null; this.start = null; }
  moveTo(x, y) { this.path.push(`${num(x)} ${num(y)} m`); this.last = [x, y]; this.start = [x, y]; }
  lineTo(x, y) { if (!this.last) return this.moveTo(x, y); this.path.push(`${num(x)} ${num(y)} l`); this.last = [x, y]; }
  quadraticCurveTo(cx, cy, x, y) {
    const [x0, y0] = this.last ?? [cx, cy];
    if (!this.last) this.moveTo(x0, y0);
    const c1x = x0 + (2 / 3) * (cx - x0), c1y = y0 + (2 / 3) * (cy - y0), c2x = x + (2 / 3) * (cx - x), c2y = y + (2 / 3) * (cy - y);
    this.path.push(`${num(c1x)} ${num(c1y)} ${num(c2x)} ${num(c2y)} ${num(x)} ${num(y)} c`);
    this.last = [x, y];
  }
  closePath() { this.path.push("h"); this.last = this.start; }
  /** Full and partial circles as Bézier quarters. */
  arc(x, y, r, a0, a1) {
    const span = Math.min(Math.PI * 2, a1 - a0), n = Math.max(1, Math.ceil(span / (Math.PI / 2))), step = span / n;
    const k = (4 / 3) * Math.tan(step / 4);
    let a = a0;
    const sx = x + r * Math.cos(a), sy = y + r * Math.sin(a);
    if (this.last) this.lineTo(sx, sy); else this.moveTo(sx, sy);
    for (let i = 0; i < n; i++) {
      const b = a + step;
      const p1x = x + r * (Math.cos(a) - k * Math.sin(a)), p1y = y + r * (Math.sin(a) + k * Math.cos(a));
      const p2x = x + r * (Math.cos(b) + k * Math.sin(b)), p2y = y + r * (Math.sin(b) - k * Math.cos(b));
      this.path.push(`${num(p1x)} ${num(p1y)} ${num(p2x)} ${num(p2y)} ${num(x + r * Math.cos(b))} ${num(y + r * Math.sin(b))} c`);
      a = b;
    }
    this.last = [x + r * Math.cos(a), y + r * Math.sin(a)];
  }
  rect(x, y, w, h) { this.path.push(`${num(x)} ${num(y)} ${num(w)} ${num(h)} re`); }

  /** Alpha and blend mode as an ExtGState; `fill` picks which alpha the colour's own alpha multiplies. */
  style(color) {
    const [r, g, b, a] = parseColor(color);
    const alpha = Math.max(0, Math.min(1, a * this.globalAlpha));
    const blend = this.globalCompositeOperation === "multiply" ? "Multiply" : "Normal";
    const key = `GS${Math.round(alpha * 1000)}${blend === "Multiply" ? "m" : ""}`;
    if (!this.states.has(key)) this.states.set(key, this.doc.add(`<< /Type /ExtGState /ca ${num(alpha)} /CA ${num(alpha)} /BM /${blend} >>`));
    return { rgb: `${num(r)} ${num(g)} ${num(b)}`, gs: `/${key} gs` };
  }

  stroke() {
    if (!this.path.length) return;
    const s = this.style(this.strokeStyle);
    const cap = { butt: 0, round: 1, square: 2 }[this.lineCap] ?? 0, join = { miter: 0, round: 1, bevel: 2 }[this.lineJoin] ?? 0;
    this.ops.push("q", s.gs, `${s.rgb} RG`, `${num(this.lineWidth)} w ${cap} J ${join} j`, ...this.path, "S", "Q");
  }
  fill() {
    if (!this.path.length) return;
    const s = this.style(this.fillStyle);
    this.ops.push("q", s.gs, `${s.rgb} rg`, ...this.path, "f", "Q");
  }
  fillRect(x, y, w, h) { const keep = this.path; this.path = [`${num(x)} ${num(y)} ${num(w)} ${num(h)} re`]; this.fill(); this.path = keep; }
  clearRect() {}

  measureText(text) {
    if (measurer) { measurer.font = this.font; return measurer.measureText(text); }
    return { width: text.length * this.fontSize() * 0.5 };
  }
  fontSize() { return Number(/([\d.]+)px/.exec(this.font)?.[1] ?? 10); }

  fillText(text, x, y) {
    const size = this.fontSize();
    // Helvetica's ascent is about 0.77 em, so a "top" baseline sits that far down.
    const base = this.textBaseline === "top" ? y + size * 0.77 : this.textBaseline === "middle" ? y + size * 0.3 : y;
    const s = this.style(this.fillStyle);
    this.ops.push("q", s.gs, `${s.rgb} rg`, "BT", `/F1 ${num(size)} Tf`, `1 0 0 -1 ${num(x)} ${num(base)} Tm`, `(${pdfText(text)}) Tj`, "ET", "Q");
  }

  /** A JPEG (bytes, with its pixel size) into the box x, y, w, h. */
  drawJpeg(bytes, pxWidth, pxHeight, x, y, w, h) {
    const id = this.doc.jpeg(bytes, pxWidth, pxHeight);
    const name = `Im${id}`;
    this.images.set(name, id);
    // Images map the unit square; flip it back since the page is flipped.
    this.ops.push("q", `${num(w)} 0 0 ${num(-h)} ${num(x)} ${num(y + h)} cm`, `/${name} Do`, "Q");
  }
}
