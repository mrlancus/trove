// The drawing editor: sketches and ink on PDFs and images (PROTOCOL.md §10, core/ink.js).
// - Pens (pen, ballpoint, pencil, fountain pen, brush, marker, highlighter), an eraser (whole strokes or
//   partial, optionally highlighter only), the lasso (move, resize, turn, flip, front/back, group,
//   straighten, recolour, duplicate, copy, copy as image, save as element, delete; picks
//   everything, ink, text or pictures), shapes (a shape mode, holding the pen still at the end of a
//   line snaps it, and the shape tool's picker with handles and connectors), the ruler and
//   protractor, text boxes (font, bold, italic, bullets), pictures and the elements library.
// - Sketches have a page panel (add, duplicate, reorder, delete, paper and colour per page) or one
//   endless canvas. Export to PDF.
// - Apple Pencil (or any pen) draws and fingers scroll and pinch; without a pen, one finger draws
//   and two scroll and pinch. Two-finger tap undoes, three-finger tap redoes. A mouse or trackpad
//   draws, the wheel scrolls, ⌘/Ctrl + wheel zooms.
import { h } from "./dom.js";
import { icon as lineIcon } from "./icons.js";
import {
  bounds, CLOSED_SHAPES, drawPaper, drawStroke, drawTapeElement, drawTextElement, hits, InkGrid, lassoSelects, lassoSelectsBox, MAX_FAVOURITES, MAX_PALETTE, moveBy,
  PAGE_COLOR_TITLES, PAGE_COLORS, PAGE_SIZES, PAPER_GROUPS, PAPER_TITLES, pageSizeName, PenFilter, pressureAfter, recognizeShape, scribbleTargets, strokeBounds,
  strokeStyle, TAPE_COLORS, tapeBox, textFont, transformPoint, transformRect, unionRect, widthScale, wrapText, withElementTransform, TEXT_FONTS,
} from "./core/ink.js";
import {
  connectable, connectorEnds, elementBounds, elementContains, flipAbout, moveShapeHandle, onArc, onProtractorArc, onRuler, onRulerEdge,
  PICKER_SHAPES, rotateAbout, rulerEdge, shapeHandles, shapePoints, snapRotation, straightenAngle, transformElement, withGroups,
} from "./core/inkedit.js";
import { drawGuides, guideHit, renderSelectionPNG, stickerCanvas } from "./drawedit.js";
import { PdfDocument } from "./pdfwrite.js";

const COLORS = ["#1c1c1e", "#8e8e93", "#0a84ff", "#ff3b30", "#34c759", "#ff9500", "#af52de", "#ffd60a"];
const PEN_TOOLS = ["pen", "ballpoint", "pencil", "fountain", "brush", "marker", "highlighter"];
const RECENT_COLOURS = 8;
/** Finished ink is drawn into tiles this many device pixels square, cached per zoom step (√2 apart). */
const TILE = 512, MAX_TILES = 96;
const TOOL_INFO = {
  pen: { label: "Pen", key: "p", width: 2.5, color: "#1c1c1e", icon: "M4 20l4-1 10-10-3-3L5 16l-1 4zM14 5l3 3" },
  ballpoint: { label: "Ballpoint: one even thickness", key: "o", width: 2, color: "#1c1c1e", icon: "M5 19l2-6 9-9 2 2-9 9-6 2 2-2zM14 6l2 2" },
  pencil: { label: "Pencil", key: "n", width: 2, color: "#1c1c1e", icon: "M4 20l2-5 9-9 3 3-9 9-5 2zM15 6l3 3M6 15l3 3" },
  fountain: { label: "Fountain pen", key: "f", width: 4, color: "#1c3d8f", icon: "M12 3l5 7-5 11-5-11 5-7zM12 10v4" },
  brush: { label: "Brush pen", key: "b", width: 8, color: "#1c1c1e", icon: "M15 4l5 5-8 8c-2 2-5 3-8 3 0-3 1-6 3-8l8-8zM12 7l5 5" },
  marker: { label: "Marker", key: "m", width: 7, color: "#0a84ff", icon: "M7 21h6M9 17h2l6-6-4-4-6 6v2l2 2zM13 7l4 4" },
  highlighter: { label: "Highlighter", key: "h", width: 22, color: "#ffd60a", icon: "M5 21h8M7 17l2 2 9-9-4-4-9 9 2 2zM14 6l4 4" },
  eraser: { label: "Eraser", key: "e", width: 10, color: "", icon: "M7 20h11M5 15l8-8 6 6-5 5H9l-4-4zM9 11l5 5" },
  lasso: { label: "Lasso", key: "l", width: 0, color: "", icon: "M12 4c5 0 8 2.5 8 5.5S16.5 15 12 15s-8-2.5-8-5.5S7 4 12 4zM6 13c-1 2 0 4 2 5l-1 3" },
  shape: { label: "Shape: drag to draw a shape, arrow or connector", key: "g", width: 3, color: "#1c1c1e", icon: "M4 4h8v8H4zM17 13a4 4 0 1 0 .01 0M5 20l4-5 4 5H5z" },
  text: { label: "Text", key: "t", width: 20, color: "#1c1c1e", icon: "M5 5h14M12 5v14M9 19h6" },
  laser: { label: "Laser pointer: shows a line that fades, never saved", key: "k", width: 6, color: "#ff3b30", icon: "M5 19l7-7M14 4v3M20 10h-3M18.5 5.5l-2 2M12 12a1.5 1.5 0 1 0 .01 0" },
  tape: { label: "Tape: covers what's under it until tapped", key: "y", width: 24, color: "#f2c94c", icon: "M3 9l15-5 3 9-15 5-3-9zM7 8l2 7M12 6l2 7M17 5l2 7" },
};
const ERASER_MODES = { stroke: "Strokes", partial: "Partial", precise: "Precise (exactly under the tip)" };
const LAYOUTS = { vertical: "Scroll down", horizontal: "Scroll sideways", flip: "Flip pages" };
const MIN_ZOOM = 0.1, MAX_ZOOM = 10;
const LASER_FADE_MS = 1100;
const SHAPE_ICON = "M4 18L12 5l8 13H4z";
const PICTURE_ICON = "M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15 9.5a1.5 1.5 0 1 0 0-.01";
const HOLD_TO_SNAP_MS = 550;
/** The shape tool's shapes, with an icon each (a connector is a line joined to the shapes at its ends). */
const SHAPE_KINDS = {
  line: { label: "Line", icon: "M5 19L19 5" }, arrow: { label: "Arrow", icon: "M5 19L19 5M11 5h8v8" },
  connector: { label: "Connector: joins two shapes and follows them", icon: "M3 15h6v6H3zM15 3h6v6h-6zM9 18c5 0 6-12 6-12" },
  rectangle: { label: "Rectangle", icon: "M4 6h16v12H4z" }, ellipse: { label: "Ellipse", icon: "M12 6c5 0 9 2.7 9 6s-4 6-9 6-9-2.7-9-6 4-6 9-6z" },
  circle: { label: "Circle", icon: "M12 4a8 8 0 1 0 .01 0" }, triangle: { label: "Triangle", icon: "M12 4l9 16H3z" },
  diamond: { label: "Diamond", icon: "M12 3l9 9-9 9-9-9z" }, star: { label: "Star", icon: "M12 3l2.6 6 6.4.6-4.9 4.2 1.5 6.2L12 16.8 6.4 20l1.5-6.2L3 9.6 9.4 9z" },
  heart: { label: "Heart", icon: "M12 20s-8-5-8-11a4.5 4.5 0 0 1 8-2.5A4.5 4.5 0 0 1 20 9c0 6-8 11-8 11z" },
  bubble: { label: "Speech bubble", icon: "M4 5h16v11H10l-5 4v-4H4z" },
};
const LASSO_KINDS = { all: "Everything", ink: "Ink", text: "Text", pictures: "Pictures" };
const TEXT_FONT_TITLES = { sans: "Sans", serif: "Serif", mono: "Mono", rounded: "Rounded" };
/** A tap's slack, in screen pixels: a pen within this of a ruler's edge draws along it. */
const GUIDE_SNAP_PX = 14;

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
 * Pictures, then strokes, then text boxes, then tape on one page (`key`) of an item. `exclude`
 * hides ids (a selection being dragged, a text box being edited). `onLoaded` runs when a picture
 * arrives. `area` ({x, y, w, h} in page points) draws only what touches it (a tile); `strokes` and
 * `elements` save looking them up again; `peeked` are tape strips tapped open.
 */
function drawSurface(ctx, vault, itemId, layer, key, { exclude = null, onLoaded = null, area = null, strokes = null, elements: all = null, peeked = null } = {}) {
  const touches = (b) => !area || (b && b.x <= area.x + area.w && area.x <= b.x + b.w && b.y <= area.y + area.h && area.y <= b.y + b.h);
  const elements = (all ?? vault.elements(itemId, layer, key)).filter((e) => !exclude?.has(e.id) && touches(elementBox(e)));
  for (const e of elements) {
    if (e.type !== "image" || !e.image) continue;
    const ready = pictureBitmap(vault, e.image).ready;
    if (ready) withElementTransform(ctx, e, () => ctx.drawImage(ready, e.x, e.y, e.w, e.h));
    else pictureBitmap(vault, e.image).then(() => onLoaded?.()).catch(() => {});
  }
  for (const s of strokes ?? vault.strokes(itemId, layer, key)) if (!exclude?.has(s.id) && touches(strokeBounds(s))) drawStroke(ctx, s);
  for (const e of elements) if (e.type === "text") drawTextElement(ctx, e);
  for (const e of elements) if (e.type === "tape") drawTapeElement(ctx, e, Boolean(peeked?.has(e.id)));
}

/** An element's box as drawn (a text box as tall as its wrapped lines), a little grown for antialiasing. */
function elementBox(e) {
  const b = elementBounds(e.type === "text" ? { ...e, h: textHeight(e) } : e);
  return { x: b.x - 2, y: b.y - 2, w: b.w + 4, h: b.h + 4 };
}

/** Everything drawn on a page, as a box in page points (for the endless canvas). */
function contentBounds(vault, itemId, layer, key) {
  let box = null;
  for (const s of vault.strokes(itemId, layer, key)) box = unionRect(box, strokeBounds(s));
  for (const e of vault.elements(itemId, layer, key)) box = unionRect(box, elementBounds(e));
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
  return item.pageList.map((p) => ({ key: p.id, width: p.size?.[0] ?? width, height: p.size?.[1] ?? height, paper: p.paper ?? item.paper, color: p.color }));
}

/** A text box's height as drawn: its wrapped lines. */
function textHeight(e) {
  const ctx = textHeight.ctx ??= document.createElement("canvas").getContext("2d");
  ctx.font = textFont(e.size, e);
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
  changed = () => {}, onClose = () => {}, connect = null, selectionActions = [], recognizeInk = null, actionsClass = "" }) {
  // `selectionActions` [{label, run(selection)} or {label, choices: [{label, run}]}] add buttons to
  // the lasso's bar (Ask AI and its choices); `selection` has {strokes, elements, page, box, png()}.
  // `recognizeInk(strokes, selection)` → Promise<string> turns on "Convert to text" (the website has
  // no recogniser of its own: app.js passes the relay's cloud AI). `actionsClass` is added to those
  // buttons (app.js: "ai-only", so they hide while cloud AI is off).
  const extra = { connect, selectionActions: Array.isArray(selectionActions) ? selectionActions : [], recognizeInk, actionsClass: String(actionsClass || "") };
  const prefs = { tool: "pen", colors: {}, widths: {}, eraser: "stroke", highlighterOnly: false, shapes: false, panel: innerWidth > 900,
    scribble: false, layout: "vertical", fit: "page", recent: [], dash: {}, arrow: "none", fill: null, shapeKind: "rectangle", lassoKinds: "all",
    textStyle: { font: "sans", bold: false, italic: false }, ...loadPrefs() };
  if (!SHAPE_KINDS[prefs.shapeKind]) prefs.shapeKind = "rectangle";
  if (!LASSO_KINDS[prefs.lassoKinds]) prefs.lassoKinds = "all";
  if (!prefs.textStyle || typeof prefs.textStyle !== "object") prefs.textStyle = { font: "sans", bold: false, italic: false };
  if (!Array.isArray(prefs.recent)) prefs.recent = [];
  if (!prefs.dash || typeof prefs.dash !== "object") prefs.dash = {};
  /** Tape strips tapped open here (each device keeps its own). */
  const peeked = new Set();
  let picking = false; // the eyedropper: the next tap on a page picks its colour
  let taping = null; // a strip of tape being laid
  let inkSettings = vault.inkSettings();
  if (!ERASER_MODES[prefs.eraser]) prefs.eraser = "stroke";
  if (!LAYOUTS[prefs.layout]) prefs.layout = "vertical";
  let tool = TOOL_INFO[prefs.tool] ? prefs.tool : "pen";
  // CSS pixels per page point (100 % = a page at its size in points). Fitted when the editor opens
  // and on rotation, until zoomed by hand.
  let zoom = 1;
  let zoomedByHand = false;
  let lasers = []; // fading laser lines: {view, points, end}
  let penSeen = false;
  let edited = false;
  let current = null; // the stroke being drawn
  let erasing = null; // one eraser gesture
  let lasso = null; // the loop being drawn
  let selection = null; // {view, strokes: Set, elements: Set}
  let shaping = null; // a shape being dragged out with the shape tool
  let guideDrag = null; // the ruler or protractor being moved or turned
  /** The ruler and protractor (this device only), on one page. */
  const guides = { view: null, ruler: null, protractor: null };
  let drag = null; // moving or resizing the selection
  let editing = null; // the text box being typed in
  let hover = null; // the eraser's circle under a mouse or pen
  const touches = new Map(); // finger pointers when they pan/pinch
  let pinch = null;
  let tap = null; // a two- or three-finger tap in progress
  const undo = [], redo = [];

  const colorOf = (t) => prefs.colors[t] ?? TOOL_INFO[t].color;
  const widthOf = (t) => prefs.widths[t] ?? (t === "eraserPrecise" ? 3 : TOOL_INFO[t].width);
  /** The precise eraser keeps its own (small) size. */
  const sizeKey = () => (tool === "eraser" && prefs.eraser === "precise" ? "eraserPrecise" : tool);
  const item = () => vault.item(itemId);
  const pagesNow = () => (sketch ? sketchPages(item()) : filePages.map((p, i) => ({ ...p, key: i })));

  // ---------- toolbar ----------
  // Two rows, like GoodNotes: the tools on top, the chosen tool's colours, size and modes under them
  // (tapping the chosen tool again hides or shows that row). Both scroll sideways on a narrow
  // screen; Done stays put. Page and editor settings live in popovers.
  const toolButtons = Object.entries(TOOL_INFO).map(([id, info]) => h("button", {
    type: "button", class: `ink-tool tool-${id}`, title: `${info.label} (${info.key.toUpperCase()})`, "aria-label": info.label.split(":")[0],
    onclick: () => { if (tool === id) { prefs.options = prefs.options === false; savePrefs(prefs); refreshToolbar(); requestAnimationFrame(layout); } else setTool(id); },
  }, icon(info.icon)));
  const shapeButton = h("button", { type: "button", class: "ink-tool", title: "Shapes: lines and shapes come out clean (S)", "aria-label": "Shapes",
    onclick: () => { prefs.shapes = !prefs.shapes; savePrefs(prefs); refreshToolbar(); } }, icon(SHAPE_ICON));
  const pictureInput = h("input", { type: "file", accept: "image/*", hidden: true });
  pictureInput.addEventListener("change", () => { const f = pictureInput.files?.[0]; pictureInput.value = ""; if (f) insertPicture(f); });
  const elementsButton = h("button", { type: "button", class: "ink-tool", title: "Elements: stickers, arrows, checkboxes and what you saved", "aria-label": "Elements",
    "aria-haspopup": "dialog", onclick: (e) => togglePop(elementsPop, e.currentTarget, () => refreshElementsPop()) }, icon("M5 5h6v6H5zM13 5h6v6h-6zM5 13h6v6H5zM16 13v6M13 16h6"));
  const rulerButton = h("button", { type: "button", class: "ink-tool", title: "Ruler: draw along its edges; drag to move, turn with the round knobs", "aria-label": "Ruler",
    onclick: () => toggleGuide("ruler") }, icon("M3 15L15 3l6 6L9 21zM7 11l2 2M10 8l2 2M13 5l2 2M11 15l-1-1M14 12l-1-1"));
  const protractorButton = h("button", { type: "button", class: "ink-tool", title: "Protractor: measure angles and draw arcs", "aria-label": "Protractor",
    onclick: () => toggleGuide("protractor") }, icon("M3 18a9 9 0 0 1 18 0zM12 18l5-7M12 18V9"));
  const pictureButton = h("button", { type: "button", class: "ink-tool", title: "Insert a picture", "aria-label": "Picture", onclick: () => pictureInput.click() },
    icon(PICTURE_ICON));
  const swatchRow = h("div", { class: "ink-swatches" });
  const custom = h("input", { type: "color", class: "ink-custom", "aria-label": "Any colour", title: "Any colour" });
  custom.addEventListener("change", () => setColor(custom.value));
  const hexInput = h("input", { type: "text", class: "ink-hex", "aria-label": "Colour as hex", title: "Colour as hex (#rrggbb)", maxlength: "7", spellcheck: "false",
    autocomplete: "off" });
  hexInput.addEventListener("change", () => {
    const v = hexInput.value.trim().replace(/^([0-9a-f]{6})$/i, "#$1");
    if (/^#[0-9a-fA-F]{6}$/.test(v)) setColor(v.toLowerCase()); else refreshToolbar();
  });
  const eyedropper = h("button", { type: "button", class: "ink-tool ink-mini", title: "Pick a colour from the page", "aria-label": "Pick a colour from the page",
    onclick: () => { picking = !picking; root.classList.toggle("picking", picking); eyedropper.setAttribute("aria-pressed", String(picking)); } },
  icon("M15 4l5 5-2 2-5-5 2-2zM13 6l-8 8v5h5l8-8M5 19l3-3"));
  const addPaletteButton = h("button", { type: "button", class: "ink-tool ink-mini", title: "Keep this colour in your colours (on every device)",
    "aria-label": "Add to your colours", onclick: () => addToPalette() }, icon("M12 5v14M5 12h14"));
  const favouriteButton = h("button", { type: "button", class: "secondary small", title: "Keep this pen, colour and size as a favourite (on every device)",
    onclick: () => addFavourite() }, "Save pen");
  const penButton = h("button", { type: "button", class: "secondary small", "aria-haspopup": "dialog", title: "Smoothing, pressure, lines and fill for this pen",
    onclick: (e) => togglePop(penPop, e.currentTarget, refreshPenPop) }, "Pen options");
  const favouritesRow = h("div", { class: "ink-group ink-favourites", role: "group", "aria-label": "Favourite pens" });
  const size = h("input", { type: "range", min: "0.5", max: "60", step: "0.5", class: "ink-size", "aria-label": "Size" });
  const sizeDot = h("span", { class: "ink-size-dot", "aria-hidden": "true" });
  size.addEventListener("input", () => { prefs.widths[sizeKey()] = Number(size.value); savePrefs(prefs); refreshToolbar(); });
  const eraserMode = h("select", { class: "folder-select ink-eraser-mode", "aria-label": "Eraser mode" },
    Object.entries(ERASER_MODES).map(([value, text]) => h("option", { value, text })));
  eraserMode.addEventListener("change", () => { prefs.eraser = eraserMode.value; savePrefs(prefs); refreshToolbar(); });
  const highlighterOnly = h("label", { class: "ink-check" }, h("input", { type: "checkbox" }), "Highlighter only");
  highlighterOnly.firstChild.addEventListener("change", (e) => { prefs.highlighterOnly = e.target.checked; savePrefs(prefs); });
  const undoButton = h("button", { type: "button", class: "ink-tool", title: "Undo (⌘Z, or tap with two fingers)", "aria-label": "Undo", onclick: doUndo }, lineIcon("undo"));
  const redoButton = h("button", { type: "button", class: "ink-tool", title: "Redo (⇧⌘Z, or tap with three fingers)", "aria-label": "Redo", onclick: doRedo }, lineIcon("redo"));
  const pasteButton = h("button", { type: "button", class: "secondary small", title: "Paste (⌘V)", onclick: () => paste() }, "Paste");
  const exportButton = h("button", { type: "button", class: "secondary small", onclick: () => { closePops(); exportPDF(); } }, "Export PDF");
  const pageButton = h("button", { type: "button", class: "secondary small", "aria-haspopup": "dialog", title: "Paper, page colour, size and layout",
    onclick: (e) => togglePop(pagePop, e.currentTarget, refreshPagePop) }, lineIcon("pages"), sketch ? " Page" : " View");
  const settingsButton = h("button", { type: "button", class: "ink-tool", "aria-haspopup": "dialog", "aria-label": "Settings", title: "Settings",
    onclick: (e) => togglePop(settingsPop, e.currentTarget, refreshSettingsPop) }, icon("M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"));
  const connectButton = extra.connect ? h("button", { type: "button", class: "secondary small", title: "Connect this sketch to notes, files and other sketches",
    onclick: () => { closePops(); extra.connect(); } }, lineIcon("link"), " Connect") : null;
  let panelButton = null;
  if (sketch) {
    panelButton = h("button", { type: "button", class: "ink-tool", "aria-label": "Pages panel", title: "Pages panel",
      onclick: () => { prefs.panel = !prefs.panel; savePrefs(prefs); refreshPanel(); requestAnimationFrame(layout); } }, icon("M4 4h6v7H4zM4 14h6v6H4zM13 4h7v16h-7z"));
  }
  const bar = h("div", { class: "ink-bar", role: "toolbar", "aria-label": "Drawing tools" },
    h("div", { class: "ink-bar-scroll" },
      sketch ? h("div", { class: "ink-group" }, panelButton) : null,
      h("div", { class: "ink-group" }, undoButton, redoButton, pasteButton),
      h("div", { class: "ink-group" }, toolButtons, shapeButton, pictureButton, pictureInput, elementsButton, rulerButton, protractorButton),
      favouritesRow,
      h("div", { class: "ink-group" }, pageButton, connectButton, exportButton, settingsButton),
      h("strong", { class: "ink-title", text: title })),
    h("button", { type: "button", class: "primary ink-done", onclick: close }, "Done"));
  const toolName = h("span", { class: "ink-options-name" });
  const shapeGroup = h("div", { class: "ink-group ink-shape-group", role: "radiogroup", "aria-label": "Shape" },
    Object.entries(SHAPE_KINDS).map(([id, k]) => h("button", { type: "button", class: "ink-tool ink-mini", role: "radio", "data-shape": id, title: k.label,
      "aria-label": k.label.split(":")[0], onclick: () => { prefs.shapeKind = id; savePrefs(prefs); refreshToolbar(); } }, icon(k.icon))));
  const lassoGroup = h("div", { class: "ink-group ink-lasso-group" }, h("span", { class: "hint", text: "Picks" }),
    h("div", { class: "ink-seg", role: "radiogroup", "aria-label": "The lasso picks" }, Object.entries(LASSO_KINDS).map(([id, text]) => h("button", { type: "button", role: "radio",
      "data-kinds": id, onclick: () => { prefs.lassoKinds = id; savePrefs(prefs); refreshToolbar(); } }, text))));
  const fontSelect = h("select", { class: "folder-select ink-font", "aria-label": "Font" }, Object.entries(TEXT_FONT_TITLES).map(([value, text]) => h("option", { value, text })));
  fontSelect.addEventListener("change", () => applyTextStyle({ font: fontSelect.value }));
  const boldButton = h("button", { type: "button", class: "ink-tool ink-mini ink-bold", title: "Bold (⌘B)", "aria-label": "Bold", onmousedown: (e) => e.preventDefault(),
    onclick: () => applyTextStyle({ bold: !currentTextStyle().bold }) }, h("strong", { text: "B" }));
  const italicButton = h("button", { type: "button", class: "ink-tool ink-mini ink-italic", title: "Italic (⌘I)", "aria-label": "Italic", onmousedown: (e) => e.preventDefault(),
    onclick: () => applyTextStyle({ italic: !currentTextStyle().italic }) }, h("em", { text: "I" }));
  const bulletButton = h("button", { type: "button", class: "ink-tool ink-mini", title: "Bullet list", "aria-label": "Bullet list", onmousedown: (e) => e.preventDefault(),
    onclick: () => toggleBullets() }, icon("M9 6h11M9 12h11M9 18h11M5 6h.01M5 12h.01M5 18h.01"));
  const textGroup = h("div", { class: "ink-group ink-text-group" }, fontSelect, boldButton, italicButton, bulletButton);
  const optionsBar = h("div", { class: "ink-options", role: "toolbar", "aria-label": "Tool options" },
    h("div", { class: "ink-bar-scroll" },
      h("div", { class: "ink-group" }, toolName),
      h("div", { class: "ink-group ink-colors" }, swatchRow, custom, hexInput, eyedropper, addPaletteButton),
      h("div", { class: "ink-group ink-size-group" }, sizeDot, size),
      h("div", { class: "ink-group ink-pen-group" }, penButton, favouriteButton),
      h("div", { class: "ink-group ink-eraser-group" }, eraserMode, highlighterOnly),
      shapeGroup, lassoGroup, textGroup));
  const head = h("div", { class: "ink-head" }, bar, optionsBar);

  // The lasso's actions, along the bottom while something is selected.
  // Turning, flipping and arranging are icons; the rest are words.
  const selAction = (label, d, run, extraClass = "") => h("button", { type: "button", class: `ink-tool ink-mini${extraClass}`, title: label, "aria-label": label, onclick: run }, icon(d));
  const groupButton = h("button", { type: "button", class: "secondary small ink-group-button", onclick: () => toggleGroup() }, "Group");
  const hookClass = extra.actionsClass ? ` ${extra.actionsClass}` : "";
  const convertButton = extra.recognizeInk ? h("button", { type: "button", class: `secondary small${hookClass}`, onclick: () => convertSelection() }, "Convert to text") : null;
  const copyImageButton = h("button", { type: "button", class: "secondary small", onclick: () => copySelectionImage() }, "Copy as image");
  const selectionBar = h("div", { class: "ink-selbar", hidden: true, role: "toolbar", "aria-label": "Selection" },
    h("span", { class: "ink-selcount" }),
    h("div", { class: "ink-group" }, COLORS.map((c) => h("button", { type: "button", class: "ink-swatch", "aria-label": `Recolour ${c}`, style: `--swatch:${c}`,
      onclick: () => recolourSelection(c) }))),
    h("div", { class: "ink-group" },
      selAction("Turn a quarter right", "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7", () => turnSelection(Math.PI / 2)),
      selAction("Flip left to right", "M12 3v18M9 7L4 17h5zM15 7l5 10h-5z", () => flipSelection("x")),
      selAction("Flip upside down", "M3 12h18M7 9L17 4v5zM7 15l10 5v-5z", () => flipSelection("y")),
      selAction("Bring to front", "M8 8h12v12H8zM4 4h12v2M4 4v12h2", () => arrangeSelection(true)),
      selAction("Send to back", "M4 4h12v12H4zM8 20h12V8h-2", () => arrangeSelection(false)),
      selAction("Straighten", "M4 18L20 6M4 18h16", () => straightenSelection())),
    groupButton,
    h("button", { type: "button", class: "secondary small", onclick: () => duplicateSelection() }, "Duplicate"),
    h("button", { type: "button", class: "secondary small", onclick: () => copySelection() }, "Copy"),
    copyImageButton,
    h("button", { type: "button", class: "secondary small", onclick: (e) => openSaveElement(e.currentTarget) }, "Save as element"),
    convertButton,
    // Ask AI (and anything else passed in `selectionActions`).
    extra.selectionActions.map((a) => h("button", { type: "button", class: `secondary small ink-hook-action${hookClass}`, "aria-haspopup": a.choices ? "menu" : null,
      onclick: (e) => (a.choices ? togglePop(actionsPop, e.currentTarget, () => fillActionsPop(a)) : runSelectionAction(a)) }, String(a.label))),
    h("button", { type: "button", class: "secondary small", onclick: () => { copySelection(); deleteSelection(); } }, "Cut"),
    h("button", { type: "button", class: "secondary small danger", onclick: () => deleteSelection() }, "Delete"),
    h("button", { type: "button", class: "secondary small", "aria-label": "Deselect", onclick: () => clearSelection() }, lineIcon("close")));

  // ---------- popovers ----------
  const pagePop = h("div", { class: "ink-pop", role: "dialog", "aria-label": "Page", hidden: true });
  const settingsPop = h("div", { class: "ink-pop", role: "dialog", "aria-label": "Settings", hidden: true });
  const zoomPop = h("div", { class: "ink-pop ink-zoom-pop", role: "dialog", "aria-label": "Zoom", hidden: true });
  const penPop = h("div", { class: "ink-pop", role: "dialog", "aria-label": "Pen options", hidden: true });
  const elementsPop = h("div", { class: "ink-pop ink-elements-pop", role: "dialog", "aria-label": "Elements", hidden: true });
  // A hook action's choices (Ask AI: summarise, explain…), opening upwards from the selection's bar.
  const actionsPop = h("div", { class: "ink-pop ink-actions-pop", role: "menu", "aria-label": "Actions", hidden: true, "data-up": "true" });
  let openPop = null;
  function togglePop(pop, anchor, fill) {
    if (openPop === pop) { closePops(); return; }
    closePops();
    fill();
    pop.hidden = false;
    openPop = pop;
    const r = anchor.getBoundingClientRect(), rr = root.getBoundingClientRect();
    const width = Math.min(340, rr.width - 16);
    pop.style.width = `${width}px`;
    pop.style.left = `${Math.max(8, Math.min(rr.width - width - 8, r.left - rr.left))}px`;
    if (pop === zoomPop || pop.dataset.up) { pop.style.top = ""; pop.style.bottom = `${rr.bottom - r.top + 8}px`; } else { pop.style.bottom = ""; pop.style.top = `${r.bottom - rr.top + 6}px`; }
  }
  function closePops() { for (const p of [pagePop, settingsPop, zoomPop, penPop, elementsPop, actionsPop]) p.hidden = true; openPop = null; }
  const onOutside = (e) => { if (openPop && !openPop.contains(e.target) && !e.target.closest?.(".ink-head, .ink-zoom-pill, .ink-selbar")) closePops(); };
  document.addEventListener("pointerdown", onOutside, true);

  const segmented = (label, options, value, onPick) => h("div", { class: "ink-seg", role: "radiogroup", "aria-label": label },
    Object.entries(options).map(([v, text]) => h("button", { type: "button", role: "radio", "aria-checked": String(v === value), onclick: () => onPick(v) }, text)));

  /** Paper, colour and size for this page or every page; the sketch's layout and how pages show. */
  function refreshPagePop() {
    const parts = [];
    if (sketch) {
      const it = item();
      const spec = pagesNow().find((p) => p.key === currentKey) ?? pagesNow()[0];
      const page = it.pageList.find((p) => p.id === spec?.key);
      const scope = pagePop.dataset.scope ?? "all";
      const apply = (change) => {
        if (scope === "all" || it.infinite) vault.setAllPages(itemId, change); else vault.setPage(itemId, spec.key, change);
        afterPagesChanged();
        refreshPagePop();
      };
      if (!it.infinite) {
        parts.push(segmented("Change", { all: "Every page", one: "This page" }, scope, (v) => { pagePop.dataset.scope = v; refreshPagePop(); }));
      }
      parts.push(h("div", { class: "ink-pop-title", text: "Paper" }));
      parts.push(h("div", { class: "ink-papers" }, PAPER_GROUPS.map(([group, papers]) => h("div", { class: "ink-paper-group" },
        h("span", { class: "hint", text: group }),
        h("div", { class: "ink-paper-row" }, papers.map((paper) => {
          const c = h("canvas", { width: 72, height: 96, class: "ink-paper-thumb" });
          const ctx = c.getContext("2d");
          ctx.scale(72 / 300, 96 / 400);
          drawPaper(ctx, paper, 300, 400, spec?.color);
          return h("button", { type: "button", class: "ink-paper", "aria-pressed": String(spec?.paper === paper), title: PAPER_TITLES[paper],
            onclick: () => apply({ paper }) }, c, h("span", { text: PAPER_TITLES[paper] }));
        }))))));
      parts.push(h("div", { class: "ink-pop-title", text: "Page colour" }));
      parts.push(h("div", { class: "ink-page-colors" }, PAGE_COLORS.map((c) => h("button", { type: "button", class: "ink-swatch page-swatch",
        "aria-label": PAGE_COLOR_TITLES[c] ?? c, title: PAGE_COLOR_TITLES[c] ?? c, style: `--swatch:${c}`,
        "aria-pressed": String((page?.color ?? spec?.color ?? "#ffffff") === c), onclick: () => apply({ color: c === "#ffffff" ? "" : c }) }))));
      if (!it.infinite && spec) {
        const named = pageSizeName([spec.width, spec.height]);
        const sizeSelect = h("select", { class: "folder-select", "aria-label": "Page size" },
          Object.entries(PAGE_SIZES).map(([v, { title: t }]) => h("option", { value: v, text: t })), named ? null : h("option", { value: "", text: "Custom" }));
        sizeSelect.value = named?.name ?? "";
        const landscape = named?.landscape ?? spec.width > spec.height;
        const sized = (name, land) => { const [a, b] = PAGE_SIZES[name].size; return land ? [b, a] : [a, b]; };
        sizeSelect.addEventListener("change", () => { if (sizeSelect.value) apply({ size: sized(sizeSelect.value, sizeSelect.value === "wide" ? true : landscape) }); });
        parts.push(h("div", { class: "ink-pop-title", text: "Size" }),
          h("div", { class: "ink-pop-row" }, sizeSelect,
            segmented("Orientation", { portrait: "Portrait", landscape: "Landscape" }, landscape ? "landscape" : "portrait",
              (v) => apply({ size: [Math.min(spec.width, spec.height), Math.max(spec.width, spec.height)][v === "landscape" ? "reverse" : "slice"]() }))));
      }
      parts.push(h("div", { class: "ink-pop-title", text: "Canvas" }),
        segmented("Canvas", { pages: "Pages", infinite: "Endless canvas" }, it.infinite ? "infinite" : "pages", (v) => {
          clearSelection(); vault.setSketchCanvas(itemId, v === "infinite"); afterPagesChanged(); refreshPagePop();
        }));
    }
    if (!infinite) {
      parts.push(h("div", { class: "ink-pop-title", text: "Pages show" }),
        segmented("Pages show", LAYOUTS, prefs.layout, (v) => { setLayout(v); refreshPagePop(); }));
    }
    if (sketch && !item().infinite) {
      parts.push(h("div", { class: "ink-pop-row" },
        h("button", { type: "button", class: "secondary small", onclick: () => addPage(currentKey) }, "+ Page after this"),
        h("button", { type: "button", class: "secondary small", onclick: () => { closePops(); prefs.panel = true; savePrefs(prefs); refreshPanel(); requestAnimationFrame(layout); } }, "All pages…")));
    }
    pagePop.replaceChildren(...parts);
  }

  function refreshSettingsPop() {
    const check = (label, hint, key, after = () => {}) => {
      const box = h("input", { type: "checkbox" });
      box.checked = Boolean(prefs[key]);
      box.addEventListener("change", () => { prefs[key] = box.checked; savePrefs(prefs); refreshToolbar(); after(); });
      return h("label", { class: "ink-setting" }, box, h("span", {}, h("strong", { text: label }), h("span", { class: "hint", text: hint })));
    };
    settingsPop.replaceChildren(
      check("Scribble to erase", "Scratch back and forth right over something to delete it. Off: every line stays.", "scribble"),
      check("Shapes", "Lines and shapes come out clean. Holding the pen still at the end of a line does it either way.", "shapes"),
      h("div", { class: "ink-pop-title", text: "When a drawing opens" }),
      segmented("Zoom when opening", { page: "Whole page", width: "Page width" }, prefs.fit, (v) => { prefs.fit = v; savePrefs(prefs); zoomedByHand = false; fitZoom(); refreshSettingsPop(); }),
      favouritesEditor(),
      paletteEditor(),
      compactSetting(),
      h("p", { class: "hint", text: "Apple Pencil: draw with the pen, scroll and pinch with fingers. Two-finger tap undoes, three-finger tap redoes." }));
  }

  /** Favourites, each with a button to take it off (they're on every device). */
  function favouritesEditor() {
    const list = inkSettings.favourites;
    return h("div", {},
      h("div", { class: "ink-pop-title", text: "Favourite pens" }),
      list.length ? h("div", { class: "ink-pop-row ink-fav-list" }, list.map((f, i) => h("span", { class: "ink-chip" }, favouriteDot(f),
        h("button", { type: "button", class: "ink-chip-x", "aria-label": `Remove favourite ${i + 1}`, title: "Remove",
          onclick: () => { vault.setInkFavourites(list.filter((_, j) => j !== i)); settingsChanged(); refreshSettingsPop(); } }, lineIcon("close")))))
        : h("p", { class: "hint", text: "Pick a pen, colour and size, then Save pen. Up to 10, one tap away." }));
  }

  function paletteEditor() {
    const list = inkSettings.palette;
    if (!list.length) return null;
    return h("div", {},
      h("div", { class: "ink-pop-title", text: "Your colours" }),
      h("div", { class: "ink-pop-row ink-fav-list" }, list.map((c) => h("span", { class: "ink-chip" }, h("span", { class: "ink-swatch", style: `--swatch:${c}`, "aria-hidden": "true" }),
        h("button", { type: "button", class: "ink-chip-x", "aria-label": `Remove colour ${c}`, title: "Remove",
          onclick: () => { vault.setInkPalette(list.filter((x) => x !== c)); settingsChanged(); refreshSettingsPop(); } }, lineIcon("close"))))));
  }

  function compactSetting() {
    const box = h("input", { type: "checkbox" });
    box.checked = inkSettings.compactPoints;
    box.addEventListener("change", () => { vault.setCompactPoints(box.checked); settingsChanged(); });
    return h("label", { class: "ink-setting" }, box, h("span", {}, h("strong", { text: "Smaller drawings" }),
      h("span", { class: "hint", text: "New ink takes a quarter of the space. Turn on once every device has the latest Trove: older apps can't show ink saved this way." })));
  }

  /** The pen's feel (synced: smoothing, pressure, lightest touch) and its lines (this device: dashes, arrows, fill). */
  function refreshPenPop() {
    const penTool = PEN_TOOLS.includes(tool) ? tool : "pen";
    const feel = inkSettings.pens[penTool];
    const save = (change) => { vault.setPenSettings(penTool, { ...feel, ...change }); settingsChanged(); refreshPenPop(); };
    const slider = (label, hint, key, max, unit) => {
      const input = h("input", { type: "range", min: "0", max: String(max), step: "1", class: "ink-pen-slider", "aria-label": label });
      input.value = String(feel[key]);
      const value = h("strong", { class: "ink-zoom-value", text: `${feel[key]}${unit}` });
      input.addEventListener("input", () => { value.textContent = `${input.value}${unit}`; });
      input.addEventListener("change", () => save({ [key]: Number(input.value) }));
      return h("div", {}, h("div", { class: "ink-pop-row" }, h("span", { text: label }), value), input, h("p", { class: "hint", text: hint }));
    };
    const shapeTool = tool === "shape", dashKey = shapeTool ? "shape" : penTool;
    const parts = shapeTool ? [] : [h("div", { class: "ink-pop-title", text: `${TOOL_INFO[penTool].label}: on every device` })];
    if (!shapeTool) parts.push(slider("Smoothing", "Steadies the line as you write. 0 is exactly where the pen goes.", "smoothing", 100, ""));
    if (!shapeTool && penTool !== "marker" && penTool !== "highlighter" && penTool !== "ballpoint") {
      parts.push(h("div", { class: "ink-pop-row" }, h("span", { text: "Pressure" }),
        segmented("Pressure", { soft: "Soft", normal: "Normal", firm: "Firm" }, feel.curve, (v) => save({ curve: v }))));
      parts.push(slider("Lightest touch", "How thick the lightest touch still writes, as a share of full pressure.", "minWidth", 100, "%"));
    }
    parts.push(h("div", { class: "ink-pop-title", text: "Lines (this device)" }));
    parts.push(segmented("Line", { solid: "Solid", dash: "Dashes", dot: "Dots" }, prefs.dash[dashKey] ?? "solid", (v) => {
      prefs.dash[dashKey] = v === "solid" ? undefined : v; savePrefs(prefs); refreshPenPop();
    }));
    parts.push(h("div", { class: "ink-pop-row" }, h("span", { text: "Arrows on straight lines" }),
      segmented("Arrows", { none: "None", end: "End", both: "Both ends" }, prefs.arrow ?? "none", (v) => { prefs.arrow = v; savePrefs(prefs); refreshPenPop(); })));
    parts.push(h("div", { class: "ink-pop-title", text: "Fill closed shapes" }),
      h("div", { class: "ink-pop-row ink-fill-row" },
        h("button", { type: "button", class: "secondary small", "aria-pressed": String(!prefs.fill), onclick: () => { prefs.fill = null; savePrefs(prefs); refreshPenPop(); } }, "No fill"),
        [...COLORS, "#ffffff"].map((c) => h("button", { type: "button", class: "ink-swatch", "aria-label": `Fill ${c}`, title: `Fill ${c}`, style: `--swatch:${c}`,
          "aria-pressed": String(prefs.fill === c), onclick: () => { prefs.fill = c; savePrefs(prefs); refreshPenPop(); } }))),
      h("p", { class: "hint", text: "Shapes snap when Shapes is on or when you hold the pen still at the end of a line." }));
    penPop.replaceChildren(...parts);
  }

  /** The synced drawing settings changed (here or on another device). */
  function settingsChanged() {
    inkSettings = vault.inkSettings();
    refreshToolbar();
  }

  // ---------- favourites and colours ----------
  const toolOfFavourite = (f) => (TOOL_INFO[f.tool] ? f.tool : "pen");
  function favouriteDot(f) {
    const d = Math.max(6, Math.min(18, f.width * (f.tool === "highlighter" ? 0.6 : 1.6) + 4));
    return h("span", { class: "ink-fav-dot", "aria-hidden": "true", style: `--swatch:${f.color};--d:${d}px;opacity:${f.tool === "highlighter" ? 0.6 : 1}` });
  }
  function refreshFavourites() {
    const list = inkSettings.favourites;
    favouritesRow.hidden = !list.length;
    favouritesRow.replaceChildren(...list.map((f, i) => {
      const active = tool === f.tool && colorOf(f.tool) === f.color && widthOf(f.tool) === f.width;
      return h("button", { type: "button", class: "ink-tool ink-fav", "aria-pressed": String(active),
        "aria-label": `Favourite ${i + 1}: ${TOOL_INFO[toolOfFavourite(f)].label.split(":")[0]}, ${f.color}, size ${f.width}`,
        title: `${TOOL_INFO[toolOfFavourite(f)].label.split(":")[0]}, size ${f.width}`, onclick: () => useFavourite(f) }, favouriteDot(f));
    }));
  }
  function useFavourite(f) {
    prefs.colors[f.tool] = f.color;
    prefs.widths[f.tool] = f.width;
    savePrefs(prefs);
    if (tool !== f.tool) setTool(f.tool); else refreshToolbar();
  }
  function addFavourite() {
    if (!PEN_TOOLS.includes(tool)) return;
    const f = { tool, color: colorOf(tool).toLowerCase(), width: widthOf(tool) };
    const list = inkSettings.favourites.filter((x) => !(x.tool === f.tool && x.color === f.color && x.width === f.width));
    vault.setInkFavourites([...list, f].slice(-MAX_FAVOURITES));
    settingsChanged();
  }
  function addToPalette() {
    const c = (PEN_TOOLS.includes(tool) || tool === "text" || tool === "tape" ? colorOf(tool) : custom.value).toLowerCase();
    if (inkSettings.palette.includes(c)) return;
    vault.setInkPalette([...inkSettings.palette, c].slice(-MAX_PALETTE));
    settingsChanged();
  }
  function noteRecent(c) {
    prefs.recent = [c, ...prefs.recent.filter((x) => x !== c)].slice(0, RECENT_COLOURS);
  }
  /** The colours offered: the tool's own, your colours (synced) and recently used (this device). */
  function refreshSwatches(current) {
    const base = tool === "tape" ? TAPE_COLORS : COLORS;
    const mine = inkSettings.palette.filter((c) => !base.includes(c));
    const recent = prefs.recent.filter((c) => !base.includes(c) && !mine.includes(c)).slice(0, 5);
    const swatch = (c, kind) => h("button", { type: "button", class: `ink-swatch${kind ? ` ${kind}` : ""}`, title: c, "aria-label": `Colour ${c}`, style: `--swatch:${c}`,
      "aria-pressed": String(c === current), onclick: () => setColor(c) });
    swatchRow.replaceChildren(...base.map((c) => swatch(c, "")),
      ...(mine.length ? [h("span", { class: "ink-sep", "aria-hidden": "true" }), ...mine.map((c) => swatch(c, "mine"))] : []),
      ...(recent.length ? [h("span", { class: "ink-sep", "aria-hidden": "true" }), ...recent.map((c) => swatch(c, "recent"))] : []));
  }

  // ---------- zoom (bottom left) ----------
  const zoomPill = h("button", { type: "button", class: "ink-zoom-pill", title: "Zoom: tap for options", "aria-haspopup": "dialog",
    onclick: (e) => togglePop(zoomPop, e.currentTarget, refreshZoomPop) });
  const zoomLabel = zoomPill;
  const toLog = (z) => Math.log(z / MIN_ZOOM) / Math.log(MAX_ZOOM / MIN_ZOOM), fromLog = (f) => MIN_ZOOM * (MAX_ZOOM / MIN_ZOOM) ** f;
  function refreshZoomPop() {
    const slider = h("input", { type: "range", min: "0", max: "1", step: "0.001", class: "ink-zoom-slider", "aria-label": "Zoom" });
    slider.value = String(toLog(zoom));
    const label = h("strong", { class: "ink-zoom-value", text: `${Math.round(zoom * 100)}%` });
    slider.addEventListener("input", () => { setZoom(fromLog(Number(slider.value)), null, true); label.textContent = `${Math.round(zoom * 100)}%`; });
    const preset = (text, fn) => h("button", { type: "button", class: "secondary small", onclick: () => { fn(); refreshZoomPop(); } }, text);
    zoomPop.replaceChildren(
      h("div", { class: "ink-pop-row" }, preset("−", () => setZoom(zoom / 1.25, null, true)), label, preset("+", () => setZoom(zoom * 1.25, null, true))),
      slider,
      h("div", { class: "ink-pop-row ink-zoom-presets" },
        preset("Reset to 100%", () => setZoom(1, null, true)),
        infinite ? null : preset("Whole page", () => { zoomedByHand = false; fitZoom("page"); }),
        infinite ? null : preset("Page width", () => { zoomedByHand = false; fitZoom("width"); }),
        ...[50, 200, 400].map((n) => preset(`${n}%`, () => setZoom(n / 100, null, true)))),
      h("p", { class: "hint", text: "10% to 1000%. Pinch, ⌘/Ctrl + scroll or + and − zoom too." }));
  }

  // ---------- pages ----------
  const stack = h("div", { class: "ink-pages" });
  const scroller = h("div", { class: "ink-scroller" }, stack);
  const panel = h("aside", { class: "ink-panel", "aria-label": "Pages" });
  const stage = h("div", { class: "ink-stage" }, scroller);
  const body = h("div", { class: "ink-body" }, panel, stage);
  const flipPrev = h("button", { type: "button", class: "ink-flip ink-flip-prev", "aria-label": "Previous page", onclick: () => flipBy(-1) }, lineIcon("back"));
  const flipNext = h("button", { type: "button", class: "ink-flip ink-flip-next", "aria-label": "Next page", onclick: () => flipBy(1) }, lineIcon("forward"));
  const pageCount = h("span", { class: "ink-page-count", "aria-live": "polite" });
  stage.append(h("div", { class: "ink-corner" }, zoomPill, pageCount), flipPrev, flipNext);
  const root = h("div", { class: "ink-editor", role: "dialog", "aria-label": `Drawing: ${title}` }, head, body, selectionBar, pagePop, settingsPop, zoomPop, penPop, elementsPop, actionsPop);
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
    // The pen's layer paints without waiting for the compositor where the browser can (lower latency).
    try { live.getContext("2d", { desynchronized: true }); } catch { /* an ordinary context then */ }
    const view = { key: spec.key, index, spec, el, bg, ink: inkCanvas, live, bgWidth: 0, inkWidth: 0, visible: Boolean(spec.infinite), infinite: Boolean(spec.infinite),
      scale: 1, ox: 0, oy: 0, state: null, tiles: { step: 0, map: new Map() }, dirtyBoxes: [] };
    views.push(view);
    stack.append(el);
    wirePointer(view);
    if (!spec.infinite) io.observe(el);
    return view;
  }

  /** Sizes the pages for the zoom, and shows them down, across or one at a time. */
  function layout() {
    root.dataset.layout = infinite ? "endless" : prefs.layout;
    zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
    if (infinite) {
      infinite.scale = zoom;
      renderView(infinite, true);
      refreshPageCount();
      return;
    }
    for (const v of views) {
      v.el.style.width = `${Math.round(v.spec.width * zoom)}px`;
      v.el.hidden = prefs.layout === "flip" && v.key !== currentKey;
    }
    refreshPageCount();
    renderVisible();
  }

  /** The zoom that fits the page in view: all of it, or its width. */
  function fitZoom(kind = prefs.fit) {
    const spec = infinite ? null : (viewByKey(currentKey) ?? views[0])?.spec;
    if (!spec || !scroller.clientWidth) return;
    const w = Math.max(120, scroller.clientWidth - 32), hgt = Math.max(120, scroller.clientHeight - 44);
    const z = kind === "width" || prefs.layout === "vertical" && kind === "width" ? w / spec.width : Math.min(w / spec.width, hgt / spec.height);
    setZoom(z);
    if (prefs.layout !== "flip") reveal(viewByKey(currentKey));
  }

  function setLayout(next) {
    prefs.layout = next;
    savePrefs(prefs);
    if (!zoomedByHand) fitZoom(); else layout();
    requestAnimationFrame(() => reveal(viewByKey(currentKey)));
  }

  function refreshPageCount() {
    const n = infinite ? 0 : views.length;
    const i = views.findIndex((v) => v.key === currentKey);
    pageCount.textContent = n > 1 ? `${i + 1} / ${n}` : "";
    pageCount.hidden = n < 2;
    const flip = !infinite && prefs.layout === "flip";
    flipPrev.hidden = !flip || i <= 0;
    flipNext.hidden = !flip || i >= n - 1;
  }

  /** Flip mode: turn to the next (1) or previous (−1) page, like turning paper. */
  function flipBy(step) {
    const i = views.findIndex((v) => v.key === currentKey);
    const to = views[Math.max(0, Math.min(views.length - 1, i + step))];
    if (!to || to === views[i] || infinite) return;
    if (editing) commitText();
    clearSelection();
    const from = views[i];
    if (prefs.layout === "flip") {
      from.el.classList.remove("turn-in-next", "turn-in-prev");
      to.el.hidden = false;
      to.el.classList.add(step > 0 ? "turn-in-next" : "turn-in-prev");
      from.el.hidden = true;
      setTimeout(() => to.el.classList.remove("turn-in-next", "turn-in-prev"), 450);
    }
    setCurrentPage(to.key);
    layout();
    if (prefs.layout !== "flip") reveal(to, true);
    else scroller.scrollTo({ top: 0, left: Math.max(0, (scroller.scrollWidth - scroller.clientWidth) / 2) });
  }

  /** Scrolls a page into view with the gap above (or beside) it showing. */
  function reveal(v, smooth = false) {
    if (!v || infinite) return;
    const across = prefs.layout === "horizontal";
    const left = across ? v.el.offsetLeft - 16 : Math.max(0, v.el.offsetLeft + v.el.offsetWidth / 2 - scroller.clientWidth / 2);
    scroller.scrollTo({ top: across ? 0 : Math.max(0, v.el.offsetTop - 18), left, behavior: smooth ? "smooth" : "auto" });
  }

  /** CSS pixels per page point. */
  const cssScale = (v) => (v.infinite ? v.scale : v.el.clientWidth / v.spec.width);

  /**
   * The part of a page its canvases cover, in CSS pixels from the page's corner: all of it, or when
   * that would be too many pixels (zoomed far in), what's on screen and a margin around it.
   */
  const MAX_PIXELS = 12e6;
  function regionOf(v) {
    const dpr = Math.min(devicePixelRatio || 1, 3);
    const css = v.el.clientWidth, cssH = css * v.spec.height / v.spec.width;
    if (css * cssH * dpr * dpr <= MAX_PIXELS) return { x: 0, y: 0, w: css, h: cssH, clipped: false };
    const er = v.el.getBoundingClientRect(), sr = scroller.getBoundingClientRect();
    const mx = sr.width * 0.35, my = sr.height * 0.35;
    const x0 = Math.max(0, sr.left - er.left - mx), y0 = Math.max(0, sr.top - er.top - my);
    const x1 = Math.min(css, sr.right - er.left + mx), y1 = Math.min(cssH, sr.bottom - er.top + my);
    return { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0), clipped: true };
  }

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
    const r = v.region ?? (v.region = regionOf(v));
    w = Math.max(1, Math.round(r.w * dpr)); hgt = Math.max(1, Math.round(r.h * dpr));
    if (canvas.width !== w || canvas.height !== hgt) { canvas.width = w; canvas.height = hgt; }
    canvas.style.cssText = r.clipped ? `left:${r.x}px;top:${r.y}px;width:${r.w}px;height:${r.h}px` : "";
    k = dpr * v.el.clientWidth / v.spec.width;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, hgt);
    ctx.setTransform(k, 0, 0, k, -r.x * dpr, -r.y * dpr);
    return ctx;
  }

  /** Zoomed far in, a page's canvases follow the scrolling. */
  function refollow() {
    for (const v of views) {
      if (!v.visible || v.infinite || !v.region?.clipped) continue;
      const er = v.el.getBoundingClientRect(), sr = scroller.getBoundingClientRect(), r = v.region;
      const vx0 = sr.left - er.left, vy0 = sr.top - er.top;
      if (vx0 < r.x || vy0 < r.y || vx0 + sr.width > r.x + r.w || vy0 + sr.height > r.y + r.h) renderView(v, true);
    }
  }

  /** The part of an endless canvas on screen, in page points. */
  const area = (v) => ({ x: v.ox, y: v.oy, w: v.el.clientWidth / v.scale, h: v.el.clientHeight / v.scale });

  async function renderView(v, force = false) {
    if (!v.visible || !v.el.clientWidth || v.el.hidden) return;
    const css = v.el.clientWidth;
    if (!v.infinite && (v.bgWidth !== css || force)) v.region = regionOf(v);
    if (v.infinite || v.bgWidth !== css || force) {
      v.bgWidth = css;
      const ctx = prepare(v, v.bg);
      if (sketch) drawPaper(ctx, v.spec.paper, v.spec.width, v.spec.height, v.spec.color, v.infinite ? area(v) : null);
      else { ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, v.spec.width, v.spec.height); }
      try { await v.spec.background?.(ctx, (v.bg.width / (v.region?.w ?? v.el.clientWidth)) * v.el.clientWidth / v.spec.width); } catch { /* no background */ }
    }
    if (v.infinite || v.inkWidth !== css || v.dirty || force) { v.inkWidth = css; v.dirty = false; renderInk(v); }
    renderLive(v);
  }
  function renderVisible() { for (const v of views) if (v.visible) renderView(v); }

  // A pen reports up to 240 moves a second: draw at most once per screen frame.
  function scheduleLive(v) {
    if (v.liveFrame) return;
    v.liveFrame = requestAnimationFrame(() => { v.liveFrame = 0; renderLive(v); });
  }
  function scheduleView(v) {
    if (v.viewFrame) return;
    v.viewFrame = requestAnimationFrame(() => { v.viewFrame = 0; renderView(v); });
  }

  /** Ids hidden from the ink layer: a selection being dragged (drawn live instead), a text box being typed in. */
  function hidden(v) {
    const out = new Set();
    if (drag && selection?.view === v) { for (const id of selection.strokes) out.add(id); for (const id of selection.elements) out.add(id); }
    if (editing?.view === v && editing.id) out.add(editing.id);
    return out;
  }

  // ---------- finished ink: what changed, the page's grid, and tiles ----------

  /**
   * Brings a page's record of its ink up to date: what each stroke and element looked like when
   * last drawn, the grid of stroke boxes (for the eraser, lasso and scribble), and the boxes that
   * changed since (for the tiles to redraw). O(strokes on the page), and only when the vault changed.
   */
  function syncInk(v) {
    const hide = hidden(v);
    const sig = `${vault.store.version}|${[...hide].join(",")}|${[...peeked].join(",")}`;
    if (v.state?.sig === sig) return v.state;
    const strokes = vault.strokes(itemId, layer, v.key), elements = vault.elements(itemId, layer, v.key);
    const prev = v.state?.entries ?? new Map(), grid = v.state?.grid ?? new InkGrid(), next = new Map();
    const dirty = (box) => { if (box) v.dirtyBoxes.push(box); };
    for (const s of strokes) {
      const stamp = hide.has(s.id) ? "hidden" : s.cache, old = prev.get(s.id);
      const box = strokeBounds(s);
      next.set(s.id, { stamp, box });
      if (!old || old.stamp !== stamp) { dirty(old?.box); dirty(box); grid.add(s.id, box); }
    }
    for (const e of elements) {
      const stamp = `${hide.has(e.id)}|${peeked.has(e.id)}|${e.type}|${e.x},${e.y},${e.w},${e.h}|${e.size}|${e.color}|${e.text}|${e.image?.id ?? ""}|${e.rotate}|${e.flip}|${e.font}|${e.bold}|${e.italic}`, old = prev.get(e.id);
      const box = elementBox(e);
      next.set(e.id, { stamp, box });
      if (!old || old.stamp !== stamp) { dirty(old?.box); dirty(box); }
    }
    for (const [id, old] of prev) if (!next.has(id)) { dirty(old.box); grid.remove(id); }
    v.state = { sig, entries: next, grid, strokes, elements };
    return v.state;
  }

  /** Strokes on a page whose box touches `r` (page points), oldest first. */
  function strokesNear(v, r) {
    const st = syncInk(v);
    if (!r) return [];
    const ids = new Set(st.grid.query(r));
    return st.strokes.filter((s) => ids.has(s.id));
  }

  /** Tiles kept for every page, least recently used first, so memory stays bounded. */
  const tileUse = new Map(); // tile → view
  function dropTile(v, key) {
    const t = v.tiles.map.get(key);
    if (!t) return;
    v.tiles.map.delete(key);
    tileUse.delete(t);
    t.canvas.width = 0;
  }

  /**
   * The ink layer from 512-pixel tiles of finished ink, each drawn once per zoom step (√2 apart,
   * rounded up so tiles are only ever scaled down) and kept until something on it changes. Panning
   * and zooming between steps reuse them; a new stroke redraws only the tiles under it.
   */
  function renderInk(v) {
    const st = syncInk(v);
    const ctx = prepare(v, v.ink);
    const m = ctx.getTransform(); // page points → device pixels
    const k = m.a;
    const step = Math.SQRT2 ** Math.ceil(Math.log(Math.max(k, 0.01)) / Math.log(Math.SQRT2) - 1e-9);
    const tiles = v.tiles;
    if (tiles.step !== step) { for (const key of [...tiles.map.keys()]) dropTile(v, key); tiles.step = step; }
    const span = TILE / step; // page points per tile
    for (const b of v.dirtyBoxes) {
      for (let tx = Math.floor(b.x / span); tx <= Math.floor((b.x + b.w) / span); tx++) {
        for (let ty = Math.floor(b.y / span); ty <= Math.floor((b.y + b.h) / span); ty++) dropTile(v, `${tx},${ty}`);
      }
    }
    v.dirtyBoxes = [];
    // What the canvas shows, in page points.
    const x0 = -m.e / k, y0 = -m.f / k, x1 = x0 + v.ink.width / k, y1 = y0 + v.ink.height / k;
    const onLoaded = () => { for (const key of [...tiles.map.keys()]) dropTile(v, key); v.dirty = true; renderView(v); };
    const hide = hidden(v);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.imageSmoothingQuality = "high";
    for (let tx = Math.floor(x0 / span); tx * span < x1; tx++) {
      for (let ty = Math.floor(y0 / span); ty * span < y1; ty++) {
        const key = `${tx},${ty}`;
        let t = tiles.map.get(key);
        if (!t) {
          const canvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(TILE, TILE) : h("canvas", { width: TILE, height: TILE });
          const c = canvas.getContext("2d");
          c.setTransform(step, 0, 0, step, -tx * TILE, -ty * TILE);
          const area = { x: tx * span, y: ty * span, w: span, h: span };
          drawSurface(c, vault, itemId, layer, v.key, { exclude: hide, onLoaded, area, strokes: st.strokes, elements: st.elements, peeked });
          t = { canvas };
          tiles.map.set(key, t);
        }
        tileUse.delete(t);
        tileUse.set(t, v);
        // Whole device pixels at the edges, so neighbouring tiles meet without a seam.
        const dx0 = Math.round(tx * span * k + m.e), dy0 = Math.round(ty * span * k + m.f);
        const dx1 = Math.round((tx + 1) * span * k + m.e), dy1 = Math.round((ty + 1) * span * k + m.f);
        ctx.drawImage(t.canvas, dx0, dy0, dx1 - dx0, dy1 - dy0);
      }
    }
    // Too many tiles: let the least recently used go.
    while (tileUse.size > MAX_TILES) {
      const [t, owner] = tileUse.entries().next().value;
      const key = [...owner.tiles.map.entries()].find(([, x]) => x === t)?.[0];
      if (key) dropTile(owner, key); else tileUse.delete(t);
    }
  }

  function viewByKey(key) { return views.find((v) => v.key === key); }

  /** The current stroke, the lasso, the selection with its handles, the eraser. */
  function renderLive(v) {
    const ctx = prepare(v, v.live);
    const px = 1 / cssScale(v); // one CSS pixel in page points
    if (current?.view === v && current.tool !== "laser") {
      // A frame or two ahead of the pen (the browser's guess), replaced by the real points as they come.
      const ahead = current.predicted?.length && !current.shape ? { ...current, points: [...current.points, ...current.predicted] } : current;
      drawStroke(ctx, ahead);
      if (current.inputAt) {
        noteLatency(performance.now() - current.inputAt);
        current.inputAt = 0;
      }
    }
    if (taping?.view === v) drawTapeElement(ctx, { ...tapeBox(taping.start, taping.end, widthOf("tape")), color: colorOf("tape") });
    if (current?.view === v && current.tool === "laser") {
      ctx.save(); ctx.shadowColor = current.color; ctx.shadowBlur = 12;
      drawStroke(ctx, { tool: "marker", color: current.color, width: current.width * px * 1.5, points: current.points });
      ctx.restore();
    }
    lasersOn(v, ctx);
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
    if (shaping?.view === v && shaping.preview) drawStroke(ctx, shaping.preview);
    if (selection?.view === v) {
      const t = drag?.t ?? null;
      if (t) {
        // The selection drawn where it's being moved, resized or turned to.
        const els = vault.elements(itemId, layer, v.key).filter((e) => selection.elements.has(e.id));
        const moved = (e) => ({ ...e, ...transformElement(t, e) });
        for (const e of els) if (e.type === "image" && e.image) {
          const m = moved(e), b = pictureBitmap(vault, e.image).ready;
          if (b) withElementTransform(ctx, m, () => ctx.drawImage(b, m.x, m.y, m.w, m.h));
        }
        for (const s of vault.strokes(itemId, layer, v.key)) if (selection.strokes.has(s.id)) {
          drawStroke(ctx, { ...s, cache: null, width: s.width * widthScale(t), points: s.points.map((p) => transformPoint(t, p)) });
        }
        for (const e of els) if (e.type === "text") drawTextElement(ctx, { ...moved(e), size: e.size * widthScale(t) });
        for (const e of els) if (e.type === "tape") drawTapeElement(ctx, moved(e), peeked.has(e.id));
      }
      if (drag?.shapeEdit) drawStroke(ctx, drag.shapeEdit);
      const box = drag?.shapeEdit ? null : selectionBox(t);
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
        // The turning handle above the top edge.
        const [rx, ry] = rotateHandle(box, px);
        ctx.beginPath();
        ctx.moveTo(rx, box.y);
        ctx.lineTo(rx, ry + 7 * px);
        ctx.stroke();
        ctx.beginPath();
        ctx.arc(rx, ry, 7 * px, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
        if (drag?.turning) {
          ctx.fillStyle = "rgba(10, 132, 255, 0.95)";
          ctx.font = `600 ${12 * px}px system-ui, sans-serif`;
          ctx.textAlign = "center";
          ctx.fillText(`${Math.round((drag.t?.r ?? 0) * 180 / Math.PI)}°`, rx, ry - 14 * px);
        }
        ctx.restore();
      }
      // A lone shape's own handles: its ends, corners or bend.
      const handles = drag && !drag.shapeEdit ? [] : selectedShapeHandles(drag?.shapeEdit ?? null);
      if (handles.length) {
        ctx.save();
        ctx.lineWidth = 1.5 * px;
        ctx.strokeStyle = "rgba(10, 132, 255, 0.95)";
        ctx.fillStyle = "#fff";
        handles.forEach((q, i) => {
          const r = 5 * px;
          ctx.beginPath();
          if (i === 2 && (singleShape()?.shape === "line" || singleShape()?.shape === "curve")) ctx.arc(q.x, q.y, r, 0, Math.PI * 2);
          else ctx.rect(q.x - r, q.y - r, 2 * r, 2 * r);
          ctx.fill();
          ctx.stroke();
        });
        ctx.restore();
      }
    }
    if (guides.view === v) drawGuides(ctx, guides, px);
    if (hover?.view === v && (tool === "eraser")) {
      ctx.beginPath();
      ctx.arc(hover.x, hover.y, eraserRadius(v), 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(120,120,128,0.9)";
      ctx.lineWidth = 1.5 * px;
      ctx.stroke();
    }
  }

  /**
   * Input-to-paint latency of the pen's line: from the event's time to the frame that drew it, in
   * ms (the last 600, on `window.troveInkLatency` for the e2e test and anyone curious).
   */
  function noteLatency(ms) {
    const list = (globalThis.troveInkLatency ??= []);
    list.push(ms);
    if (list.length > 600) list.splice(0, list.length - 600);
  }

  // ---------- input ----------
  function toPage(v, e) {
    const r = v.el.getBoundingClientRect();
    if (v.infinite) return { x: (e.clientX - r.left) / v.scale + v.ox, y: (e.clientY - r.top) / v.scale + v.oy };
    return { x: ((e.clientX - r.left) / r.width) * v.spec.width, y: ((e.clientY - r.top) / r.height) * v.spec.height };
  }

  function wirePointer(v) {
    const c = v.live;
    c.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "pen") { penSeen = true; root.classList.add("pen-seen"); }
      if (e.pointerType === "touch") noteTap(e, "down");
      // The ruler and protractor: dragging their bodies moves them, their knobs turn them (a pen at an edge draws instead).
      if (guides.view === v && !guideDrag && !touches.size && !current && !lasso && !drag && !shaping && e.button === 0) {
        const p = toPage(v, e);
        const draws = PEN_TOOLS.includes(tool) && !(e.pointerType === "touch" && penSeen) && guideSnap(v, p);
        const hit = draws ? null : guideHit(guides, p, 1 / cssScale(v));
        if (hit) {
          const g = guides[hit.kind];
          guideDrag = { view: v, pointerId: e.pointerId, kind: hit.kind, turn: hit.turn, start: p, x: g.x, y: g.y, angle: g.angle,
            grab: Math.atan2(p.y - g.y, p.x - g.x) };
          capture(c, e);
          e.preventDefault();
          return;
        }
      }
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
      if (current || erasing || lasso || drag || taping || shaping || guideDrag) return;
      e.preventDefault();
      capture(c, e);
      const p = toPage(v, e);
      setCurrentPage(v.key);
      if (picking) { pickColour(v, e); return; }
      if (editing) { commitText(); if (tool === "text") return; }
      if (tool === "tape") { taping = { view: v, pointerId: e.pointerId, start: p, end: p, client: { x: e.clientX, y: e.clientY }, moved: false }; return; }
      if (tool === "text") { startText(v, p); return; }
      if (selection && selection.view === v && tool === "lasso") {
        const handle = handleAt(v, p);
        const box = selectionBox();
        if (handle || (box && p.x >= box.x && p.x <= box.x + box.w && p.y >= box.y && p.y <= box.y + box.h)) {
          drag = { pointerId: e.pointerId, pointerType: e.pointerType, start: p, handle, box, t: null, client: { x: e.clientX, y: e.clientY } };
          return;
        }
        clearSelection();
      }
      if (selection) clearSelection();
      if (tool === "shape") { startShape(v, e, p); return; }
      if (tool === "lasso") { lasso = { view: v, pointerId: e.pointerId, pointerType: e.pointerType, points: [p], client: { x: e.clientX, y: e.clientY } }; return; }
      if (tool === "eraser") { startErase(v, e, p); return; }
      const pen = PEN_TOOLS.includes(tool);
      current = { view: v, pointerId: e.pointerId, pointerType: e.pointerType, start: e.timeStamp, points: [], tool, color: colorOf(tool), width: widthOf(tool),
        shape: null, anchor: { x: e.clientX, y: e.clientY }, client: { x: e.clientX, y: e.clientY },
        dash: pen ? prefs.dash[tool] ?? null : null, nib: null, filter: pen ? new PenFilter(inkSettings.pens[tool]) : null, raw: null, predicted: null,
        guide: pen ? guideSnap(v, p) : null };
      addPoint(e);
      armSnap();
      renderLive(v);
    });
    c.addEventListener("pointermove", (e) => {
      if (e.pointerType === "touch") noteTap(e, "move");
      if (touches.has(e.pointerId)) { touches.set(e.pointerId, { x: e.clientX, y: e.clientY }); movePinch(); e.preventDefault(); return; }
      if (guideDrag?.pointerId === e.pointerId) { moveGuide(toPage(v, e)); return; }
      if (shaping?.pointerId === e.pointerId) { moveShape(toPage(v, e), e); return; }
      if (guides.protractor && guides.view === v && e.pointerType !== "touch") {
        // The protractor reads the angle of wherever the pen or mouse is.
        const p = toPage(v, e), pr = guides.protractor;
        const near = Math.hypot(p.x - pr.x, p.y - pr.y) <= (pr.radius ?? 160) * 1.6;
        if (near || pr.reading) { pr.reading = near ? p : null; scheduleLive(v); }
      }
      if (erasing?.pointerId === e.pointerId) { for (const ev of coalesced(e)) eraseTo(v, toPage(v, ev)); return; }
      if (lasso?.pointerId === e.pointerId) {
        for (const ev of coalesced(e)) lasso.points.push(toPage(v, ev));
        lasso.client = { x: e.clientX, y: e.clientY };
        scheduleLive(v);
        return;
      }
      if (drag?.pointerId === e.pointerId) { moveDrag(v, toPage(v, e)); drag.client = { x: e.clientX, y: e.clientY }; return; }
      if (taping?.pointerId === e.pointerId) {
        taping.end = toPage(v, e);
        if (Math.hypot(e.clientX - taping.client.x, e.clientY - taping.client.y) > 4) taping.moved = true;
        scheduleLive(v);
        return;
      }
      if (current?.pointerId !== e.pointerId) {
        if (tool === "eraser" && e.pointerType !== "touch") { hover = { view: v, ...toPage(v, e) }; scheduleLive(v); }
        return;
      }
      if (current.shape) return; // snapped: lift to keep it
      for (const ev of coalesced(e)) addPoint(ev);
      predict(e);
      if (!current.inputAt) current.inputAt = e.timeStamp;
      if (Math.hypot(e.clientX - current.anchor.x, e.clientY - current.anchor.y) > 4) { current.anchor = { x: e.clientX, y: e.clientY }; armSnap(); }
      scheduleLive(v);
    });
    const end = (e) => {
      if (e.pointerType === "touch") noteTap(e, "up");
      if (touches.delete(e.pointerId)) { startPinch(); if (!touches.size && swipe.dx) finishSwipe(); return; }
      if (guideDrag?.pointerId === e.pointerId) { guideDrag = null; return; }
      if (shaping?.pointerId === e.pointerId) { finishShape(e.type === "pointercancel"); return; }
      if (erasing?.pointerId === e.pointerId) { finishErase(); return; }
      if (lasso?.pointerId === e.pointerId) { finishLasso(); return; }
      if (drag?.pointerId === e.pointerId) { finishDrag(e.type === "pointercancel"); return; }
      if (taping?.pointerId === e.pointerId) { finishTape(e.type === "pointercancel"); return; }
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

  /** A pointer event as a raw point: page position, pressure and, for a pen that reports its twist (barrel roll), the nib's angle. */
  function rawPoint(v, e) {
    const { x, y } = toPage(v, e);
    let p = e.pointerType === "mouse" ? 0.5 : e.pressure;
    if (e.pointerType === "touch" && (!p || p === 1)) p = 0.5; // most touch screens don't report force
    if (e.pointerType === "pen" && !p) p = 0.05;
    const pt = { x, y, p: Math.max(0, Math.min(1, p)), t: Math.max(0, e.timeStamp - current.start) };
    // A pen that turns in the hand (Apple Pencil Pro, some tablets) turns the fountain pen's nib.
    if (e.pointerType === "pen" && e.twist && (current.tool === "fountain" || current.tool === "brush")) pt.a = ((Math.PI / 4 + (e.twist * Math.PI) / 180) % Math.PI + Math.PI) % Math.PI;
    return pt;
  }

  /** Adds where the pointer is, through the pen's settings (stabiliser, pressure curve), so what's stored is what's shown. */
  function addPoint(e) {
    const v = current.view;
    current.client = { x: e.clientX, y: e.clientY };
    const raw = rawPoint(v, e);
    const minGap = 0.6 / cssScale(v); // ~0.6 screen pixels
    const last = current.points.at(-1);
    if (current.raw && Math.hypot(current.raw.x - raw.x, current.raw.y - raw.y) < minGap) {
      if (last) last.p = Math.max(last.p, current.filter ? pressureAfter(raw.p, current.filter.settings) : raw.p);
      return;
    }
    current.raw = raw;
    current.points.push(alongGuide(current.filter ? current.filter.add(raw) : raw));
  }

  /** A point moved onto the ruler's edge or the protractor's arc when the stroke started there. */
  const alongGuide = (pt) => onGuide(current?.guide, pt);
  function onGuide(g, pt) {
    if (!g) return pt;
    if (g.kind === "ruler") return guides.ruler ? onRulerEdge(guides.ruler, g.edge, pt) : pt;
    return guides.protractor ? onArc(guides.protractor, pt) : pt;
  }

  /** The guide edge a pen put down at `p` draws along: {kind: "ruler", edge} or {kind: "arc"}, or null. */
  function guideSnap(v, p) {
    if (guides.view !== v) return null;
    const tol = GUIDE_SNAP_PX / cssScale(v);
    if (guides.ruler) { const edge = rulerEdge(guides.ruler, p, tol); if (edge) return { kind: "ruler", edge }; }
    if (guides.protractor && onProtractorArc(guides.protractor, p, tol)) return { kind: "arc" };
    return null;
  }

  /** The browser's guess at the next point or two (drawn this frame only), from where the pen is heading. */
  function predict(e) {
    current.predicted = null;
    const list = e.getPredictedEvents?.();
    if (!list?.length || current.filter?.settings.smoothing) return;
    const last = current.points.at(-1);
    const out = [];
    for (const ev of list.slice(0, 2)) {
      const p = rawPoint(current.view, ev);
      // Never further than about 30 screen pixels ahead.
      if (last && Math.hypot(p.x - last.x, p.y - last.y) * cssScale(current.view) > 30) break;
      out.push(alongGuide({ ...p, p: last?.p ?? p.p }));
    }
    current.predicted = out.length ? out : null;
  }

  /**
   * Holding the pen still at the end of a stroke turns it into a clean shape (a highlighter into a
   * straight line, from where it started to where it is).
   */
  function armSnap() {
    clearTimeout(armSnap.timer);
    const s = current;
    armSnap.timer = setTimeout(() => {
      if (current !== s || !s || s.shape || s.points.length < 3 || s.tool === "laser" || s.guide) return;
      const shape = s.tool === "highlighter" ? straightLine(s.points) : recognizeShape(s.points);
      if (!shape) return;
      s.points = shape.points;
      s.shape = shape.shape;
      s.predicted = null;
      renderLive(s.view);
    }, HOLD_TO_SNAP_MS);
  }

  /** A highlighter held still: a straight line from its start to where it is. */
  function straightLine(pts) {
    const a = pts[0], b = pts.at(-1);
    if (Math.hypot(b.x - a.x, b.y - a.y) < 4) return null;
    const p = pts.reduce((n, q) => n + q.p, 0) / pts.length;
    return { shape: "line", points: [{ x: a.x, y: a.y, p, t: 0 }, { x: b.x, y: b.y, p, t: b.t }] };
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
    s.predicted = null;
    if (!s.shape && s.filter && s.raw) { const end = s.filter.end(s.raw); if (end) s.points.push(onGuide(s.guide, end)); }
    // A tap on tape (any pen) opens or covers it again instead of leaving a dot.
    const tapped = s.tool !== "laser" && isTap(s) ? tapeAt(s.view, s.points[0]) : null;
    if (tapped) { togglePeek(s.view, tapped); renderLive(s.view); return; }
    if (s.tool === "laser") {
      // Never saved: it fades away.
      lasers.push({ view: s.view, points: s.points, color: s.color, width: s.width, end: performance.now() });
      animateLasers();
      return;
    }
    if (!s.shape && prefs.scribble && s.tool !== "highlighter") {
      const targets = scribbleTargets(s.points, strokesNear(s.view, bounds(s.points, 4)));
      if (targets) {
        vault.deleteStrokes(targets);
        record({ remove: targets.map((id) => [id, "stroke"]) }, [s.view]);
        s.view.dirty = true;
        renderView(s.view);
        return;
      }
    }
    if (!s.shape && prefs.shapes && !s.guide) {
      // A highlighter only ever snaps to a straight line.
      const shape = recognizeShape(s.points);
      if (shape && (s.tool !== "highlighter" || shape.shape === "line")) { s.points = shape.points; s.shape = shape.shape; }
    }
    // The pen's lines: dashes on any stroke, arrows on straight lines, fill inside closed shapes.
    const style = { dash: s.dash };
    if (s.shape && s.tool !== "highlighter" && prefs.arrow && prefs.arrow !== "none" && (s.shape === "line" || s.shape === "polyline" || s.shape === "curve")) style.arrow = prefs.arrow;
    if (s.shape && prefs.fill && CLOSED_SHAPES.includes(s.shape)) style.fill = prefs.fill;
    const id = vault.addStroke({ on: itemId, layer, page: s.view.key, tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape, style });
    record({ add: [[id, "stroke"]] }, [s.view]);
    s.view.dirty = true;
    renderView(s.view);
  }

  /** A pen put down and lifted without really moving. */
  const isTap = (s) => { const b = bounds(s.points); return b && Math.max(b.w, b.h) * cssScale(s.view) < 4; };

  /** The tape strip under a point, the top one first. */
  function tapeAt(v, p) {
    return vault.elements(itemId, layer, v.key).reverse().find((e) => e.type === "tape" && elementContains(e, p)) ?? null;
  }

  function togglePeek(v, tape) {
    if (peeked.has(tape.id)) peeked.delete(tape.id); else peeked.add(tape.id);
    v.dirty = true;
    renderView(v);
  }

  /** Lays a strip of tape where it was dragged (a tap opens or covers the strip under it). */
  function finishTape(cancelled) {
    const t = taping;
    taping = null;
    const v = t.view;
    if (cancelled) { renderLive(v); return; }
    if (!t.moved) {
      const under = tapeAt(v, t.start);
      if (under) togglePeek(v, under);
      renderLive(v);
      return;
    }
    const id = vault.addElement({ on: itemId, layer, page: v.key, type: "tape", frame: tapeBox(t.start, t.end, widthOf("tape")), color: colorOf("tape") });
    record({ add: [[id, "element"]] }, [v]);
    v.dirty = true;
    renderView(v);
  }

  /** The eyedropper: the colour of the page where it was tapped (ink, else paper or the file under it). */
  function pickColour(v, e) {
    picking = false;
    root.classList.remove("picking");
    eyedropper.setAttribute("aria-pressed", "false");
    const read = (canvas) => {
      const r = canvas.getBoundingClientRect();
      if (!r.width || !r.height) return null;
      const x = Math.floor(((e.clientX - r.left) / r.width) * canvas.width), y = Math.floor(((e.clientY - r.top) / r.height) * canvas.height);
      if (x < 0 || y < 0 || x >= canvas.width || y >= canvas.height) return null;
      try { return canvas.getContext("2d").getImageData(x, y, 1, 1).data; } catch { return null; }
    };
    const ink = read(v.ink), bg = read(v.bg);
    const px = ink && ink[3] > 40 ? ink : bg;
    if (!px) return;
    // Ink over paper: blend it on, as it looks.
    const a = ink && ink[3] > 40 && bg ? ink[3] / 255 : 1;
    const ch = (i) => Math.round(bg && a < 1 ? px[i] * a + bg[i] * (1 - a) : px[i]).toString(16).padStart(2, "0");
    const hex = `#${ch(0)}${ch(1)}${ch(2)}`;
    if (!PEN_TOOLS.includes(tool) && tool !== "text" && tool !== "tape" && !selection) setTool("pen");
    setColor(hex);
  }

  // ---------- eraser ----------
  /** In page points; the precise eraser is exactly its size, the others a little bigger to be easy to hit. */
  const eraserRadius = (v) => (prefs.eraser === "precise" ? Math.max(0.25, widthOf("eraserPrecise") / 2) : widthOf("eraser") / 2 + 4) / cssScale(v);

  // ---------- laser pointer ----------
  function animateLasers() {
    if (animateLasers.frame) return;
    const tick = () => {
      animateLasers.frame = 0;
      const now = performance.now();
      const touched = new Set(lasers.map((l) => l.view));
      lasers = lasers.filter((l) => now - l.end < LASER_FADE_MS);
      for (const v of touched) renderLive(v);
      if (lasers.length) animateLasers.frame = requestAnimationFrame(tick);
    };
    animateLasers.frame = requestAnimationFrame(tick);
  }
  /** Laser lines on a page, fading out after the pen lifts. */
  function lasersOn(v, ctx = null) {
    const now = performance.now();
    for (const l of lasers) {
      if (l.view !== v) continue;
      const c = ctx ?? v.live.getContext("2d");
      c.save();
      c.globalAlpha = Math.max(0, 1 - (now - l.end) / LASER_FADE_MS);
      c.shadowColor = l.color;
      c.shadowBlur = 12;
      drawStroke(c, { tool: "marker", color: l.color, width: l.width / cssScale(v) * 1.5, points: l.points });
      c.restore();
    }
  }

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
    let changed = false;
    if (prefs.eraser === "partial" || prefs.eraser === "precise") {
      const near = new Set(strokesNear(v, bounds(path, eraserRadius(v))).map((s) => s.id));
      const made = near.size ? vault.eraseStrokes({ on: itemId, layer, page: v.key, path, radius: eraserRadius(v), only, near }) : [];
      for (const id of made) g.added.add(id);
      // What disappeared: originals and pieces made earlier in this gesture.
      const alive = new Set(vault.strokes(itemId, layer, v.key).map((s) => s.id));
      for (const id of [...g.before, ...g.added]) if (!alive.has(id) && !g.removed.has(id)) { g.removed.add(id); changed = true; }
      if (made.length) changed = true;
    } else {
      const near = strokesNear(v, bounds(path, eraserRadius(v)));
      const gone = near.filter((s) => (!only || only.includes(s.tool)) && (hits(s, p.x, p.y, eraserRadius(v))
        || (path[0] && segmentHits(s, path[0], p, eraserRadius(v)))));
      if (gone.length) { vault.deleteStrokes(gone.map((s) => s.id)); for (const s of gone) g.removed.add(s.id); changed = true; }
    }
    // Redraw the ink only when something was erased, once per frame; the eraser's circle moves on its own layer.
    if (changed) { v.dirty = true; scheduleView(v); } else scheduleLive(v);
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
  /** What the lasso may pick (the "Picks" choice): strokes, and which elements. */
  const picksStrokes = () => prefs.lassoKinds === "all" || prefs.lassoKinds === "ink";
  const picksElement = (e) => prefs.lassoKinds === "all" || (prefs.lassoKinds === "text" ? e.type === "text" : prefs.lassoKinds === "pictures" && e.type !== "text");

  /** Everything on a page as [{id, group}], for growing a selection to whole groups. */
  const pageMembers = (v) => [...vault.strokes(itemId, layer, v.key), ...vault.elements(itemId, layer, v.key)].map((x) => ({ id: x.id, group: x.group }));

  /** The loop's picks, grown to whole groups; or, for a tap, the top thing under it. */
  function finishLasso() {
    const l = lasso;
    lasso = null;
    const v = l.view;
    const b = bounds(l.points);
    if (l.points.length < 3 || Math.max(b.w, b.h) * cssScale(v) < 6) { selectIds(v, pickAt(v, l.points[0])); renderLive(v); return; }
    const strokes = picksStrokes() ? strokesNear(v, b).filter((s) => lassoSelects(s.points, l.points)).map((s) => s.id) : [];
    const elements = vault.elements(itemId, layer, v.key).filter((e) => picksElement(e) && lassoSelectsBox(boxOf(e), l.points)).map((e) => e.id);
    selectIds(v, [...strokes, ...elements]);
    renderLive(v);
  }

  /** The top stroke or element under a point (a tap with the lasso), as ids with its group. */
  function pickAt(v, p) {
    const r = 6 / cssScale(v);
    const el = vault.elements(itemId, layer, v.key).reverse().find((e) => picksElement(e) && elementContains(e, p, e.type === "text" ? textHeight(e) : e.h));
    const st = picksStrokes() ? strokesNear(v, { x: p.x - r, y: p.y - r, w: 2 * r, h: 2 * r }).reverse().find((s) => hits(s, p.x, p.y, r)) : null;
    const id = el?.type === "text" || el?.type === "tape" ? el.id : st?.id ?? el?.id;
    return id ? [id] : [];
  }

  const boxOf = (e) => elementBounds(e.type === "text" ? { ...e, h: textHeight(e) } : e);

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
  /** The turning handle: above the middle of the top edge. */
  const rotateHandle = (b, px) => [b.x + b.w / 2, b.y - 26 * px];

  /** The selection when it's one clean shape on its own (it shows its own handles). */
  function singleShape() {
    if (!selection || selection.strokes.size !== 1 || selection.elements.size) return null;
    const [id] = selection.strokes;
    const s = vault.strokes(itemId, layer, selection.view.key).find((x) => x.id === id);
    return s?.shape ? s : null;
  }
  function selectedShapeHandles(edit = null) {
    const s = singleShape();
    // A connector follows what it joins, so it has no handles of its own.
    return s && !s.from && !s.to ? shapeHandles(edit ?? s) : [];
  }

  /** The handle under a point: a shape's own ({shape: i}), the turning one ({rotate}) or a corner ({index}). */
  function handleAt(v, p) {
    const box = selectionBox();
    if (!box) return null;
    const px = 1 / cssScale(v), r = 14 * px;
    const own = selectedShapeHandles().findIndex((q) => Math.hypot(q.x - p.x, q.y - p.y) <= r);
    if (own >= 0) return { shape: own };
    const [rx, ry] = rotateHandle(box, px);
    if (Math.hypot(rx - p.x, ry - p.y) <= r) return { rotate: true };
    const i = corners(box).findIndex(([x, y]) => Math.hypot(x - p.x, y - p.y) <= r);
    return i < 0 ? null : { index: i };
  }

  function moveDrag(v, p) {
    const d = drag;
    if (d.handle?.shape !== undefined) {
      // Dragging a shape's own handle: an end, a corner, or the middle of a line to bend it.
      const s = singleShape();
      if (!s) return;
      const moved = moveShapeHandle(s, d.handle.shape, p);
      d.shapeEdit = { ...s, cache: null, shape: moved.shape, points: moved.points, handle: d.handle.shape };
      d.t = null;
    } else if (d.handle?.rotate) {
      const cx = d.box.x + d.box.w / 2, cy = d.box.y + d.box.h / 2;
      const a = Math.atan2(p.y - cy, p.x - cx) - Math.atan2(d.start.y - cy, d.start.x - cx);
      d.turning = true;
      d.t = rotateAbout(snapRotation(a), cx, cy);
    } else if (d.handle) {
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
    if (!cancelled && d.shapeEdit) {
      const id = d.shapeEdit.id, links = vault.connectorsOf(itemId, layer, v.key, [id]);
      const before = snapshot([id, ...links], []);
      vault.setStrokeShape(id, d.shapeEdit.shape, d.shapeEdit.points);
      vault.rerouteConnectors(links);
      record({ before, after: snapshot([id, ...links], []) }, [v]);
    } else if (!cancelled && d.t && (d.t.dx || d.t.dy || d.t.sx !== 1 || d.t.sy !== 1 || d.t.r)) {
      transformSelection(d.t, false);
    }
    v.dirty = true;
    renderView(v);
  }

  /**
   * Moves, resizes, turns or flips the selection with one transform (core/ink.js transformPoint),
   * then brings connectors joined to it back onto what they join. One undo step.
   */
  function transformSelection(t, redraw = true) {
    if (!selection) return;
    const v = selection.view;
    const ids = [...selection.strokes], els = [...selection.elements];
    const picked = [...ids, ...els];
    const own = vault.strokes(itemId, layer, v.key).filter((s) => selection.strokes.has(s.id) && (s.from || s.to)).map((s) => s.id);
    const links = [...new Set([...vault.connectorsOf(itemId, layer, v.key, picked), ...own])];
    const strokesTouched = [...new Set([...ids, ...links])];
    const before = snapshot(strokesTouched, els);
    vault.transformStrokes(ids, { t });
    vault.transformElements(els, t);
    vault.rerouteConnectors(links);
    record({ before, after: snapshot(strokesTouched, els) }, [v]);
    if (redraw) { v.dirty = true; renderView(v); }
  }

  /** The middle of the selection's box. */
  function selectionCentre() {
    const b = selectionBox();
    return b ? [b.x + b.w / 2, b.y + b.h / 2] : null;
  }
  function turnSelection(r) { const c = selectionCentre(); if (c) transformSelection(rotateAbout(r, c[0], c[1])); }
  function flipSelection(axis) { const c = selectionCentre(); if (c) transformSelection(flipAbout(axis, c[0], c[1])); }

  /** Straighten: turns slanted writing level (or upright) about its middle. */
  function straightenSelection() {
    if (!selection) return;
    const pts = vault.strokes(itemId, layer, selection.view.key).filter((s) => selection.strokes.has(s.id)).flatMap((s) => s.points);
    const r = straightenAngle(pts);
    if (Math.abs(r) > 1e-4) turnSelection(r);
  }

  /** Bring to front (`front`) or send to back, keeping the picked things' own order. */
  function arrangeSelection(front) {
    if (!selection) return;
    const v = selection.view, picked = [...selection.strokes, ...selection.elements];
    const before = [...snapshotFields([...selection.strokes], "stroke", ["createdAt"]), ...snapshotFields([...selection.elements], "element", ["createdAt"])];
    vault.reorderInk(picked, front);
    record({ before, after: [...snapshotFields([...selection.strokes], "stroke", ["createdAt"]), ...snapshotFields([...selection.elements], "element", ["createdAt"])] }, [v]);
    v.dirty = true;
    renderView(v);
  }

  /** The selection's single group, if it's exactly one whole group. */
  function selectionGroup() {
    if (!selection) return "";
    const all = [...vault.strokes(itemId, layer, selection.view.key), ...vault.elements(itemId, layer, selection.view.key)]
      .filter((x) => selection.strokes.has(x.id) || selection.elements.has(x.id));
    const groups = new Set(all.map((x) => x.group));
    return groups.size === 1 && !groups.has("") ? [...groups][0] : "";
  }

  /** Groups the selection (picked and moved as one from then on), or ungroups it if it's one group. */
  function toggleGroup() {
    if (!selection) return;
    const v = selection.view, strokes = [...selection.strokes], els = [...selection.elements];
    if (strokes.length + els.length < 2 && !selectionGroup()) return;
    const before = [...snapshotFields(strokes, "stroke", ["group"]), ...snapshotFields(els, "element", ["group"])];
    vault.setInkGroup([...strokes, ...els], selectionGroup() ? "" : undefined);
    record({ before, after: [...snapshotFields(strokes, "stroke", ["group"]), ...snapshotFields(els, "element", ["group"])] }, [v]);
    refreshSelection();
  }

  /** Copy as image: the selection as a PNG on the clipboard (or downloaded where the browser can't). */
  async function copySelectionImage() {
    const box = selectionBox();
    if (!box) return;
    const v = selection.view, keep = { strokes: new Set(selection.strokes), elements: new Set(selection.elements) };
    const pad = 8, area = { x: box.x - pad, y: box.y - pad, w: box.w + 2 * pad, h: box.h + 2 * pad };
    const blob = await renderSelectionPNG(area, Math.min(4, Math.max(2, devicePixelRatio || 1)), (ctx) => drawPicked(ctx, v, keep));
    if (!blob) return;
    let copied = false;
    try {
      if (navigator.clipboard?.write && typeof ClipboardItem !== "undefined") { await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]); copied = true; }
    } catch { /* not allowed here */ }
    if (!copied) {
      const url = URL.createObjectURL(blob);
      const a = h("a", { href: url, download: `${(title || "Drawing").replace(/[\\/:*?"<>|]+/g, " ").trim() || "Drawing"} selection.png` });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    }
    root.dataset.copiedImage = String(blob.size);
    copyImageButton.textContent = copied ? "Copied" : "Saved";
    setTimeout(() => { copyImageButton.textContent = "Copy as image"; }, 1500);
  }

  /** Draws only the picked strokes and elements of a page, in their usual order. */
  function drawPicked(ctx, v, keep) {
    const els = vault.elements(itemId, layer, v.key).filter((e) => keep.elements.has(e.id));
    for (const e of els) if (e.type === "image" && e.image) {
      const b = pictureBitmap(vault, e.image).ready;
      if (b) withElementTransform(ctx, e, () => ctx.drawImage(b, e.x, e.y, e.w, e.h));
    }
    for (const s of vault.strokes(itemId, layer, v.key)) if (keep.strokes.has(s.id)) drawStroke(ctx, s);
    for (const e of els) if (e.type === "text") drawTextElement(ctx, e);
    for (const e of els) if (e.type === "tape") drawTapeElement(ctx, e, true);
  }

  /** What hook actions (Ask AI, Make flashcard, …) and Convert to text get about the selection. */
  function selectionInfo() {
    const v = selection.view, keep = { strokes: new Set(selection.strokes), elements: new Set(selection.elements) };
    const box = selectionBox();
    return {
      itemId, layer, page: v.key, box,
      strokes: vault.strokes(itemId, layer, v.key).filter((s) => keep.strokes.has(s.id)),
      elements: vault.elements(itemId, layer, v.key).filter((e) => keep.elements.has(e.id)),
      png: () => renderSelectionPNG({ x: box.x - 8, y: box.y - 8, w: box.w + 16, h: box.h + 16 }, 2, (ctx) => drawPicked(ctx, v, keep)),
    };
  }
  /** The choices of a hook action (Ask AI) as a menu. */
  function fillActionsPop(action) {
    actionsPop.replaceChildren(h("div", { class: "ink-pop-title", text: String(action.label) }),
      ...action.choices.map((c) => h("button", { type: "button", class: "secondary small", role: "menuitem", onclick: () => { closePops(); runSelectionAction(c); } }, String(c.label))));
  }
  async function runSelectionAction(action) {
    if (!selection) return;
    try { await action.run(selectionInfo()); } catch (e) { console.warn("selection action failed", e); }
  }
  /** Convert to text: the recogniser's words as a text box where the ink was (the ink stays, selected, to delete or keep). */
  async function convertSelection() {
    if (!selection || !extra.recognizeInk) return;
    const info = selectionInfo();
    let text = "";
    try { text = String(await extra.recognizeInk(info.strokes, info)).trim(); } catch { text = ""; }
    if (!text || !info.box) return;
    const v = selection.view;
    const size = widthOf("text");
    const frame = { x: info.box.x, y: info.box.y + info.box.h + 8, w: Math.max(120, info.box.w), h: size * 1.25 };
    const id = vault.addElement({ on: itemId, layer, page: v.key, type: "text", frame, text, size, color: colorOf("text"), style: prefs.textStyle });
    record({ add: [[id, "element"]] }, [v]);
    v.dirty = true;
    renderView(v);
  }

  const STROKE_FIELDS = ["points", "points2", "width", "color", "nib", "shape"], ELEMENT_FIELDS = ["x", "y", "w", "h", "size", "color", "text", "rotate", "flip", "font", "bold", "italic"];
  /** The fields a lasso edit changes, so undo can put them back (points it didn't have come back empty). */
  function snapshot(strokeIds, elementIds) {
    return [...snapshotFields(strokeIds, "stroke", STROKE_FIELDS), ...snapshotFields(elementIds, "element", ELEMENT_FIELDS)];
  }
  /** [id, kind, fields]: each named field as it is now; one it doesn't have comes back as its off value. */
  function snapshotFields(ids, kind, names) {
    const off = { points: "", points2: "", rotate: 0, flip: false, bold: false, italic: false, font: "sans", group: "", nib: null, shape: null };
    return ids.map((id) => {
      const f = vault.store.records.get(id)?.fields ?? {};
      return [id, kind, Object.fromEntries(names.filter((n) => n in f || n in off).map((n) => [n, n in f ? f[n] : off[n]]))];
    });
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

  /** Selects ids on a page, with the rest of their groups (switching to the lasso). */
  function selectIds(v, ids) {
    if (tool !== "lasso") setTool("lasso");
    const all = withGroups(ids, pageMembers(v));
    selection = all.length ? { view: v, strokes: new Set(all.filter((id) => !vault.element(id))), elements: new Set(all.filter((id) => vault.element(id))) } : null;
    refreshSelection();
    refreshToolbar();
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
        .map((s) => ({ tool: s.tool, color: s.color, width: s.width, shape: s.shape, points: s.points, style: strokeStyle(s), group: s.group })),
      elements: vault.elements(itemId, layer, v.key).filter((e) => selection.elements.has(e.id))
        .map((e) => ({ type: e.type, x: e.x, y: e.y, w: e.w, h: e.h, text: e.text, size: e.size, color: e.color, image: e.image, rotate: e.rotate, flip: e.flip,
          font: e.font, bold: e.bold, italic: e.italic, group: e.group })),
    };
    try { localStorage.setItem("trove.inkClipboard", JSON.stringify(inkClipboard)); } catch { /* too big or private mode */ }
    refreshToolbar();
  }

  /** Pastes what the lasso copied onto the page in view, a little down and right (copied groups become new groups). */
  function paste() {
    if (!inkClipboard) return;
    const v = viewByKey(currentKey) ?? views[0];
    if (!v) return;
    const t = moveBy(20, 20), groups = new Map();
    const groupOf = (g) => { if (!g) return ""; if (!groups.has(g)) groups.set(g, crypto.randomUUID().toLowerCase()); return groups.get(g); };
    const ids = [
      ...inkClipboard.strokes.map((s) => vault.addStroke({ on: itemId, layer, page: v.key, tool: s.tool, color: s.color, width: s.width, shape: s.shape,
        points: s.points.map((p) => transformPoint(t, p)), style: s.style ?? null, group: groupOf(s.group) })),
      ...inkClipboard.elements.map((e) => vault.addElement({ on: itemId, layer, page: v.key, type: e.type, frame: transformRect(t, e), text: e.text, size: e.size,
        color: e.color, image: e.image, style: { ...e, group: groupOf(e.group) } })),
    ].filter(Boolean);
    selectIds(v, ids);
    record({ add: ids.map((id) => [id, vault.element(id) ? "element" : "stroke"]) }, [v]);
  }

  function clearSelection() {
    if (!selection) return;
    const v = selection.view;
    selection = null;
    drag = null;
    refreshSelection();
    refreshTextGroup();
    renderView(v);
  }

  function refreshSelection() {
    selectionBar.hidden = !selection;
    if (selection) {
      const n = selection.strokes.size + selection.elements.size;
      selectionBar.querySelector(".ink-selcount").textContent = `${n} selected`;
      const grouped = Boolean(selectionGroup());
      groupButton.textContent = grouped ? "Ungroup" : "Group";
      groupButton.hidden = !grouped && n < 2;
    }
  }

  // ---------- the shape tool ----------
  /** Starts dragging out a shape (a connector joins what's under its ends). */
  function startShape(v, e, p) {
    const kind = prefs.shapeKind;
    shaping = { view: v, pointerId: e.pointerId, kind, start: p, end: p, from: kind === "connector" ? connectableAt(v, p) : null, preview: null };
  }

  /** The closed shape or element under a point that a connector can join. */
  function connectableAt(v, p) {
    const el = vault.elements(itemId, layer, v.key).reverse().find((e) => elementContains(e, p, e.type === "text" ? textHeight(e) : e.h));
    if (el) return el.id;
    const s = vault.strokes(itemId, layer, v.key).reverse().find((x) => connectable(x) && (() => { const b = bounds(x.points, x.width / 2); return b && p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h; })());
    return s?.id ?? null;
  }

  /** The stroke the shape tool would add now: {tool, color, width, shape, points, style, from, to}. */
  function shapeStroke(sh, square) {
    let end = sh.end;
    if (square && !["line", "arrow", "connector"].includes(sh.kind)) {
      const d = Math.max(Math.abs(end.x - sh.start.x), Math.abs(end.y - sh.start.y));
      end = { x: sh.start.x + Math.sign(end.x - sh.start.x || 1) * d, y: sh.start.y + Math.sign(end.y - sh.start.y || 1) * d };
    }
    const base = { tool: "pen", color: colorOf("shape"), width: widthOf("shape"), dash: prefs.dash.shape ?? null, cache: null };
    if (sh.kind === "line" || sh.kind === "arrow" || sh.kind === "connector") {
      const to = sh.kind === "connector" ? connectableAt(sh.view, end) : null;
      const boxOfId = (id) => (id ? vault.inkBox(id) : null);
      const [a, b] = sh.kind === "connector" ? connectorEnds(sh.start, end, boxOfId(sh.from), boxOfId(to)) : [sh.start, end];
      const arrow = sh.kind === "line" ? (prefs.arrow !== "none" ? prefs.arrow : null) : prefs.arrow === "both" ? "both" : "end";
      return { ...base, shape: "line", points: [{ ...a, p: 0.5, t: 0 }, { ...b, p: 0.5, t: 0 }], arrow, from: sh.from, to };
    }
    const points = shapePoints(sh.kind, sh.start, end);
    return { ...base, shape: sh.kind, points, fill: prefs.fill && CLOSED_SHAPES.includes(sh.kind) ? prefs.fill : null };
  }

  function moveShape(p, e) {
    shaping.end = p;
    shaping.square = e.shiftKey;
    shaping.preview = shapeStroke(shaping, e.shiftKey);
    scheduleLive(shaping.view);
  }

  function finishShape(cancelled) {
    const sh = shaping;
    shaping = null;
    const v = sh.view;
    const small = Math.hypot(sh.end.x - sh.start.x, sh.end.y - sh.start.y) * cssScale(v) < 6;
    if (cancelled || small) { renderLive(v); return; }
    const s = shapeStroke(sh, sh.square);
    const id = vault.addStroke({ on: itemId, layer, page: v.key, tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape,
      style: { dash: s.dash, arrow: s.arrow, fill: s.fill }, from: s.from ?? "", to: s.to ?? "" });
    record({ add: [[id, "stroke"]] }, [v]);
    v.dirty = true;
    renderView(v);
  }

  // ---------- ruler and protractor (this device only) ----------
  function toggleGuide(kind) {
    if (guides[kind]) {
      guides[kind] = null;
    } else {
      const v = viewByKey(currentKey) ?? views[0];
      if (!v) return;
      // Where the page is on screen, so it shows up in view.
      const sr = scroller.getBoundingClientRect(), er = v.el.getBoundingClientRect();
      const mid = toPage(v, { clientX: Math.max(er.left, Math.min(er.right, sr.left + sr.width / 2)), clientY: Math.max(er.top, Math.min(er.bottom, sr.top + sr.height / 2)) });
      if (guides.view && guides.view !== v) { guides.ruler = null; guides.protractor = null; renderLive(guides.view); }
      guides.view = v;
      guides[kind] = kind === "ruler" ? { x: mid.x, y: mid.y, angle: -Math.PI / 12 } : { x: mid.x, y: mid.y + 80, angle: 0, reading: null };
    }
    if (!guides.ruler && !guides.protractor) { const v = guides.view; guides.view = null; if (v) renderLive(v); }
    if (guides.view) renderLive(guides.view);
    refreshToolbar();
  }

  /** Moving a guide with its body, or turning it about its centre with a knob (snapping to 15° steps). */
  function moveGuide(p) {
    const d = guideDrag, g = guides[d.kind];
    if (!g) return;
    if (d.turn) {
      const a = Math.atan2(p.y - d.y, p.x - d.x) - d.grab;
      g.angle = snapRotation(d.angle + a);
    } else {
      g.x = d.x + p.x - d.start.x;
      g.y = d.y + p.y - d.start.y;
    }
    scheduleLive(d.view);
  }

  // ---------- the elements library ----------
  /** The library: built-in and saved elements by folder; a tap puts one on the page. `save` shows the form to save the selection. */
  function refreshElementsPop(save = false) {
    const list = vault.stickers();
    const parts = [];
    if (save && selection) {
      const folders = [...new Set(list.filter((x) => !x.builtin && x.folder).map((x) => x.folder))].sort();
      const name = h("input", { type: "text", class: "ink-element-name", "aria-label": "Name", placeholder: "Name", maxlength: "80" });
      const folder = h("input", { type: "text", class: "ink-element-folder", "aria-label": "Folder", placeholder: "Folder (optional)", maxlength: "80", list: "ink-element-folders" });
      const save = () => {
        if (!selection) return;
        const v = selection.view;
        vault.addSticker({ name: name.value.trim() || "Element", folder: folder.value.trim(),
          strokes: vault.strokes(itemId, layer, v.key).filter((s) => selection.strokes.has(s.id)),
          elements: vault.elements(itemId, layer, v.key).filter((e) => selection.elements.has(e.id)) });
        changed();
        refreshElementsPop();
      };
      name.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") save(); });
      folder.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") save(); });
      parts.push(h("div", { class: "ink-pop-title", text: "Save the selection as an element" }),
        h("div", { class: "ink-pop-row" }, name, folder, h("datalist", { id: "ink-element-folders" }, folders.map((f) => h("option", { value: f }))),
          h("button", { type: "button", class: "primary small", onclick: save }, "Save")),
        h("p", { class: "hint", text: "Saved elements are on every device, in this library." }));
      requestAnimationFrame(() => name.focus());
    }
    const byFolder = new Map();
    for (const x of list) {
      const key = x.builtin ? `Trove: ${x.folder}` : x.folder || "Yours";
      if (!byFolder.has(key)) byFolder.set(key, []);
      byFolder.get(key).push(x);
    }
    const drawPicture = (ctx, e) => { const b = e.image && pictureBitmap(vault, e.image).ready; if (b) withElementTransform(ctx, e, () => ctx.drawImage(b, e.x, e.y, e.w, e.h)); };
    for (const [folder, items] of byFolder) {
      parts.push(h("div", { class: "ink-pop-title", text: folder }),
        h("div", { class: "ink-elements" }, items.map((x) => h("span", { class: "ink-element" },
          h("button", { type: "button", class: "ink-element-use", title: `Put ${x.name} on the page`, "aria-label": x.name, onclick: () => placeElement(x) },
            stickerCanvas(x, 56, drawPicture), h("span", { text: x.name })),
          x.builtin ? null : h("button", { type: "button", class: "ink-chip-x", "aria-label": `Delete ${x.name}`, title: "Delete",
            onclick: () => { if (confirm(`Delete “${x.name}” from your elements?`)) { vault.deleteSticker(x.id); changed(); refreshElementsPop(); } } }, lineIcon("close"))))));
    }
    if (!save) parts.push(h("p", { class: "hint", text: "Select something with the lasso, then Save as element to keep it here." }));
    elementsPop.replaceChildren(...parts);
  }

  function openSaveElement(anchor) {
    if (openPop === elementsPop) closePops();
    togglePop(elementsPop, anchor, () => refreshElementsPop(true));
  }

  /** Puts a library element in the middle of what's in view, selected so it can be moved straight away. */
  function placeElement(sticker) {
    const v = viewByKey(currentKey) ?? views[0];
    if (!v) return;
    const sr = scroller.getBoundingClientRect(), er = v.el.getBoundingClientRect();
    const at = toPage(v, { clientX: Math.max(er.left, Math.min(er.right, sr.left + sr.width / 2)), clientY: Math.max(er.top, Math.min(er.bottom, sr.top + sr.height / 2)) });
    const ids = vault.placeSticker(sticker, { on: itemId, layer, page: v.key, at });
    if (!ids.length) return;
    closePops();
    record({ add: ids.map((id) => [id, vault.element(id) ? "element" : "stroke"]) }, [v]);
    selectIds(v, ids);
    v.dirty = true;
    renderView(v);
  }

  // ---------- text boxes ----------
  function textAt(v, p) {
    return vault.elements(itemId, layer, v.key).reverse().find((e) => e.type === "text" && elementContains(e, p, textHeight(e))) ?? null;
  }

  /** The text style the options show: the box being typed in, else the selected text box, else the next box's. */
  function currentTextStyle() {
    if (editing) return editing.frame;
    const sel = selectedTextBoxes();
    return sel.length ? sel[0] : prefs.textStyle;
  }
  const selectedTextBoxes = () => (selection ? [...selection.elements].map((id) => vault.element(id)).filter((e) => e?.type === "text") : []);

  function refreshTextGroup() {
    const show = tool === "text" || Boolean(editing) || selectedTextBoxes().length > 0;
    textGroup.hidden = !show;
    if (!show) return;
    const st = currentTextStyle();
    fontSelect.value = TEXT_FONTS.includes(st.font) ? st.font : "sans";
    boldButton.setAttribute("aria-pressed", String(Boolean(st.bold)));
    italicButton.setAttribute("aria-pressed", String(Boolean(st.italic)));
  }

  /** Font, bold or italic: on the box being typed in, the selected text boxes, and the next new box. */
  function applyTextStyle(change) {
    prefs.textStyle = { ...prefs.textStyle, ...change };
    savePrefs(prefs);
    if (editing) {
      Object.assign(editing.frame, change);
      editing.place();
      editing.area.focus();
    } else if (selectedTextBoxes().length) {
      const ids = selectedTextBoxes().map((e) => e.id);
      const before = snapshot([], ids);
      for (const id of ids) vault.updateElement(id, { style: change });
      for (const id of ids) { const e = vault.element(id); vault.updateElement(id, { frame: { x: e.x, y: e.y, w: e.w, h: textHeight(e) } }); }
      record({ before, after: snapshot([], ids) }, [selection.view]);
    }
    refreshTextGroup();
  }

  /** Bullets on the lines the cursor is in (or off, when they all have them). */
  function toggleBullets() {
    if (!editing) { if (tool !== "text") setTool("text"); return; }
    const area = editing.area, text = area.value;
    const from = text.lastIndexOf("\n", area.selectionStart - 1) + 1;
    let to = text.indexOf("\n", area.selectionEnd);
    if (to < 0) to = text.length;
    const lines = text.slice(from, to).split("\n");
    const on = !lines.every((l) => l.startsWith("• "));
    const next = lines.map((l) => (on ? (l.startsWith("• ") ? l : `• ${l}`) : l.replace(/^• /, ""))).join("\n");
    area.value = text.slice(0, from) + next + text.slice(to);
    area.selectionStart = area.selectionEnd = from + next.length;
    editing.place();
    area.focus();
  }

  /** Types in a text box: the one under the point, or a new one there (in the font and style chosen). */
  function startText(v, p, existing = textAt(v, p)) {
    const k = cssScale(v);
    const width = existing ? existing.w : v.infinite ? 320 : Math.max(120, Math.min(360, v.spec.width - p.x - 16));
    const e = existing ? { ...existing } : { x: p.x, y: p.y - widthOf("text") * 0.6, w: width, h: widthOf("text") * 1.25, size: widthOf("text"), color: colorOf("text"), text: "",
      rotate: 0, font: prefs.textStyle.font, bold: Boolean(prefs.textStyle.bold), italic: Boolean(prefs.textStyle.italic) };
    const area = h("textarea", { class: "ink-textbox", "aria-label": "Text box", spellcheck: "true" });
    area.value = e.text;
    const place = () => {
      const left = v.infinite ? (e.x - v.ox) * k : e.x * k, top = v.infinite ? (e.y - v.oy) * k : e.y * k;
      area.style.cssText = `left:${left}px;top:${top}px;width:${e.w * k}px;font:${textFont(e.size * k, e)};line-height:1.25;color:${e.color}`;
      area.style.height = "auto";
      area.style.height = `${Math.max(e.size * 1.25 * k, area.scrollHeight)}px`;
      // A turned box is typed in turned, about the same centre it's drawn about.
      if (e.rotate) { area.style.transformOrigin = `${(e.w * k) / 2}px ${(e.h * k) / 2}px`; area.style.transform = `rotate(${e.rotate}rad)`; }
    };
    area.addEventListener("input", place);
    area.addEventListener("keydown", (ev) => {
      if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); commitText(); return; }
      const mod = ev.metaKey || ev.ctrlKey;
      if (mod && ev.key.toLowerCase() === "b") { ev.preventDefault(); applyTextStyle({ bold: !e.bold }); }
      else if (mod && ev.key.toLowerCase() === "i") { ev.preventDefault(); applyTextStyle({ italic: !e.italic }); }
      else if (ev.key === "Enter" && !ev.shiftKey) {
        // A bullet line continues the list; an empty bullet ends it.
        const start = area.value.lastIndexOf("\n", area.selectionStart - 1) + 1, line = area.value.slice(start, area.selectionStart);
        if (line.startsWith("• ")) {
          ev.preventDefault();
          if (line === "• ") { area.setRangeText("", start, area.selectionStart, "end"); }
          else area.setRangeText("\n• ", area.selectionStart, area.selectionEnd, "end");
          place();
        }
      }
      ev.stopPropagation();
    });
    // Picking a font or style keeps the box open; anywhere else closes it.
    area.addEventListener("blur", (ev) => {
      if (ev.relatedTarget?.closest?.(".ink-options")) return;
      setTimeout(() => { if (editing?.area === area && !document.activeElement?.closest?.(".ink-options")) commitText(); }, 0);
    });
    v.el.append(area);
    editing = { view: v, id: existing?.id ?? null, frame: e, area, place };
    place();
    v.dirty = true;
    renderView(v);
    refreshTextGroup();
    area.focus();
  }

  function commitText() {
    const ed = editing;
    if (!ed) return;
    editing = null;
    const text = ed.area.value.replace(/\s+$/, "");
    ed.area.remove();
    const v = ed.view;
    const style = { font: ed.frame.font, bold: Boolean(ed.frame.bold), italic: Boolean(ed.frame.italic) };
    if (ed.id) {
      const before = snapshot([], [ed.id]);
      const old = vault.element(ed.id);
      const restyled = old && (old.font !== style.font || old.bold !== style.bold || old.italic !== style.italic || old.color !== ed.frame.color);
      if (!text) {
        vault.deleteElements([ed.id]);
        record({ remove: [[ed.id, "element"]] }, [v]);
      } else if (text !== old?.text || restyled) {
        vault.updateElement(ed.id, { text, color: ed.frame.color, style, frame: { ...ed.frame, h: textHeight({ ...ed.frame, text }) } });
        record({ before, after: snapshot([], [ed.id]) }, [v]);
      }
    } else if (text) {
      const frame = { x: ed.frame.x, y: ed.frame.y, w: ed.frame.w, h: textHeight({ ...ed.frame, text }) };
      const id = vault.addElement({ on: itemId, layer, page: v.key, type: "text", frame, text, size: ed.frame.size, color: ed.frame.color, style });
      record({ add: [[id, "element"]] }, [v]);
    }
    v.dirty = true;
    renderView(v);
    refreshTextGroup();
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
      if (Math.abs(dist / pinch.dist - 1) > 0.04 || pinch.zooming) { pinch.zooming = true; setZoom(pinch.zoom * dist / pinch.dist, { x: cx, y: cy }, true); }
    } else if (pts.length === 1 && pinch.x !== undefined) {
      panBy(pinch.x - pts[0].x, pinch.y - pts[0].y);
      pinch.x = pts[0].x; pinch.y = pts[0].y;
    }
  }

  /** Scrolls the pages, or moves around the endless canvas, by CSS pixels. */
  function panBy(dx, dy) {
    if (canSwipe() && !pinch?.zooming && (swipe.dx || Math.abs(dx) > Math.abs(dy))) { swipeBy(dx); return; }
    if (infinite) {
      infinite.ox += dx / infinite.scale;
      infinite.oy += dy / infinite.scale;
      if (editing) commitText();
      renderView(infinite, true);
    } else scroller.scrollBy(dx, dy);
  }

  function setZoom(z, anchor = null, byHand = false) {
    if (byHand) zoomedByHand = true;
    const next = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));
    if (Math.abs(next - zoom) < 0.0005) { layout(); return; }
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
      setZoom(zoom * Math.exp(-e.deltaY / 300), { x: e.clientX, y: e.clientY }, true);
    } else if (infinite) {
      e.preventDefault();
      panBy(e.deltaX, e.deltaY);
    } else if (canSwipe() && Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      // A trackpad's sideways swipe turns the page.
      e.preventDefault();
      swipeBy(e.deltaX);
      clearTimeout(swipe.timer);
      swipe.timer = setTimeout(finishSwipe, 120);
    }
  }, { passive: false });

  // ---------- flip mode: swiping turns the page ----------
  const swipe = { dx: 0, timer: 0, until: 0 };
  /** In flip mode with the page's whole width in view, a sideways drag turns the page instead of scrolling. */
  const canSwipe = () => !infinite && prefs.layout === "flip" && scroller.scrollWidth <= scroller.clientWidth + 2;
  function swipeBy(dx) {
    if (performance.now() < swipe.until) return;
    swipe.dx += dx;
    const v = viewByKey(currentKey);
    if (v) v.el.style.transform = `translateX(${-swipe.dx * 0.6}px) rotateY(${Math.max(-25, Math.min(25, swipe.dx / 12))}deg)`;
  }
  function finishSwipe() {
    const v = viewByKey(currentKey);
    if (v) v.el.style.transform = "";
    const dx = swipe.dx;
    swipe.dx = 0;
    if (Math.abs(dx) > 70) { swipe.until = performance.now() + 450; flipBy(dx > 0 ? 1 : -1); }
  }

  let followFrame = 0;
  scroller.addEventListener("scroll", () => {
    if (infinite) return;
    if (!followFrame) followFrame = requestAnimationFrame(() => { followFrame = 0; refollow(); });
    if (prefs.layout === "flip") return;
    // The page most in view is the one new pages, pastes and pictures go on.
    const sr = scroller.getBoundingClientRect();
    const across = prefs.layout === "horizontal";
    const at = across ? sr.left + scroller.clientWidth / 3 : sr.top + scroller.clientHeight / 3;
    const v = views.find((x) => { const r = x.el.getBoundingClientRect(); return across ? r.left <= at && r.right >= at : r.top <= at && r.bottom >= at; });
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
    noteRecent(c);
    savePrefs(prefs);
    if (editing) { editing.frame.color = c; editing.area.style.color = c; }
    refreshToolbar();
  }

  function refreshToolbar() {
    toolButtons.forEach((b, i) => b.setAttribute("aria-pressed", String(Object.keys(TOOL_INFO)[i] === tool)));
    shapeButton.setAttribute("aria-pressed", String(prefs.shapes));
    const hasColor = PEN_TOOLS.includes(tool) || tool === "text" || tool === "laser" || tool === "tape" || tool === "shape";
    const c = hasColor ? colorOf(tool) : null;
    refreshSwatches(c);
    refreshFavourites();
    if (c) { custom.value = c; if (document.activeElement !== hexInput) hexInput.value = c; }
    root.querySelector(".ink-pen-group").hidden = !PEN_TOOLS.includes(tool) && tool !== "shape";
    favouriteButton.hidden = tool === "shape";
    shapeGroup.hidden = tool !== "shape";
    for (const b of shapeGroup.children) b.setAttribute("aria-checked", String(b.dataset.shape === prefs.shapeKind));
    lassoGroup.hidden = tool !== "lasso";
    for (const b of lassoGroup.querySelectorAll("[data-kinds]")) b.setAttribute("aria-checked", String(b.dataset.kinds === prefs.lassoKinds));
    refreshTextGroup();
    rulerButton.setAttribute("aria-pressed", String(Boolean(guides.ruler)));
    protractorButton.setAttribute("aria-pressed", String(Boolean(guides.protractor)));
    const sized = hasColor || tool === "eraser";
    root.querySelector(".ink-colors").hidden = !hasColor && !(tool === "lasso" && selection);
    root.querySelector(".ink-size-group").hidden = !sized;
    size.max = sizeKey() === "eraserPrecise" ? "12" : tool === "text" ? "72" : "60";
    size.value = String(sized ? widthOf(sizeKey()) : 10);
    const d = Math.max(3, Math.min(22, sized ? widthOf(sizeKey()) : 10));
    sizeDot.style.cssText = `width:${d}px;height:${d}px;background:${c ?? "transparent"};opacity:${tool === "highlighter" ? 0.5 : 1}`;
    eraserMode.value = prefs.eraser;
    highlighterOnly.firstChild.checked = prefs.highlighterOnly;
    root.querySelector(".ink-eraser-group").hidden = tool !== "eraser";
    undoButton.disabled = !undo.length;
    redoButton.disabled = !redo.length;
    pasteButton.hidden = !inkClipboard;
    root.dataset.tool = tool;
    toolName.textContent = TOOL_INFO[tool].label.split(":")[0];
    const options = hasColor || sized || tool === "lasso";
    const showOptions = options && prefs.options !== false;
    if (optionsBar.hidden === showOptions) { optionsBar.hidden = !showOptions; requestAnimationFrame(layout); }
    if (sketch) panelButton.hidden = item().infinite;
    panelButton?.setAttribute("aria-pressed", String(Boolean(prefs.panel)));
  }

  // ---------- the page panel ----------
  function setCurrentPage(key) {
    if (currentKey === key) return;
    currentKey = key;
    refreshPageCount();
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
        onclick: () => {
          const i = views.findIndex((v) => v.key === currentKey), j = views.findIndex((v) => v.key === spec.key);
          if (prefs.layout === "flip") { if (j !== i) flipBy(j - i); return; }
          setCurrentPage(spec.key);
          reveal(viewByKey(spec.key), true);
        } },
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
    const paper = h("select", { class: "folder-select", "aria-label": "This page's paper" },
      PAPER_GROUPS.map(([group, list]) => h("optgroup", { label: group }, list.map((p) => h("option", { value: p, text: PAPER_TITLES[p] })))));
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
    closePops();
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
      if (!zoomedByHand && !infinite) fitZoom(); else layout();
      if (focusKey && prefs.layout !== "flip") reveal(viewByKey(focusKey), true);
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
          const jpeg = await jpegOf(canvas);
          withElementTransform(ctx, e, () => ctx.drawJpeg(jpeg, canvas.width, canvas.height, e.x, e.y, e.w, e.h));
        }
        for (const s of vault.strokes(itemId, layer, spec.key)) drawStroke(ctx, s);
        for (const e of vault.elements(itemId, layer, spec.key)) if (e.type === "text") drawTextElement(ctx, e);
        for (const e of vault.elements(itemId, layer, spec.key)) if (e.type === "tape") drawTapeElement(ctx, e);
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
      const next = vault.inkSettings();
      if (JSON.stringify(next) !== JSON.stringify(inkSettings)) { inkSettings = next; refreshToolbar(); }
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
    else if (e.key === "Escape") { if (openPop) closePops(); else if (selection) clearSelection(); else close(); }
    else if (!mod && !e.altKey) {
      const id = Object.keys(TOOL_INFO).find((t) => TOOL_INFO[t].key === k);
      if (id) setTool(id);
      else if (k === "s") { prefs.shapes = !prefs.shapes; savePrefs(prefs); refreshToolbar(); }
      else if (e.key === "+" || e.key === "=") setZoom(zoom * 1.25, null, true);
      else if (e.key === "-") setZoom(zoom / 1.25, null, true);
      else if (e.key === "0") setZoom(1, null, true);
      else if (e.key === "ArrowRight" || e.key === "PageDown") { if (prefs.layout === "flip" || e.key === "PageDown") flipBy(1); else handled = false; }
      else if (e.key === "ArrowLeft" || e.key === "PageUp") { if (prefs.layout === "flip" || e.key === "PageUp") flipBy(-1); else handled = false; }
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
  // Turning the iPad or resizing the window keeps the page fitted (unless zoomed by hand).
  const onResize = () => { if (!zoomedByHand) fitZoom(); else layout(); };
  addEventListener("resize", onResize);

  function close() {
    if (editing) commitText();
    if (current) finishStroke();
    if (erasing) finishErase();
    io.disconnect();
    unsubscribe();
    document.removeEventListener("keydown", onKey, true);
    document.removeEventListener("paste", onPaste, true);
    document.removeEventListener("pointerdown", onOutside, true);
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
    if (infinite) layout(); else fitZoom();
    if (!infinite) reveal(viewByKey(currentKey));
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
