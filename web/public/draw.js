// The drawing editor: sketches and ink on PDFs and images (PROTOCOL.md §10, core/ink.js).
// - Pens (pen, pencil, fountain pen, brush, marker, highlighter), an eraser (whole strokes or
//   partial, optionally highlighter only), the lasso (move, resize, recolour, duplicate, copy,
//   delete), shapes (a shape mode, and holding the pen still at the end of a line snaps it), text
//   boxes and pictures.
// - Sketches have a page panel (add, duplicate, reorder, delete, paper and colour per page) or one
//   endless canvas. Export to PDF.
// - Apple Pencil (or any pen) draws and fingers scroll and pinch; without a pen, one finger draws
//   and two scroll and pinch. Two-finger tap undoes, three-finger tap redoes. A mouse or trackpad
//   draws, the wheel scrolls, ⌘/Ctrl + wheel zooms.
import { h } from "./dom.js";
import {
  bounds, drawPaper, drawStroke, drawTextElement, hits, lassoSelects, lassoSelectsBox, moveBy,
  PAGE_COLORS, PAPER_TITLES, PAPERS, recognizeShape, textFont, transformPoint, transformRect, unionRect, widthScale, wrapText,
} from "./core/ink.js";
import { PdfDocument } from "./pdfwrite.js";

const COLORS = ["#1c1c1e", "#8e8e93", "#0a84ff", "#ff3b30", "#34c759", "#ff9500", "#af52de", "#ffd60a"];
const PEN_TOOLS = ["pen", "pencil", "fountain", "brush", "marker", "highlighter"];
const TOOL_INFO = {
  pen: { label: "Pen", key: "p", width: 2.5, color: "#1c1c1e", icon: "M4 20l4-1 10-10-3-3L5 16l-1 4zM14 5l3 3" },
  pencil: { label: "Pencil", key: "n", width: 2, color: "#1c1c1e", icon: "M4 20l2-5 9-9 3 3-9 9-5 2zM15 6l3 3M6 15l3 3" },
  fountain: { label: "Fountain pen", key: "f", width: 4, color: "#1c3d8f", icon: "M12 3l5 7-5 11-5-11 5-7zM12 10v4" },
  brush: { label: "Brush pen", key: "b", width: 8, color: "#1c1c1e", icon: "M15 4l5 5-8 8c-2 2-5 3-8 3 0-3 1-6 3-8l8-8zM12 7l5 5" },
  marker: { label: "Marker", key: "m", width: 7, color: "#0a84ff", icon: "M7 21h6M9 17h2l6-6-4-4-6 6v2l2 2zM13 7l4 4" },
  highlighter: { label: "Highlighter", key: "h", width: 22, color: "#ffd60a", icon: "M5 21h8M7 17l2 2 9-9-4-4-9 9 2 2zM14 6l4 4" },
  eraser: { label: "Eraser", key: "e", width: 10, color: "", icon: "M7 20h11M5 15l8-8 6 6-5 5H9l-4-4zM9 11l5 5" },
  lasso: { label: "Lasso", key: "l", width: 0, color: "", icon: "M12 4c5 0 8 2.5 8 5.5S16.5 15 12 15s-8-2.5-8-5.5S7 4 12 4zM6 13c-1 2 0 4 2 5l-1 3" },
  text: { label: "Text", key: "t", width: 20, color: "#1c1c1e", icon: "M5 5h14M12 5v14M9 19h6" },
};
const SHAPE_ICON = "M4 18L12 5l8 13H4z";
const PICTURE_ICON = "M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15 9.5a1.5 1.5 0 1 0 0-.01";
const HOLD_TO_SNAP_MS = 550;

function loadPrefs() {
  try { return JSON.parse(localStorage.getItem("trove.ink") ?? "{}"); } catch { return {}; }
}
function savePrefs(p) { try { localStorage.setItem("trove.ink", JSON.stringify(p)); } catch { /* private mode */ } }

const icon = (d) => {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "20");
  svg.setAttribute("height", "20");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", d);
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.8");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  svg.append(path);
  return svg;
};

// ---------- drawing a page (shared by the editor, the panel, thumbnails and PDF export) ----------

const bitmaps = new Map(); // attachment id → Promise<ImageBitmap>
function pictureBitmap(vault, image) {
  if (!bitmaps.has(image.id)) {
    bitmaps.set(image.id, vault.attachment(image.id).then((bytes) => createImageBitmap(new Blob([bytes], { type: image.mime })))
      .then((b) => { bitmaps.set(image.id, Object.assign(Promise.resolve(b), { ready: b })); return b; }));
  }
  return bitmaps.get(image.id);
}

/**
 * Pictures, then strokes, then text boxes on one page (`key`) of an item. `exclude` hides ids (a
 * selection being dragged, a text box being edited). `onLoaded` runs when a picture arrives.
 */
function drawSurface(ctx, vault, itemId, layer, key, { exclude = null, onLoaded = null } = {}) {
  const elements = vault.elements(itemId, layer, key).filter((e) => !exclude?.has(e.id));
  for (const e of elements) {
    if (e.type !== "image" || !e.image) continue;
    const ready = pictureBitmap(vault, e.image).ready;
    if (ready) ctx.drawImage(ready, e.x, e.y, e.w, e.h);
    else pictureBitmap(vault, e.image).then(() => onLoaded?.()).catch(() => {});
  }
  for (const s of vault.strokes(itemId, layer, key)) if (!exclude?.has(s.id)) drawStroke(ctx, s);
  for (const e of elements) if (e.type === "text") drawTextElement(ctx, e);
}

/** Everything drawn on a page, as a box in page points (for the endless canvas). */
function contentBounds(vault, itemId, layer, key) {
  let box = null;
  for (const s of vault.strokes(itemId, layer, key)) box = unionRect(box, bounds(s.points, s.width / 2));
  for (const e of vault.elements(itemId, layer, key)) box = unionRect(box, { x: e.x, y: e.y, w: e.w, h: e.h });
  return box;
}

/** A sketch's pages as the editor and previews see them: [{key, width, height, paper, color}]. */
export function sketchPages(item) {
  const [width, height] = item.pageSize;
  if (item.infinite) {
    // The endless canvas is page "0", with that page's paper and colour if it has its own.
    const zero = item.pageList.find((p) => p.id === "0");
    return [{ key: "0", width, height, paper: zero?.paper ?? item.paper, color: zero?.color ?? null, infinite: true }];
  }
  return item.pageList.map((p) => ({ key: p.id, width, height, paper: p.paper ?? item.paper, color: p.color }));
}

/** A text box's height as drawn: its wrapped lines. */
function textHeight(e) {
  const ctx = textHeight.ctx ??= document.createElement("canvas").getContext("2d");
  ctx.font = textFont(e.size);
  return Math.max(e.size * 1.25, wrapText(ctx, e.text || " ", e.w).length * e.size * 1.25);
}

// ---------- the editor ----------

/** What the lasso copied, for pasting into this or another drawing. */
let inkClipboard = null;
try { inkClipboard = JSON.parse(localStorage.getItem("trove.inkClipboard") ?? "null"); } catch { /* private mode */ }

/**
 * Opens the editor over the page.
 * - A sketch: `sketch: true`; its pages come from the item (page ids, paper, colour, endless).
 * - Ink on a file: `pages`: [{ width, height, background?(ctx, pxPerPoint) }] in page points.
 * - `changed()` runs after every edit (to sync); `onClose(edited)` when it closes.
 */
export function openInkEditor({ vault, itemId, layer = "", title = "Drawing", pages: filePages = null, sketch = false, startPage = 0,
  changed = () => {}, onClose = () => {} }) {
  const prefs = { tool: "pen", colors: {}, widths: {}, eraser: "stroke", highlighterOnly: false, shapes: false, panel: innerWidth > 900, ...loadPrefs() };
  let tool = TOOL_INFO[prefs.tool] ? prefs.tool : "pen";
  let zoom = 1;
  let penSeen = false;
  let edited = false;
  let current = null; // the stroke being drawn
  let erasing = null; // one eraser gesture
  let lasso = null; // the loop being drawn
  let selection = null; // {view, strokes: Set, elements: Set}
  let drag = null; // moving or resizing the selection
  let editing = null; // the text box being typed in
  let hover = null; // the eraser's circle under a mouse or pen
  const touches = new Map(); // finger pointers when they pan/pinch
  let pinch = null;
  let tap = null; // a two- or three-finger tap in progress
  const undo = [], redo = [];

  const colorOf = (t) => prefs.colors[t] ?? TOOL_INFO[t].color;
  const widthOf = (t) => prefs.widths[t] ?? TOOL_INFO[t].width;
  const item = () => vault.item(itemId);
  const pagesNow = () => (sketch ? sketchPages(item()) : filePages.map((p, i) => ({ ...p, key: i })));

  // ---------- toolbar ----------
  const toolButtons = Object.entries(TOOL_INFO).map(([id, info]) => h("button", {
    type: "button", class: `ink-tool tool-${id}`, title: `${info.label} (${info.key.toUpperCase()})`, "aria-label": info.label,
    onclick: () => setTool(id),
  }, icon(info.icon)));
  const shapeButton = h("button", { type: "button", class: "ink-tool", title: "Shapes: lines and shapes come out clean (S)", "aria-label": "Shapes",
    onclick: () => { prefs.shapes = !prefs.shapes; savePrefs(prefs); refreshToolbar(); } }, icon(SHAPE_ICON));
  const pictureInput = h("input", { type: "file", accept: "image/*", hidden: true });
  pictureInput.addEventListener("change", () => { const f = pictureInput.files?.[0]; pictureInput.value = ""; if (f) insertPicture(f); });
  const pictureButton = h("button", { type: "button", class: "ink-tool", title: "Insert a picture", "aria-label": "Picture", onclick: () => pictureInput.click() },
    icon(PICTURE_ICON));
  const swatches = COLORS.map((c) => h("button", { type: "button", class: "ink-swatch", title: c, "aria-label": `Colour ${c}`, style: `--swatch:${c}`, onclick: () => setColor(c) }));
  const custom = h("input", { type: "color", class: "ink-custom", "aria-label": "Any colour", title: "Any colour" });
  custom.addEventListener("input", () => setColor(custom.value));
  const size = h("input", { type: "range", min: "1", max: "60", step: "0.5", class: "ink-size", "aria-label": "Size" });
  const sizeDot = h("span", { class: "ink-size-dot", "aria-hidden": "true" });
  size.addEventListener("input", () => { prefs.widths[tool] = Number(size.value); savePrefs(prefs); refreshToolbar(); });
  const eraserMode = h("select", { class: "folder-select ink-eraser-mode", "aria-label": "Eraser mode" },
    h("option", { value: "stroke", text: "Whole strokes" }), h("option", { value: "partial", text: "Partial" }));
  eraserMode.addEventListener("change", () => { prefs.eraser = eraserMode.value; savePrefs(prefs); });
  const highlighterOnly = h("label", { class: "ink-check" }, h("input", { type: "checkbox" }), "Highlighter only");
  highlighterOnly.firstChild.addEventListener("change", (e) => { prefs.highlighterOnly = e.target.checked; savePrefs(prefs); });
  const undoButton = h("button", { type: "button", class: "secondary small", title: "Undo (⌘Z, or tap with two fingers)", onclick: doUndo }, "↶ Undo");
  const redoButton = h("button", { type: "button", class: "secondary small", title: "Redo (⇧⌘Z, or tap with three fingers)", onclick: doRedo }, "↷ Redo");
  const pasteButton = h("button", { type: "button", class: "secondary small", title: "Paste (⌘V)", onclick: () => paste() }, "Paste");
  const zoomLabel = h("span", { class: "saved ink-zoom" });
  const exportButton = h("button", { type: "button", class: "secondary small", onclick: () => exportPDF() }, "Export PDF");
  let paperSelect = null, layoutSelect = null, panelButton = null;
  if (sketch) {
    paperSelect = h("select", { class: "folder-select", "aria-label": "Paper", title: "Paper for every page" },
      PAPERS.map((p) => h("option", { value: p, text: PAPER_TITLES[p] })));
    paperSelect.addEventListener("change", () => {
      const it = item();
      vault.setSketch(itemId, { paper: paperSelect.value });
      // One paper for every page: drop the pages' own.
      for (const p of it.pageList) if (p.paper) vault.setPage(itemId, p.id, { paper: paperSelect.value });
      afterPagesChanged();
    });
    layoutSelect = h("select", { class: "folder-select", "aria-label": "Layout" },
      h("option", { value: "pages", text: "Pages" }), h("option", { value: "infinite", text: "Endless canvas" }));
    layoutSelect.addEventListener("change", () => { clearSelection(); vault.setSketchCanvas(itemId, layoutSelect.value === "infinite"); afterPagesChanged(); });
    panelButton = h("button", { type: "button", class: "secondary small", "aria-label": "Pages panel", onclick: () => { prefs.panel = !prefs.panel; savePrefs(prefs); refreshPanel(); } }, "▤ Pages");
  }
  const bar = h("div", { class: "ink-bar", role: "toolbar", "aria-label": "Drawing tools" },
    h("div", { class: "ink-group" }, toolButtons, shapeButton, pictureButton, pictureInput),
    h("div", { class: "ink-group ink-colors" }, swatches, custom),
    h("div", { class: "ink-group ink-size-group" }, sizeDot, size),
    h("div", { class: "ink-group ink-eraser-group" }, eraserMode, highlighterOnly),
    h("div", { class: "ink-group" }, undoButton, redoButton, pasteButton),
    h("div", { class: "ink-group" },
      h("button", { type: "button", class: "secondary small", "aria-label": "Zoom out", onclick: () => setZoom(zoom / 1.25) }, "−"), zoomLabel,
      h("button", { type: "button", class: "secondary small", "aria-label": "Zoom in", onclick: () => setZoom(zoom * 1.25) }, "+")),
    sketch ? h("div", { class: "ink-group" }, panelButton, paperSelect, layoutSelect,
      h("button", { type: "button", class: "secondary small ink-add-page", onclick: () => addPage(null) }, "+ Page")) : null,
    exportButton,
    h("span", { class: "spacer" }),
    h("strong", { class: "ink-title", text: title }),
    h("button", { type: "button", class: "primary", onclick: close }, "Done"));

  // The lasso's actions, along the bottom while something is selected.
  const selectionBar = h("div", { class: "ink-selbar", hidden: true, role: "toolbar", "aria-label": "Selection" },
    h("span", { class: "ink-selcount" }),
    h("div", { class: "ink-group" }, COLORS.map((c) => h("button", { type: "button", class: "ink-swatch", "aria-label": `Recolour ${c}`, style: `--swatch:${c}`,
      onclick: () => recolourSelection(c) }))),
    h("button", { type: "button", class: "secondary small", onclick: () => duplicateSelection() }, "Duplicate"),
    h("button", { type: "button", class: "secondary small", onclick: () => copySelection() }, "Copy"),
    h("button", { type: "button", class: "secondary small", onclick: () => { copySelection(); deleteSelection(); } }, "Cut"),
    h("button", { type: "button", class: "secondary small danger", onclick: () => deleteSelection() }, "Delete"),
    h("button", { type: "button", class: "secondary small", "aria-label": "Deselect", onclick: () => clearSelection() }, "✕"));

  // ---------- pages ----------
  const stack = h("div", { class: "ink-pages" });
  const scroller = h("div", { class: "ink-scroller" }, stack);
  const panel = h("aside", { class: "ink-panel", "aria-label": "Pages" });
  const body = h("div", { class: "ink-body" }, panel, scroller);
  const root = h("div", { class: "ink-editor", role: "dialog", "aria-label": `Drawing: ${title}` }, bar, body, selectionBar);
  document.body.append(root);
  document.body.classList.add("ink-open");

  let views = [];
  let infinite = null; // the endless view, when the sketch is one
  let shownSig = "";
  let currentKey = null; // the page most in view
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const v = views.find((x) => x.el === e.target);
      if (!v) continue;
      v.visible = e.isIntersecting;
      if (e.isIntersecting) renderView(v);
    }
  }, { root: scroller, rootMargin: "800px" });

  const pagesSig = () => (sketch ? JSON.stringify([item()?.pageList, item()?.paper, item()?.infinite]) : "file");

  /** (Re)builds the page views, keeping the page in view where it was. */
  function buildViews() {
    const keep = currentKey;
    for (const v of views) { io.unobserve(v.el); v.el.remove(); }
    views = [];
    infinite = null;
    const specs = pagesNow();
    shownSig = pagesSig();
    root.classList.toggle("endless", Boolean(specs[0]?.infinite));
    if (specs[0]?.infinite) {
      infinite = addView(specs[0], 0);
      const box = contentBounds(vault, itemId, layer, "0");
      infinite.scale = zoom;
      infinite.ox = box ? box.x - 40 : -40;
      infinite.oy = box ? box.y - 40 : -40;
    } else {
      specs.forEach((spec, i) => addView(spec, i));
    }
    if (selection && !views.includes(selection.view)) selection = null;
    currentKey = views.some((v) => v.key === keep) ? keep : views[0]?.key ?? null;
    refreshPanel();
  }

  function addView(spec, index) {
    const bg = h("canvas", { class: "ink-bg" }), inkCanvas = h("canvas", { class: "ink-ink" }), live = h("canvas", { class: "ink-live" });
    const el = h("div", { class: spec.infinite ? "ink-page ink-infinite" : "ink-page", "data-page": String(spec.key),
      style: spec.infinite ? "" : `aspect-ratio: ${spec.width} / ${spec.height}` }, bg, inkCanvas, live,
    spec.infinite ? null : h("span", { class: "ink-page-number", text: pagesNow().length > 1 ? `${index + 1}` : "" }));
    const view = { key: spec.key, index, spec, el, bg, ink: inkCanvas, live, bgWidth: 0, inkWidth: 0, visible: Boolean(spec.infinite), infinite: Boolean(spec.infinite),
      scale: 1, ox: 0, oy: 0 };
    views.push(view);
    stack.append(el);
    wirePointer(view);
    if (!spec.infinite) io.observe(el);
    return view;
  }

  function layout() {
    if (infinite) {
      infinite.scale = zoom;
      zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
      renderView(infinite, true);
      return;
    }
    const avail = Math.max(240, scroller.clientWidth - 32);
    for (const v of views) {
      const fit = Math.min(avail, Math.max(avail * 0.6, 900)) / v.spec.width;
      v.el.style.width = `${Math.round(v.spec.width * fit * zoom)}px`;
    }
    zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
    renderVisible();
  }

  /** CSS pixels per page point. */
  const cssScale = (v) => (v.infinite ? v.scale : v.el.clientWidth / v.spec.width);

  /** Sizes a canvas to its view and returns its context, transformed to page points. */
  function prepare(v, canvas) {
    const dpr = Math.min(devicePixelRatio || 1, 3);
    let w, hgt, k;
    if (v.infinite) {
      w = Math.round(v.el.clientWidth * dpr); hgt = Math.round(v.el.clientHeight * dpr);
      if (canvas.width !== w || canvas.height !== hgt) { canvas.width = w; canvas.height = hgt; }
      k = dpr * v.scale;
      const ctx = canvas.getContext("2d");
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, w, hgt);
      ctx.setTransform(k, 0, 0, k, -v.ox * k, -v.oy * k);
      return ctx;
    }
    const css = v.el.clientWidth;
    w = Math.round(css * dpr); hgt = Math.round(css * dpr * v.spec.height / v.spec.width);
    const cap = 16e6 / Math.max(1, w * hgt);
    if (cap < 1) { w = Math.floor(w * Math.sqrt(cap)); hgt = Math.floor(hgt * Math.sqrt(cap)); }
    if (canvas.width !== w || canvas.height !== hgt) { canvas.width = w; canvas.height = hgt; }
    k = w / v.spec.width;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, hgt);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    return ctx;
  }

  /** The part of an endless canvas on screen, in page points. */
  const area = (v) => ({ x: v.ox, y: v.oy, w: v.el.clientWidth / v.scale, h: v.el.clientHeight / v.scale });

  async function renderView(v, force = false) {
    if (!v.visible || !v.el.clientWidth) return;
    const css = v.el.clientWidth;
    if (v.infinite || v.bgWidth !== css || force) {
      v.bgWidth = css;
      const ctx = prepare(v, v.bg);
      if (sketch) drawPaper(ctx, v.spec.paper, v.spec.width, v.spec.height, v.spec.color, v.infinite ? area(v) : null);
      else { ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, v.spec.width, v.spec.height); }
      try { await v.spec.background?.(ctx, v.bg.width / v.spec.width); } catch { /* no background */ }
    }
    if (v.infinite || v.inkWidth !== css || v.dirty || force) { v.inkWidth = css; v.dirty = false; renderInk(v); }
    renderLive(v);
  }
  function renderVisible() { for (const v of views) if (v.visible) renderView(v); }

  /** Ids hidden from the ink layer: a selection being dragged (drawn live instead), a text box being typed in. */
  function hidden(v) {
    const out = new Set();
    if (drag && selection?.view === v) { for (const id of selection.strokes) out.add(id); for (const id of selection.elements) out.add(id); }
    if (editing?.view === v && editing.id) out.add(editing.id);
    return out;
  }

  function renderInk(v) {
    const ctx = prepare(v, v.ink);
    drawSurface(ctx, vault, itemId, layer, v.key, { exclude: hidden(v), onLoaded: () => { v.dirty = true; renderView(v); } });
  }

  function viewByKey(key) { return views.find((v) => v.key === key); }

  /** The current stroke, the lasso, the selection with its handles, the eraser. */
  function renderLive(v) {
    const ctx = prepare(v, v.live);
    const px = 1 / cssScale(v); // one CSS pixel in page points
    if (current?.view === v) drawStroke(ctx, current);
    if (lasso?.view === v && lasso.points.length > 1) {
      ctx.save();
      ctx.setLineDash([6 * px, 5 * px]);
      ctx.lineWidth = 1.5 * px;
      ctx.strokeStyle = "rgba(10, 132, 255, 0.95)";
      ctx.fillStyle = "rgba(10, 132, 255, 0.06)";
      ctx.beginPath();
      ctx.moveTo(lasso.points[0].x, lasso.points[0].y);
      for (const p of lasso.points.slice(1)) ctx.lineTo(p.x, p.y);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      ctx.restore();
    }
    if (selection?.view === v) {
      const t = drag?.t ?? null;
      if (t) {
        // The selection drawn where it's being moved to.
        const els = vault.elements(itemId, layer, v.key).filter((e) => selection.elements.has(e.id));
        for (const e of els) if (e.type === "image" && e.image) {
          const r = transformRect(t, e), b = pictureBitmap(vault, e.image).ready;
          if (b) ctx.drawImage(b, r.x, r.y, r.w, r.h);
        }
        for (const s of vault.strokes(itemId, layer, v.key)) if (selection.strokes.has(s.id)) {
          drawStroke(ctx, { ...s, width: s.width * widthScale(t), points: s.points.map((p) => transformPoint(t, p)) });
        }
        for (const e of els) if (e.type === "text") drawTextElement(ctx, { ...e, ...transformRect(t, e), size: e.size * widthScale(t) });
      }
      const box = selectionBox(t);
      if (box) {
        ctx.save();
        ctx.lineWidth = 1.5 * px;
        ctx.strokeStyle = "rgba(10, 132, 255, 0.95)";
        ctx.setLineDash([5 * px, 4 * px]);
        ctx.strokeRect(box.x, box.y, box.w, box.h);
        ctx.setLineDash([]);
        ctx.fillStyle = "#fff";
        for (const [hx, hy] of corners(box)) {
          ctx.beginPath();
          ctx.arc(hx, hy, 6 * px, 0, Math.PI * 2);
          ctx.fill();
          ctx.stroke();
        }
        ctx.restore();
      }
    }
    if (hover?.view === v && (tool === "eraser")) {
      ctx.beginPath();
      ctx.arc(hover.x, hover.y, eraserRadius(v), 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(120,120,128,0.9)";
      ctx.lineWidth = 1.5 * px;
      ctx.stroke();
    }
  }

  // ---------- input ----------
  function toPage(v, e) {
    const r = v.live.getBoundingClientRect();
    if (v.infinite) return { x: (e.clientX - r.left) / v.scale + v.ox, y: (e.clientY - r.top) / v.scale + v.oy };
    return { x: ((e.clientX - r.left) / r.width) * v.spec.width, y: ((e.clientY - r.top) / r.height) * v.spec.height };
  }

  function wirePointer(v) {
    const c = v.live;
    c.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "pen") { penSeen = true; root.classList.add("pen-seen"); }
      if (e.pointerType === "touch") noteTap(e, "down");
      if (e.pointerType === "touch" && (penSeen || touches.size > 0 || current?.pointerType === "touch" || lasso?.pointerType === "touch")) {
        // A finger with a pen around, or a second finger: scroll and pinch instead of drawing.
        if (current?.pointerType === "touch") { touches.set(current.pointerId, current.client); cancelStroke(); }
        if (lasso?.pointerType === "touch") { touches.set(lasso.pointerId, lasso.client); lasso = null; renderLive(v); }
        if (drag?.pointerType === "touch") { touches.set(drag.pointerId, drag.client); drag = null; renderView(v, true); }
        touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        capture(c, e);
        startPinch();
        e.preventDefault();
        return;
      }
      if (e.button === 1 || (e.button > 0 && e.pointerType === "mouse")) {
        if (e.button === 1) { touches.set(e.pointerId, { x: e.clientX, y: e.clientY }); capture(c, e); startPinch(); e.preventDefault(); }
        return;
      }
      if (current || erasing || lasso || drag) return;
      e.preventDefault();
      capture(c, e);
      const p = toPage(v, e);
      setCurrentPage(v.key);
      if (editing) { commitText(); if (tool === "text") return; }
      if (tool === "text") { startText(v, p); return; }
      if (selection && selection.view === v && tool === "lasso") {
        const handle = handleAt(v, p);
        const box = selectionBox();
        if (handle || (box && p.x >= box.x && p.x <= box.x + box.w && p.y >= box.y && p.y <= box.y + box.h)) {
          drag = { pointerId: e.pointerId, pointerType: e.pointerType, start: p, handle, box, t: null, client: { x: e.clientX, y: e.clientY } };
          return;
        }
        if (tool === "lasso") clearSelection();
      }
      if (tool === "lasso") { lasso = { view: v, pointerId: e.pointerId, pointerType: e.pointerType, points: [p], client: { x: e.clientX, y: e.clientY } }; return; }
      if (tool === "eraser") { startErase(v, e, p); return; }
      current = { view: v, pointerId: e.pointerId, pointerType: e.pointerType, start: e.timeStamp, points: [], tool, color: colorOf(tool), width: widthOf(tool),
        shape: null, anchor: { x: e.clientX, y: e.clientY }, client: { x: e.clientX, y: e.clientY } };
      addPoint(e);
      armSnap();
      renderLive(v);
    });
    c.addEventListener("pointermove", (e) => {
      if (e.pointerType === "touch") noteTap(e, "move");
      if (touches.has(e.pointerId)) { touches.set(e.pointerId, { x: e.clientX, y: e.clientY }); movePinch(); e.preventDefault(); return; }
      if (erasing?.pointerId === e.pointerId) { for (const ev of coalesced(e)) eraseTo(v, toPage(v, ev)); return; }
      if (lasso?.pointerId === e.pointerId) {
        for (const ev of coalesced(e)) lasso.points.push(toPage(v, ev));
        lasso.client = { x: e.clientX, y: e.clientY };
        renderLive(v);
        return;
      }
      if (drag?.pointerId === e.pointerId) { moveDrag(v, toPage(v, e)); drag.client = { x: e.clientX, y: e.clientY }; return; }
      if (current?.pointerId !== e.pointerId) {
        if (tool === "eraser" && e.pointerType !== "touch") { hover = { view: v, ...toPage(v, e) }; renderLive(v); }
        return;
      }
      if (current.shape) return; // snapped: lift to keep it
      for (const ev of coalesced(e)) addPoint(ev);
      if (Math.hypot(e.clientX - current.anchor.x, e.clientY - current.anchor.y) > 4) { current.anchor = { x: e.clientX, y: e.clientY }; armSnap(); }
      renderLive(v);
    });
    const end = (e) => {
      if (e.pointerType === "touch") noteTap(e, "up");
      if (touches.delete(e.pointerId)) { startPinch(); return; }
      if (erasing?.pointerId === e.pointerId) { finishErase(); return; }
      if (lasso?.pointerId === e.pointerId) { finishLasso(); return; }
      if (drag?.pointerId === e.pointerId) { finishDrag(e.type === "pointercancel"); return; }
      if (current?.pointerId === e.pointerId) { if (e.type === "pointercancel") cancelStroke(); else finishStroke(); }
    };
    c.addEventListener("pointerup", end);
    c.addEventListener("pointercancel", end);
    c.addEventListener("pointerleave", () => { if (hover?.view === v && !erasing) { hover = null; renderLive(v); } });
    c.addEventListener("dblclick", (e) => {
      // Double-click a text box (any tool) to type in it.
      const p = toPage(v, e);
      const box = textAt(v, p);
      if (box) { clearSelection(); startText(v, p, box); }
    });
  }

  /** The in-between positions the browser saw since the last event (smoother lines), or just this one. */
  function coalesced(e) { const list = e.getCoalescedEvents?.(); return list?.length ? list : [e]; }

  function capture(c, e) { try { c.setPointerCapture(e.pointerId); } catch { /* synthetic or already gone */ } }

  function addPoint(e) {
    const v = current.view;
    current.client = { x: e.clientX, y: e.clientY };
    const { x, y } = toPage(v, e);
    let p = e.pointerType === "mouse" ? 0.5 : e.pressure;
    if (e.pointerType === "touch" && (!p || p === 1)) p = 0.5; // most touch screens don't report force
    if (e.pointerType === "pen" && !p) p = 0.05;
    const last = current.points.at(-1);
    const minGap = 0.6 / cssScale(v); // ~0.6 screen pixels
    if (last && Math.hypot(last.x - x, last.y - y) < minGap) { last.p = Math.max(last.p, p); return; }
    current.points.push({ x, y, p: Math.max(0, Math.min(1, p)), t: Math.max(0, e.timeStamp - current.start) });
  }

  /** Holding the pen still at the end of a stroke turns it into a clean shape. */
  function armSnap() {
    clearTimeout(armSnap.timer);
    const s = current;
    armSnap.timer = setTimeout(() => {
      if (current !== s || !s || s.shape || s.points.length < 3) return;
      const shape = recognizeShape(s.points);
      if (!shape) return;
      s.points = shape.points;
      s.shape = shape.shape;
      renderLive(s.view);
    }, HOLD_TO_SNAP_MS);
  }

  function cancelStroke() {
    clearTimeout(armSnap.timer);
    if (!current) return;
    const v = current.view;
    current = null;
    renderLive(v);
  }

  function finishStroke() {
    clearTimeout(armSnap.timer);
    const s = current;
    current = null;
    if (!s.points.length) return;
    if (!s.shape && prefs.shapes) {
      const shape = recognizeShape(s.points);
      if (shape) { s.points = shape.points; s.shape = shape.shape; }
    }
    const id = vault.addStroke({ on: itemId, layer, page: s.view.key, tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape });
    record({ add: [[id, "stroke"]] }, [s.view]);
    s.view.dirty = true;
    renderView(s.view);
  }

  // ---------- eraser ----------
  const eraserRadius = (v) => (widthOf("eraser") / 2 + 4) / cssScale(v);

  function startErase(v, e, p) {
    erasing = { view: v, pointerId: e.pointerId, last: p, added: new Set(), removed: new Set(), before: new Set(vault.strokes(itemId, layer, v.key).map((s) => s.id)) };
    hover = { view: v, ...p };
    eraseTo(v, p);
  }

  function eraseTo(v, p) {
    const g = erasing;
    hover = { view: v, ...p };
    const only = prefs.highlighterOnly ? ["highlighter"] : null;
    const path = [g.last, p];
    g.last = p;
    if (prefs.eraser === "partial") {
      for (const id of vault.eraseStrokes({ on: itemId, layer, page: v.key, path, radius: eraserRadius(v), only })) g.added.add(id);
      // What disappeared: originals and pieces made earlier in this gesture.
      const alive = new Set(vault.strokes(itemId, layer, v.key).map((s) => s.id));
      for (const id of [...g.before, ...g.added]) if (!alive.has(id)) g.removed.add(id);
    } else {
      const gone = vault.strokes(itemId, layer, v.key).filter((s) => (!only || only.includes(s.tool)) && (hits(s, p.x, p.y, eraserRadius(v))
        || (path[0] && segmentHits(s, path[0], p, eraserRadius(v)))));
      if (gone.length) { vault.deleteStrokes(gone.map((s) => s.id)); for (const s of gone) g.removed.add(s.id); }
    }
    v.dirty = true;
    renderView(v);
  }
  /** A stroke eraser moving fast still catches what it passed over. */
  function segmentHits(s, a, b, r) {
    const n = Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / Math.max(r, 1));
    for (let i = 1; i < n; i++) if (hits(s, a.x + (b.x - a.x) * i / n, a.y + (b.y - a.y) * i / n, r)) return true;
    return false;
  }

  function finishErase() {
    const g = erasing;
    erasing = null;
    const alive = new Set(vault.strokes(itemId, layer, g.view.key).map((s) => s.id));
    const add = [...g.added].filter((id) => alive.has(id)).map((id) => [id, "stroke"]);
    const remove = [...g.removed].filter((id) => g.before.has(id)).map((id) => [id, "stroke"]);
    if (add.length || remove.length) record({ add, remove }, [g.view]);
    renderView(g.view);
  }

  // ---------- lasso ----------
  function finishLasso() {
    const l = lasso;
    lasso = null;
    const v = l.view;
    if (l.points.length < 3) { renderLive(v); return; }
    const strokes = vault.strokes(itemId, layer, v.key).filter((s) => lassoSelects(s.points, l.points)).map((s) => s.id);
    const elements = vault.elements(itemId, layer, v.key).filter((e) => lassoSelectsBox(boxOf(e), l.points)).map((e) => e.id);
    selection = strokes.length || elements.length ? { view: v, strokes: new Set(strokes), elements: new Set(elements) } : null;
    refreshSelection();
    renderLive(v);
  }

  const boxOf = (e) => ({ x: e.x, y: e.y, w: e.w, h: e.type === "text" ? textHeight(e) : e.h });

  /** The box around the selection (moved by `t` while dragging). */
  function selectionBox(t = null) {
    if (!selection) return null;
    const v = selection.view;
    let box = null;
    for (const s of vault.strokes(itemId, layer, v.key)) if (selection.strokes.has(s.id)) box = unionRect(box, bounds(s.points, s.width / 2));
    for (const e of vault.elements(itemId, layer, v.key)) if (selection.elements.has(e.id)) box = unionRect(box, boxOf(e));
    if (!box) return null;
    return t ? transformRect(t, box) : box;
  }

  const corners = (b) => [[b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]];

  /** The corner handle under a point: its index (0 top-left, clockwise). */
  function handleAt(v, p) {
    const box = selectionBox();
    if (!box) return null;
    const r = 14 / cssScale(v);
    const i = corners(box).findIndex(([x, y]) => Math.hypot(x - p.x, y - p.y) <= r);
    return i < 0 ? null : { index: i };
  }

  function moveDrag(v, p) {
    const d = drag;
    if (d.handle) {
      // Resize from the opposite corner, keeping the shape's proportions.
      const [ox, oy] = corners(d.box)[(d.handle.index + 2) % 4];
      const [cx, cy] = corners(d.box)[d.handle.index];
      const sx = (p.x - ox) / ((cx - ox) || 1), sy = (p.y - oy) / ((cy - oy) || 1);
      const s = Math.max(0.05, (sx + sy) / 2);
      d.t = { sx: s, sy: s, ox, oy, dx: 0, dy: 0 };
    } else {
      d.t = moveBy(p.x - d.start.x, p.y - d.start.y);
    }
    if (!d.hiding) { d.hiding = true; v.dirty = true; renderView(v); }
    renderLive(v);
  }

  function finishDrag(cancelled) {
    const d = drag;
    drag = null;
    const v = selection?.view;
    if (!v) return;
    if (!cancelled && d.t && (d.t.dx || d.t.dy || d.t.sx !== 1)) {
      const ids = [...selection.strokes], els = [...selection.elements];
      const before = snapshot(ids, els);
      vault.transformStrokes(ids, { t: d.t });
      vault.transformElements(els, d.t);
      record({ before, after: snapshot(ids, els) }, [v]);
    }
    v.dirty = true;
    renderView(v);
  }

  const STROKE_FIELDS = ["points", "width", "color"], ELEMENT_FIELDS = ["x", "y", "w", "h", "size", "color", "text"];
  /** The fields a lasso edit changes, so undo can put them back. */
  function snapshot(strokeIds, elementIds) {
    const pick = (id, kind, names) => {
      const f = vault.store.records.get(id)?.fields ?? {};
      return [id, kind, Object.fromEntries(names.filter((n) => n in f).map((n) => [n, f[n]]))];
    };
    return [...strokeIds.map((id) => pick(id, "stroke", STROKE_FIELDS)), ...elementIds.map((id) => pick(id, "element", ELEMENT_FIELDS))];
  }

  function recolourSelection(color) {
    if (!selection) return;
    const ids = [...selection.strokes], els = [...selection.elements].filter((id) => vault.element(id)?.type === "text");
    const before = snapshot(ids, els);
    vault.transformStrokes(ids, { color });
    for (const id of els) vault.updateElement(id, { color });
    record({ before, after: snapshot(ids, els) }, [selection.view]);
  }

  function duplicateSelection() {
    if (!selection) return;
    const v = selection.view;
    const ids = vault.duplicateInk({ strokes: [...selection.strokes], elements: [...selection.elements], on: itemId, layer, page: v.key });
    selectIds(v, ids);
    record({ add: ids.map((id) => [id, vault.element(id) ? "element" : "stroke"]) }, [v]);
  }

  function selectAll() {
    setTool("lasso");
    const v = viewByKey(currentKey) ?? views[0];
    if (!v) return;
    selectIds(v, [...vault.strokes(itemId, layer, v.key).map((s) => s.id), ...vault.elements(itemId, layer, v.key).map((x) => x.id)]);
    renderLive(v);
  }

  function selectIds(v, ids) {
    if (tool !== "lasso") setTool("lasso");
    selection = { view: v, strokes: new Set(ids.filter((id) => !vault.element(id))), elements: new Set(ids.filter((id) => vault.element(id))) };
    refreshSelection();
  }

  function deleteSelection() {
    if (!selection) return;
    const v = selection.view;
    const strokes = [...selection.strokes], els = [...selection.elements];
    vault.deleteStrokes(strokes);
    vault.deleteElements(els);
    clearSelection();
    record({ remove: [...strokes.map((id) => [id, "stroke"]), ...els.map((id) => [id, "element"])] }, [v]);
  }

  function copySelection() {
    if (!selection) return;
    const v = selection.view;
    inkClipboard = {
      strokes: vault.strokes(itemId, layer, v.key).filter((s) => selection.strokes.has(s.id))
        .map((s) => ({ tool: s.tool, color: s.color, width: s.width, shape: s.shape, points: s.points })),
      elements: vault.elements(itemId, layer, v.key).filter((e) => selection.elements.has(e.id))
        .map((e) => ({ type: e.type, x: e.x, y: e.y, w: e.w, h: e.h, text: e.text, size: e.size, color: e.color, image: e.image })),
    };
    try { localStorage.setItem("trove.inkClipboard", JSON.stringify(inkClipboard)); } catch { /* too big or private mode */ }
    refreshToolbar();
  }

  /** Pastes what the lasso copied onto the page in view, a little down and right. */
  function paste() {
    if (!inkClipboard) return;
    const v = viewByKey(currentKey) ?? views[0];
    if (!v) return;
    const t = moveBy(20, 20);
    const ids = [
      ...inkClipboard.strokes.map((s) => vault.addStroke({ on: itemId, layer, page: v.key, tool: s.tool, color: s.color, width: s.width, shape: s.shape,
        points: s.points.map((p) => transformPoint(t, p)) })),
      ...inkClipboard.elements.map((e) => vault.addElement({ on: itemId, layer, page: v.key, type: e.type, frame: transformRect(t, e), text: e.text, size: e.size,
        color: e.color, image: e.image })),
    ];
    selectIds(v, ids);
    record({ add: ids.map((id) => [id, vault.element(id) ? "element" : "stroke"]) }, [v]);
  }

  function clearSelection() {
    if (!selection) return;
    const v = selection.view;
    selection = null;
    drag = null;
    refreshSelection();
    renderView(v);
  }

  function refreshSelection() {
    selectionBar.hidden = !selection;
    if (selection) {
      const n = selection.strokes.size + selection.elements.size;
      selectionBar.querySelector(".ink-selcount").textContent = `${n} selected`;
    }
  }

  // ---------- text boxes ----------
  function textAt(v, p) {
    return vault.elements(itemId, layer, v.key).reverse().find((e) => e.type === "text" && p.x >= e.x && p.x <= e.x + e.w && p.y >= e.y && p.y <= e.y + textHeight(e)) ?? null;
  }

  /** Types in a text box: the one under the point, or a new one there. */
  function startText(v, p, existing = textAt(v, p)) {
    const k = cssScale(v);
    const width = existing ? existing.w : v.infinite ? 320 : Math.max(120, Math.min(360, v.spec.width - p.x - 16));
    const e = existing ?? { x: p.x, y: p.y - widthOf("text") * 0.6, w: width, size: widthOf("text"), color: colorOf("text"), text: "" };
    const area = h("textarea", { class: "ink-textbox", "aria-label": "Text box", spellcheck: "true" });
    area.value = e.text;
    const place = () => {
      const left = v.infinite ? (e.x - v.ox) * k : e.x * k, top = v.infinite ? (e.y - v.oy) * k : e.y * k;
      area.style.cssText = `left:${left}px;top:${top}px;width:${e.w * k}px;font:${textFont(e.size * k)};line-height:1.25;color:${e.color}`;
      area.style.height = "auto";
      area.style.height = `${Math.max(e.size * 1.25 * k, area.scrollHeight)}px`;
    };
    area.addEventListener("input", place);
    area.addEventListener("keydown", (ev) => {
      if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); commitText(); }
      ev.stopPropagation();
    });
    area.addEventListener("blur", () => setTimeout(() => { if (editing?.area === area) commitText(); }, 0));
    v.el.append(area);
    editing = { view: v, id: existing?.id ?? null, frame: e, area };
    place();
    v.dirty = true;
    renderView(v);
    area.focus();
  }

  function commitText() {
    const ed = editing;
    if (!ed) return;
    editing = null;
    const text = ed.area.value.replace(/\s+$/, "");
    ed.area.remove();
    const v = ed.view;
    if (ed.id) {
      const before = snapshot([], [ed.id]);
      if (!text) {
        vault.deleteElements([ed.id]);
        record({ remove: [[ed.id, "element"]] }, [v]);
      } else if (text !== vault.element(ed.id)?.text) {
        vault.updateElement(ed.id, { text, frame: { ...ed.frame, h: textHeight({ ...ed.frame, text }) } });
        record({ before, after: snapshot([], [ed.id]) }, [v]);
      }
    } else if (text) {
      const frame = { x: ed.frame.x, y: ed.frame.y, w: ed.frame.w, h: textHeight({ ...ed.frame, text }) };
      const id = vault.addElement({ on: itemId, layer, page: v.key, type: "text", frame, text, size: ed.frame.size, color: ed.frame.color });
      record({ add: [[id, "element"]] }, [v]);
    }
    v.dirty = true;
    renderView(v);
  }

  // ---------- pictures ----------
  async function insertPicture(file) {
    const v = viewByKey(currentKey) ?? views[0];
    if (!v || !file.type.startsWith("image/")) return;
    let bitmap;
    try { bitmap = await createImageBitmap(file); } catch { return; }
    const a = v.infinite ? area(v) : { x: 0, y: 0, w: v.spec.width, h: v.spec.height };
    const w = Math.min(bitmap.width, a.w * 0.6), hgt = w * bitmap.height / bitmap.width;
    const frame = { x: a.x + (a.w - w) / 2, y: a.y + Math.max(16, (a.h - hgt) / 3), w, h: hgt };
    const id = await vault.addPicture(new Uint8Array(await file.arrayBuffer()), file.type, { on: itemId, layer, page: v.key, frame });
    record({ add: [[id, "element"]] }, [v]);
    setTool("lasso");
    selectIds(v, [id]);
    v.dirty = true;
    renderView(v);
  }

  // ---------- fingers: scroll, pinch, and taps to undo ----------
  function noteTap(e, phase) {
    if (phase === "down") {
      if (!tap || tap.done) tap = { start: e.timeStamp, ids: new Set(), max: 0, moved: false, from: new Map(), done: false };
      tap.ids.add(e.pointerId);
      tap.from.set(e.pointerId, { x: e.clientX, y: e.clientY });
      tap.max = Math.max(tap.max, tap.ids.size);
    } else if (phase === "move" && tap?.from.has(e.pointerId)) {
      const f = tap.from.get(e.pointerId);
      if (Math.hypot(e.clientX - f.x, e.clientY - f.y) > 12) tap.moved = true;
    } else if (phase === "up" && tap) {
      tap.ids.delete(e.pointerId);
      if (tap.ids.size === 0) {
        tap.done = true;
        if (!tap.moved && e.timeStamp - tap.start < 400) {
          if (tap.max === 2) doUndo();
          else if (tap.max === 3) doRedo();
        }
      }
    }
  }

  function startPinch() {
    const pts = [...touches.values()];
    pinch = pts.length >= 2
      ? { dist: Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y), zoom, cx: (pts[0].x + pts[1].x) / 2, cy: (pts[0].y + pts[1].y) / 2 }
      : pts.length === 1 ? { x: pts[0].x, y: pts[0].y } : null;
  }

  function movePinch() {
    const pts = [...touches.values()];
    if (!pinch) return;
    if (pts.length >= 2 && pinch.dist) {
      const cx = (pts[0].x + pts[1].x) / 2, cy = (pts[0].y + pts[1].y) / 2;
      panBy(pinch.cx - cx, pinch.cy - cy);
      pinch.cx = cx; pinch.cy = cy;
      const dist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      setZoom(pinch.zoom * dist / pinch.dist, { x: cx, y: cy });
    } else if (pts.length === 1 && pinch.x !== undefined) {
      panBy(pinch.x - pts[0].x, pinch.y - pts[0].y);
      pinch.x = pts[0].x; pinch.y = pts[0].y;
    }
  }

  /** Scrolls the pages, or moves around the endless canvas, by CSS pixels. */
  function panBy(dx, dy) {
    if (infinite) {
      infinite.ox += dx / infinite.scale;
      infinite.oy += dy / infinite.scale;
      if (editing) commitText();
      renderView(infinite, true);
    } else scroller.scrollBy(dx, dy);
  }

  function setZoom(z, anchor = null) {
    const next = Math.min(4, Math.max(infinite ? 0.1 : 0.5, z));
    if (Math.abs(next - zoom) < 0.001) return;
    if (infinite) {
      const r = infinite.el.getBoundingClientRect();
      const ax = anchor ? anchor.x - r.left : r.width / 2, ay = anchor ? anchor.y - r.top : r.height / 2;
      const px = ax / infinite.scale + infinite.ox, py = ay / infinite.scale + infinite.oy;
      zoom = next;
      infinite.scale = zoom;
      infinite.ox = px - ax / zoom;
      infinite.oy = py - ay / zoom;
      layout();
      return;
    }
    const r = scroller.getBoundingClientRect();
    const ax = anchor ? anchor.x - r.left : r.width / 2, ay = anchor ? anchor.y - r.top : r.height / 2;
    const fx = (scroller.scrollLeft + ax) / Math.max(1, scroller.scrollWidth), fy = (scroller.scrollTop + ay) / Math.max(1, scroller.scrollHeight);
    zoom = next;
    layout();
    scroller.scrollLeft = fx * scroller.scrollWidth - ax;
    scroller.scrollTop = fy * scroller.scrollHeight - ay;
  }

  scroller.addEventListener("wheel", (e) => {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      setZoom(zoom * Math.exp(-e.deltaY / 300), { x: e.clientX, y: e.clientY });
    } else if (infinite) {
      e.preventDefault();
      panBy(e.deltaX, e.deltaY);
    }
  }, { passive: false });

  scroller.addEventListener("scroll", () => {
    if (infinite) return;
    // The page most in view is the one new pages, pastes and pictures go on.
    const top = scroller.getBoundingClientRect().top + scroller.clientHeight / 3;
    const v = views.find((x) => { const r = x.el.getBoundingClientRect(); return r.top <= top && r.bottom >= top; });
    if (v && v.key !== currentKey) setCurrentPage(v.key);
  }, { passive: true });

  // ---------- undo ----------
  /**
   * An edit for undo: ids that came to life (`add`), ids deleted (`remove`) and fields changed
   * (`before`/`after`), each [id, kind(, fields)]. Undo puts back exactly the same records.
   */
  function record(action, touched) {
    undo.push({ add: [], remove: [], before: [], after: [], ...action, keys: touched.map((v) => v.key) });
    redo.length = 0;
    edited = true;
    refreshToolbar();
    changed();
  }

  function apply(action, forward) {
    for (const [id, kind] of forward ? action.remove : action.add) vault.set({ _deleted: true }, id, kind);
    for (const [id, kind] of forward ? action.add : action.remove) vault.set({ _deleted: false }, id, kind);
    for (const [id, kind, fields] of forward ? action.after : action.before) vault.set(fields, id, kind);
    if ([...action.add, ...action.remove, ...action.before].some(([, kind]) => kind === "element")) vault.refreshSketchText(itemId);
    clearSelection();
    edited = true;
    for (const key of action.keys) { const v = viewByKey(key); if (v) { v.dirty = true; renderView(v); } }
    refreshToolbar();
    changed();
  }

  function doUndo() {
    if (editing) commitText();
    const action = undo.pop();
    if (!action) return;
    apply(action, false);
    redo.push(action);
    refreshToolbar();
  }

  function doRedo() {
    const action = redo.pop();
    if (!action) return;
    apply(action, true);
    undo.push(action);
    refreshToolbar();
  }

  // ---------- tools ----------
  function setTool(id) {
    if (editing) commitText();
    tool = id;
    prefs.tool = id;
    savePrefs(prefs);
    hover = null;
    if (id !== "lasso") clearSelection();
    for (const v of views) renderLive(v);
    refreshToolbar();
  }

  function setColor(c) {
    if (tool === "eraser" || tool === "lasso") {
      if (selection) { recolourSelection(c); return; }
      setTool("pen");
    }
    prefs.colors[tool] = c;
    savePrefs(prefs);
    if (editing) { editing.frame.color = c; editing.area.style.color = c; }
    refreshToolbar();
  }

  function refreshToolbar() {
    toolButtons.forEach((b, i) => b.setAttribute("aria-pressed", String(Object.keys(TOOL_INFO)[i] === tool)));
    shapeButton.setAttribute("aria-pressed", String(prefs.shapes));
    const hasColor = PEN_TOOLS.includes(tool) || tool === "text";
    const c = hasColor ? colorOf(tool) : null;
    swatches.forEach((s, i) => s.setAttribute("aria-pressed", String(COLORS[i] === c)));
    if (c) custom.value = c;
    const sized = hasColor || tool === "eraser";
    size.disabled = !sized;
    size.value = String(sized ? widthOf(tool) : 10);
    const d = Math.max(3, Math.min(22, sized ? widthOf(tool) : 10));
    sizeDot.style.cssText = `width:${d}px;height:${d}px;background:${c ?? "transparent"};opacity:${tool === "highlighter" ? 0.5 : 1}`;
    eraserMode.value = prefs.eraser;
    highlighterOnly.firstChild.checked = prefs.highlighterOnly;
    root.querySelector(".ink-eraser-group").hidden = tool !== "eraser";
    undoButton.disabled = !undo.length;
    redoButton.disabled = !redo.length;
    pasteButton.hidden = !inkClipboard;
    root.dataset.tool = tool;
    if (sketch) {
      const it = item();
      paperSelect.value = it.paper;
      layoutSelect.value = it.infinite ? "infinite" : "pages";
      root.querySelector(".ink-add-page").hidden = it.infinite;
      panelButton.hidden = it.infinite;
    }
  }

  // ---------- the page panel ----------
  function setCurrentPage(key) {
    if (currentKey === key) return;
    currentKey = key;
    for (const b of panel.querySelectorAll(".ink-thumb")) b.setAttribute("aria-current", String(b.dataset.key === String(key)));
    refreshPageTools();
  }

  function refreshPanel() {
    const show = sketch && prefs.panel && !infinite;
    panel.hidden = !show;
    panelButton?.setAttribute("aria-pressed", String(Boolean(prefs.panel)));
    if (!show) return;
    const specs = pagesNow();
    const list = h("div", { class: "ink-thumbs" }, specs.map((spec, i) => {
      const canvas = h("canvas", { class: "ink-thumb-canvas" });
      const button = h("button", { type: "button", class: "ink-thumb", "data-key": spec.key, "aria-current": String(spec.key === currentKey),
        "aria-label": `Page ${i + 1}`, draggable: "true",
        onclick: () => { setCurrentPage(spec.key); viewByKey(spec.key)?.el.scrollIntoView({ behavior: "smooth", block: "start" }); } },
      canvas, h("span", { text: String(i + 1) }));
      button.addEventListener("dragstart", (e) => { e.dataTransfer.setData("text/x-trove-page", String(spec.key)); });
      button.addEventListener("dragover", (e) => { if (e.dataTransfer.types.includes("text/x-trove-page")) e.preventDefault(); });
      button.addEventListener("drop", (e) => {
        const key = e.dataTransfer.getData("text/x-trove-page");
        if (!key || key === spec.key) return;
        e.preventDefault();
        vault.movePage(itemId, key, i);
        afterPagesChanged(key);
      });
      requestAnimationFrame(() => drawThumb(canvas, spec));
      return button;
    }));
    panel.replaceChildren(list, h("div", { class: "ink-page-tools" }));
    refreshPageTools();
  }

  function drawThumb(canvas, spec) {
    const w = 96;
    canvas.width = Math.round(w * (devicePixelRatio || 1));
    canvas.height = Math.round(canvas.width * spec.height / spec.width);
    const ctx = canvas.getContext("2d");
    const s = canvas.width / spec.width;
    ctx.setTransform(s, 0, 0, s, 0, 0);
    drawPaper(ctx, spec.paper, spec.width, spec.height, spec.color);
    drawSurface(ctx, vault, itemId, layer, spec.key, { onLoaded: () => drawThumb(canvas, spec) });
  }

  function refreshPageTools() {
    const tools = panel.querySelector(".ink-page-tools");
    if (!tools) return;
    const specs = pagesNow();
    const i = specs.findIndex((s) => s.key === currentKey);
    const spec = specs[i];
    if (!spec) { tools.replaceChildren(); return; }
    const page = item().pageList.find((p) => p.id === spec.key);
    const paper = h("select", { class: "folder-select", "aria-label": "This page's paper" }, PAPERS.map((p) => h("option", { value: p, text: PAPER_TITLES[p] })));
    paper.value = spec.paper;
    paper.addEventListener("change", () => { vault.setPage(itemId, spec.key, { paper: paper.value }); afterPagesChanged(); });
    tools.replaceChildren(
      h("strong", { text: `Page ${i + 1} of ${specs.length}` }),
      h("div", { class: "ink-page-actions" },
        h("button", { type: "button", class: "secondary small", onclick: () => addPage(spec.key) }, "Add page after"),
        h("button", { type: "button", class: "secondary small", onclick: () => { const id = vault.duplicatePage(itemId, spec.key); afterPagesChanged(id); } }, "Duplicate page"),
        h("button", { type: "button", class: "secondary small", disabled: i === 0, "aria-label": "Move page up", onclick: () => { vault.movePage(itemId, spec.key, i - 1); afterPagesChanged(spec.key); } }, "↑"),
        h("button", { type: "button", class: "secondary small", disabled: i === specs.length - 1, "aria-label": "Move page down",
          onclick: () => { vault.movePage(itemId, spec.key, i + 1); afterPagesChanged(spec.key); } }, "↓"),
        h("button", { type: "button", class: "secondary small danger", disabled: specs.length < 2, onclick: () => {
          if (!confirm(`Delete page ${i + 1} and everything on it?`)) return;
          vault.deletePage(itemId, spec.key);
          undo.length = 0; redo.length = 0;
          afterPagesChanged();
        } }, "Delete page")),
      h("label", { class: "ink-page-field" }, h("span", { class: "hint", text: "Paper" }), paper),
      h("div", { class: "ink-page-colors", role: "group", "aria-label": "Page colour" }, PAGE_COLORS.map((c) => {
        const b = h("button", { type: "button", class: "ink-swatch page-swatch", "aria-label": `Page colour ${c}`, style: `--swatch:${c}`,
          "aria-pressed": String((page?.color ?? "#ffffff") === c), onclick: () => { vault.setPage(itemId, spec.key, { color: c === "#ffffff" ? "" : c }); afterPagesChanged(); } });
        return b;
      })));
  }

  function addPage(after) {
    const id = vault.addPage(itemId, after ?? (sketch ? item().pageList.at(-1).id : null));
    afterPagesChanged(id);
  }

  /** Pages changed here: rebuild, show `focusKey`, and sync. */
  function afterPagesChanged(focusKey = null) {
    edited = true;
    clearSelection();
    if (focusKey) currentKey = focusKey;
    buildViews();
    refreshToolbar();
    requestAnimationFrame(() => {
      layout();
      if (focusKey) viewByKey(focusKey)?.el.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    changed();
  }

  // ---------- export ----------
  async function exportPDF() {
    if (editing) commitText();
    exportButton.disabled = true;
    exportButton.textContent = "Exporting…";
    try {
      const doc = new PdfDocument();
      for (const spec of pagesNow()) {
        let box = { x: 0, y: 0, w: spec.width, h: spec.height };
        if (spec.infinite) {
          const content = contentBounds(vault, itemId, layer, spec.key);
          box = content ? { x: content.x - 36, y: content.y - 36, w: content.w + 72, h: content.h + 72 } : { x: 0, y: 0, w: spec.width, h: spec.height };
        }
        const ctx = doc.page(box.w, box.h);
        if (spec.infinite) ctx.ops.push(`1 0 0 1 ${-box.x} ${-box.y} cm`);
        if (sketch) drawPaper(ctx, spec.paper, spec.width, spec.height, spec.color, spec.infinite ? box : null);
        else if (spec.background) {
          // The file under the ink, as a picture at twice its size.
          const k = Math.min(2, 4000 / Math.max(spec.width, spec.height));
          const canvas = h("canvas", { width: Math.round(spec.width * k), height: Math.round(spec.height * k) });
          const c2 = canvas.getContext("2d");
          c2.fillStyle = "#fff";
          c2.fillRect(0, 0, canvas.width, canvas.height);
          c2.setTransform(k, 0, 0, k, 0, 0);
          await spec.background(c2, k);
          ctx.drawJpeg(await jpegOf(canvas), canvas.width, canvas.height, 0, 0, spec.width, spec.height);
        }
        for (const e of vault.elements(itemId, layer, spec.key)) {
          if (e.type !== "image" || !e.image) continue;
          const bitmap = await pictureBitmap(vault, e.image).catch(() => null);
          if (!bitmap) continue;
          const canvas = h("canvas", { width: bitmap.width, height: bitmap.height });
          const c2 = canvas.getContext("2d");
          c2.fillStyle = "#fff";
          c2.fillRect(0, 0, canvas.width, canvas.height);
          c2.drawImage(bitmap, 0, 0);
          ctx.drawJpeg(await jpegOf(canvas), canvas.width, canvas.height, e.x, e.y, e.w, e.h);
        }
        for (const s of vault.strokes(itemId, layer, spec.key)) drawStroke(ctx, s);
        for (const e of vault.elements(itemId, layer, spec.key)) if (e.type === "text") drawTextElement(ctx, e);
      }
      const bytes = doc.bytes();
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }));
      const a = h("a", { href: url, download: `${(title || "Drawing").replace(/[\\/:*?"<>|]+/g, " ").trim() || "Drawing"}.pdf` });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      root.dataset.exported = String(bytes.length);
    } finally {
      exportButton.disabled = false;
      exportButton.textContent = "Export PDF";
    }
  }

  async function jpegOf(canvas) {
    const blob = await new Promise((done) => canvas.toBlob(done, "image/jpeg", 0.9));
    return new Uint8Array(await blob.arrayBuffer());
  }

  // ---------- keys, sync, closing ----------
  // Strokes and pages from other devices show up as they sync.
  let pendingRemote = false;
  const unsubscribe = vault.onChange(() => {
    if (pendingRemote) return;
    pendingRemote = true;
    requestAnimationFrame(() => {
      pendingRemote = false;
      if (current || erasing || drag || lasso) return;
      if (sketch && !item()) { close(); return; }
      if (pagesSig() !== shownSig) { buildViews(); layout(); refreshToolbar(); return; }
      for (const v of views) { v.dirty = true; if (v.visible) renderView(v); }
      if (selection) {
        // Drop selected things another device deleted.
        for (const id of selection.strokes) if (!vault.store.records.get(id) || vault.store.records.get(id).fields._deleted) selection.strokes.delete(id);
        for (const id of selection.elements) if (!vault.element(id)) selection.elements.delete(id);
        if (!selection.strokes.size && !selection.elements.size) clearSelection(); else refreshSelection();
      }
    });
  });

  const onKey = (e) => {
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement?.tagName ?? "") && document.activeElement.type !== "range" && document.activeElement.type !== "color"
      && document.activeElement.type !== "checkbox") return;
    const mod = e.metaKey || e.ctrlKey;
    const k = e.key.toLowerCase();
    let handled = true;
    if (mod && k === "z") e.shiftKey ? doRedo() : doUndo();
    else if (mod && k === "y") doRedo();
    else if (mod && k === "c" && selection) copySelection();
    else if (mod && k === "x" && selection) { copySelection(); deleteSelection(); }
    else if (mod && k === "d" && selection) duplicateSelection();
    else if (mod && k === "v" && inkClipboard) paste();
    else if (mod && k === "a") selectAll();
    else if ((e.key === "Delete" || e.key === "Backspace") && selection) deleteSelection();
    else if (e.key === "Escape") { if (selection) clearSelection(); else close(); }
    else if (!mod && !e.altKey) {
      const id = Object.keys(TOOL_INFO).find((t) => TOOL_INFO[t].key === k);
      if (id) setTool(id);
      else if (k === "s") { prefs.shapes = !prefs.shapes; savePrefs(prefs); refreshToolbar(); }
      else if (e.key === "+" || e.key === "=") setZoom(zoom * 1.25);
      else if (e.key === "-") setZoom(zoom / 1.25);
      else handled = false;
    } else handled = false;
    if (handled) { e.preventDefault(); e.stopImmediatePropagation(); }
  };
  document.addEventListener("keydown", onKey, true);
  // A picture pasted from the system clipboard goes on the page in view.
  const onPaste = (e) => {
    if (editing) return;
    const file = [...(e.clipboardData?.files ?? [])].find((f) => f.type.startsWith("image/"));
    if (file) { e.preventDefault(); e.stopImmediatePropagation(); insertPicture(file); }
  };
  document.addEventListener("paste", onPaste, true);
  const onResize = () => layout();
  addEventListener("resize", onResize);

  function close() {
    if (editing) commitText();
    if (current) finishStroke();
    if (erasing) finishErase();
    io.disconnect();
    unsubscribe();
    document.removeEventListener("keydown", onKey, true);
    document.removeEventListener("paste", onPaste, true);
    removeEventListener("resize", onResize);
    root.remove();
    document.body.classList.remove("ink-open");
    onClose(edited);
  }

  buildViews();
  const start = pagesNow()[Math.min(startPage, pagesNow().length - 1)];
  if (start) currentKey = start.key;
  refreshToolbar();
  refreshPanel();
  requestAnimationFrame(() => {
    layout();
    if (!infinite) viewByKey(currentKey)?.el.scrollIntoView({ block: "start" });
  });
  return { close };
}

// ---------- previews ----------

/** A small JPEG of a sketch's first page (or all of an endless one), for its card. */
export async function sketchThumbnail(vault, item, maxWidth = 480) {
  const spec = sketchPages(item)[0];
  let box = { x: 0, y: 0, w: spec.width, h: spec.height };
  if (spec.infinite) {
    const content = contentBounds(vault, item.id, "", "0");
    if (content) { const pad = 24; box = { x: content.x - pad, y: content.y - pad, w: Math.max(200, content.w + 2 * pad), h: Math.max(150, content.h + 2 * pad) }; }
  }
  // Pictures first, so the thumbnail has them.
  await Promise.all(vault.elements(item.id, "", spec.key).filter((e) => e.image).map((e) => pictureBitmap(vault, e.image).catch(() => null)));
  const k = maxWidth / box.w;
  const canvas = h("canvas", { width: Math.round(box.w * k), height: Math.round(Math.min(box.h, box.w * 1.5) * k) });
  const ctx = canvas.getContext("2d");
  ctx.setTransform(k, 0, 0, k, -box.x * k, -box.y * k);
  drawPaper(ctx, spec.paper, spec.width, spec.height, spec.color, spec.infinite ? box : null);
  drawSurface(ctx, vault, item.id, "", spec.key);
  const blob = await new Promise((done) => canvas.toBlob(done, "image/jpeg", 0.82));
  return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
}

/** Draws one sketch page (`spec` from `sketchPages`) into a canvas sized to `cssWidth`. */
export function renderSketchPage(canvas, vault, item, spec, cssWidth) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  let box = { x: 0, y: 0, w: spec.width, h: spec.height };
  if (spec.infinite) {
    const content = contentBounds(vault, item.id, "", spec.key);
    if (content) box = { x: content.x - 24, y: content.y - 24, w: Math.max(300, content.w + 48), h: Math.max(200, content.h + 48) };
  }
  canvas.width = Math.round(cssWidth * dpr);
  canvas.height = Math.round(cssWidth * dpr * box.h / box.w);
  const k = canvas.width / box.w;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(k, 0, 0, k, -box.x * k, -box.y * k);
  drawPaper(ctx, spec.paper, spec.width, spec.height, spec.color, spec.infinite ? box : null);
  drawSurface(ctx, vault, item.id, "", spec.key, { onLoaded: () => renderSketchPage(canvas, vault, item, spec, cssWidth) });
}
