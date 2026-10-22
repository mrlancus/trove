// The PDF viewer (ROADMAP S5, PROTOCOL.md §10 "PDF text, highlights and forms"): pages render as they
// scroll into view with pdf.js's text layer, so text can be selected, highlighted (the words are
// saved with the highlight) and kept as a quote; find marks every hit; links work; forms can be
// filled (values are saved as elements, the file never changes); and the marks can be exported as
// real PDF annotations, downloaded or saved as a new version of the file.
import { h } from "./dom.js";
import { icon } from "./icons.js";
import { drawStrokes, drawTapeElement, drawTextElement, textFont, wrapText } from "./core/ink.js";
import { findAll, HIGHLIGHT_COLORS, highlightRects, joinPdfText, normalizePdfPage, PDF_TEXT_MAX, pageTextFromItems, pdfPageBox } from "./core/pdfmarks.js";

const PDFJS = "/vendor/pdfjs-4.10.38";
let pdfjs = null;
export async function loadPdfjs() {
  if (!pdfjs) {
    pdfjs = await import(`${PDFJS}/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `${PDFJS}/pdf.worker.min.mjs`;
  }
  return pdfjs;
}

export async function openPdf(bytes) {
  const lib = await loadPdfjs();
  // pdf.js takes ownership of the buffer, so give it a copy.
  return lib.getDocument({ data: bytes.slice(), isEvalSupported: false, useSystemFonts: true }).promise;
}

/** A PDF's text for search, the same as the apps write (`ocrText`, core/pdfmarks.js joinPdfText). */
export async function pdfText(bytes) {
  const doc = await openPdf(bytes);
  try {
    return await documentText(doc);
  } finally {
    doc.destroy();
  }
}

async function documentText(doc) {
  const pages = [];
  let total = 0;
  for (let n = 1; n <= doc.numPages && total <= PDF_TEXT_MAX; n++) {
    const text = pageTextFromItems((await (await doc.getPage(n)).getTextContent()).items);
    pages.push(text);
    total += Array.from(normalizePdfPage(text)).length + 2;
  }
  return joinPdfText(pages);
}

const COLOUR_NAMES = { "#ffd60a": "yellow", "#34c759": "green", "#0a84ff": "blue", "#ff6fae": "pink", "#ff9500": "orange" };
const pct = (v, of) => `${(v / of) * 100}%`;
const place = (r, box) => `left:${pct(r.x, box.width)};top:${pct(r.y, box.height)};width:${pct(r.w, box.width)};height:${pct(r.h, box.height)}`;

/** A PDF rect [x1, y1, x2, y2] in page points. */
function pageRect(rect, box) {
  const a = box.toPage([rect[0], rect[1]]), b = box.toPage([rect[2], rect[3]]);
  const x = Math.min(a[0], b[0]), y = Math.min(a[1], b[1]);
  return { x, y, w: Math.abs(b[0] - a[0]), h: Math.abs(b[1] - a[1]) };
}

/** The boxes of characters [a, b) of a pdf.js text item, in page points (proportional within the item). */
function itemBox(it, a, b, box) {
  const t = it.transform, len = it.str.length || 1;
  const fh = Math.hypot(t[2], t[3]) || it.height || 10;
  const dl = Math.hypot(t[0], t[1]) || 1, d = [t[0] / dl, t[1] / dl], n = [t[2] / fh, t[3] / fh];
  const s0 = (it.width * a) / len, s1 = (it.width * b) / len;
  const corners = [];
  for (const s of [s0, s1]) for (const u of [-0.22 * fh, 0.9 * fh]) corners.push(box.toPage([t[4] + d[0] * s + n[0] * u, t[5] + d[1] * s + n[1] * u]));
  const xs = corners.map((c) => c[0]), ys = corners.map((c) => c[1]);
  const x = Math.min(...xs), y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

/**
 * A scrolling PDF. `ink(page)` gives a page's strokes; `marks` (optional, see `pdfMarks`) holds the
 * file's highlights, text boxes and form values and saves changes to them. Returns the element, with
 * `refreshMarks()` to call when the marks may have changed (after a sync).
 */
export async function pdfViewer(bytes, { onExpand, ink, marks = null, fileName = "Document.pdf" } = {}) {
  const lib = await loadPdfjs();
  const doc = await openPdf(bytes);
  const count = doc.numPages;
  let zoom = 1;
  const pages = h("div", { class: "pdf-pages" });
  const root = h("div", { class: "pdf-viewer" });
  /** Per page (0-based): its box once loaded, its overlay (highlights, hits), its text for find. */
  const boxes = new Array(count).fill(null), overlays = [], texts = new Array(count).fill(null);
  let fieldValues = marks?.fields() ?? new Map();
  let hits = [], current = -1;

  const label = h("span", { class: "saved", text: `${count} page${count === 1 ? "" : "s"}` });
  const setZoom = (z) => { zoom = Math.min(4, Math.max(0.5, z)); pages.style.setProperty("--zoom", zoom); for (const p of pages.children) p.dataset.rendered = ""; observeAll(); };

  // ---------- find ----------
  const findInput = h("input", { type: "search", class: "pdf-find-input", placeholder: "Find in PDF", "aria-label": "Find in PDF", autocomplete: "off" });
  const findCount = h("span", { class: "saved pdf-find-count", "aria-live": "polite" });
  const findRow = h("div", { class: "pdf-find", hidden: true },
    icon("search"), findInput, findCount,
    h("button", { type: "button", class: "secondary small", "aria-label": "Previous", title: "Previous (Shift+Enter)", onclick: () => step(-1) }, icon("chevronUp")),
    h("button", { type: "button", class: "secondary small", "aria-label": "Next", title: "Next (Enter)", onclick: () => step(1) }, icon("chevronDown")),
    h("button", { type: "button", class: "secondary small", "aria-label": "Close find", onclick: () => toggleFind(false) }, icon("close")));
  let findTimer = null;
  findInput.addEventListener("input", () => { clearTimeout(findTimer); findTimer = setTimeout(runFind, 200); });
  findInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
    if (e.key === "Escape") { e.stopPropagation(); toggleFind(false); }
  });
  function toggleFind(open = findRow.hidden) {
    findRow.hidden = !open;
    if (open) { findInput.focus(); findInput.select(); } else { findInput.value = ""; hits = []; current = -1; findCount.textContent = ""; drawAllOverlays(); }
  }

  async function loadText(i) {
    if (texts[i]) return texts[i];
    const page = await doc.getPage(i + 1);
    boxes[i] ??= pdfPageBox(page.view, page.rotate);
    let text = "";
    const spans = [];
    for (const it of (await page.getTextContent()).items) {
      if (typeof it.str !== "string") continue;
      spans.push({ start: text.length, end: text.length + it.str.length, it });
      text += it.str;
      if (it.hasEOL) text += "\n";
    }
    return (texts[i] = { text, spans });
  }

  async function runFind() {
    const q = findInput.value;
    hits = [];
    current = -1;
    if (q.trim()) {
      findCount.textContent = "Searching…";
      for (let i = 0; i < count; i++) {
        const { text, spans } = await loadText(i);
        if (findInput.value !== q) return; // typed on
        for (const [s, e] of findAll(text, q)) {
          const rects = spans.filter((sp) => sp.end > s && sp.start < e && sp.it.str.length)
            .map((sp) => itemBox(sp.it, Math.max(s, sp.start) - sp.start, Math.min(e, sp.end) - sp.start, boxes[i]));
          if (rects.length) hits.push({ page: i, rects });
        }
      }
    }
    findCount.textContent = !q.trim() ? "" : hits.length ? `${hits.length} found` : "Not found";
    drawAllOverlays();
    if (hits.length) step(1);
  }

  function step(dir) {
    if (!hits.length) return;
    current = (current + dir + hits.length) % hits.length;
    findCount.textContent = `${current + 1} of ${hits.length}`;
    drawAllOverlays();
    pages.querySelector(".pdf-hit.current")?.scrollIntoView({ block: "center" });
  }

  // ---------- the bar ----------
  const exportMenu = h("div", { class: "pdf-menu", hidden: true, role: "menu" },
    h("button", { type: "button", role: "menuitem", onclick: () => exportAnnotated(false) }, "Download with annotations"),
    marks?.saveVersion ? h("button", { type: "button", role: "menuitem", onclick: () => exportAnnotated(true) }, "Save as a new version") : null,
    h("p", { class: "hint", text: "Ink, highlights, text boxes and form values become PDF annotations other apps can edit. To flatten instead, use Draw on it, then Export PDF." }));
  const exportButton = h("button", { type: "button", class: "secondary small", "aria-haspopup": "menu", onclick: () => { exportMenu.hidden = !exportMenu.hidden; } }, "Export");
  const bar = h("div", { class: "viewer-bar" }, label, h("span", { class: "spacer" }),
    h("button", { type: "button", class: "secondary small", "aria-label": "Find in PDF", title: "Find in PDF", onclick: () => toggleFind() }, icon("search")),
    marks ? exportButton : null,
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom out", onclick: () => setZoom(zoom / 1.25) }, "−"),
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom in", onclick: () => setZoom(zoom * 1.25) }, "+"),
    onExpand ? h("button", { type: "button", class: "secondary small", onclick: onExpand }, "⤢ Wide") : null);

  async function exportAnnotated(asVersion) {
    exportMenu.hidden = true;
    exportButton.disabled = true;
    exportButton.textContent = "Exporting…";
    try {
      const { annotatedPdf } = await import("./pdfannots.js");
      const measure = document.createElement("canvas").getContext("2d");
      const textHeight = (e) => { measure.font = textFont(e.size); return Math.max(e.size * 1.25, wrapText(measure, e.text || " ", e.w).length * e.size * 1.25); };
      const values = new Map([...marks.fields()].map(([name, e]) => [name, e.value]));
      const { bytes: out, count: n } = await annotatedPdf(await openPdf(bytes), { strokes: (i) => ink?.(i) ?? [], elements: (i) => marks.elements(i), fields: values, textHeight });
      if (!n) { marks.notify?.("Nothing to export yet: draw, highlight or fill in the form first."); return; }
      if (asVersion) { await marks.saveVersion(out); return; }
      const url = URL.createObjectURL(new Blob([out], { type: "application/pdf" }));
      const a = h("a", { href: url, download: fileName.replace(/(\.pdf)?$/i, " (annotated).pdf") });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      root.dataset.exported = String(out.length);
    } catch (e) {
      marks.notify?.(`Couldn't export: ${e.message}`);
    } finally {
      exportButton.disabled = false;
      exportButton.textContent = "Export";
    }
  }

  // ---------- pages ----------
  const first = await doc.getPage(1);
  const base = first.getViewport({ scale: 1 });
  for (let n = 1; n <= count; n++) {
    const overlay = h("div", { class: "pdf-overlay", "aria-hidden": "true" });
    overlays.push(overlay);
    pages.append(h("div", { class: "pdf-page", "data-page": n, style: `aspect-ratio: ${base.width} / ${base.height}` }, overlay));
  }
  const pageEl = (i) => pages.children[i];

  /** Highlights and find hits over page i (in % of the page, so zoom doesn't matter). */
  function drawOverlay(i) {
    const box = boxes[i];
    if (!box) return;
    const parts = [];
    for (const e of marks?.elements(i) ?? []) {
      if (e.type !== "highlight") continue;
      for (const r of highlightRects(e)) parts.push(h("div", { class: "pdf-hl", "data-id": e.id, style: `${place(r, box)};--hl:${e.color}` }));
    }
    hits.forEach((hit, n) => {
      if (hit.page !== i) return;
      for (const r of hit.rects) parts.push(h("div", { class: `pdf-hit${n === current ? " current" : ""}`, style: place(r, box) }));
    });
    overlays[i].replaceChildren(...parts);
  }
  function drawAllOverlays() { for (let i = 0; i < count; i++) drawOverlay(i); }

  const render = async (el) => {
    const n = Number(el.dataset.page), i = n - 1;
    const width = el.clientWidth;
    if (!width || el.dataset.rendered === String(width)) return;
    el.dataset.rendered = String(width);
    const page = await doc.getPage(n);
    const box = (boxes[i] ??= pdfPageBox(page.view, page.rotate));
    el.style.aspectRatio = `${box.width} / ${box.height}`;
    const px = width / box.width;
    el.style.setProperty("--scale-factor", px);
    const scale = px * Math.min(devicePixelRatio || 1, 2);
    const vp = page.getViewport({ scale });
    const canvas = h("canvas", { width: Math.floor(vp.width), height: Math.floor(vp.height), "aria-label": `Page ${n}` });
    // With marks, the form's fields are HTML inputs over the page, so pdf.js leaves them out of the canvas.
    await page.render({ canvasContext: canvas.getContext("2d"), viewport: vp, annotationMode: marks ? lib.AnnotationMode.ENABLE_FORMS : lib.AnnotationMode.ENABLE }).promise;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    drawStrokes(ctx, ink?.(i) ?? []);
    for (const e of marks?.elements(i) ?? []) { if (e.type === "text") drawTextElement(ctx, e); else if (e.type === "tape") drawTapeElement(ctx, e); }
    const textLayer = h("div", { class: "textLayer" });
    const layers = [canvas, overlays[i], textLayer];
    new lib.TextLayer({ textContentSource: page.streamTextContent(), container: textLayer, viewport: page.getViewport({ scale: px }) }).render().catch(() => {});
    const annots = await annotationLayer(page, i, box);
    if (annots) layers.push(annots);
    if (el.dataset.rendered === String(width)) el.replaceChildren(...layers);
    drawOverlay(i);
  };

  // ---------- links and forms ----------
  const group = `pdf${Math.random().toString(36).slice(2, 8)}`;
  async function goTo(dest) {
    try {
      const explicit = typeof dest === "string" ? await doc.getDestination(dest) : dest;
      if (!Array.isArray(explicit)) return;
      const ref = explicit[0];
      const index = ref && typeof ref === "object" ? await doc.getPageIndex(ref) : Number.isInteger(ref) ? ref : null;
      if (index !== null && pageEl(index)) pageEl(index).scrollIntoView({ block: "start" });
    } catch { /* a broken link */ }
  }

  async function annotationLayer(page, i, box) {
    let annotations;
    try { annotations = await page.getAnnotations({ intent: "display" }); } catch { return null; }
    const out = [];
    for (const a of annotations) {
      if (!a.rect || a.hidden || a.noView) continue;
      const r = pageRect(a.rect, box), style = place(r, box);
      if (a.subtype === "Link") {
        if (a.url && /^(https?:|mailto:)/i.test(a.url)) out.push(h("a", { class: "pdf-link", href: a.url, target: "_blank", rel: "noopener noreferrer", title: a.url, style }));
        else if (a.dest) out.push(h("a", { class: "pdf-link", href: "#", title: "Go to the page", style, onclick: (e) => { e.preventDefault(); goTo(a.dest); } }));
      } else if (a.subtype === "Widget" && marks && a.fieldName) {
        const input = fieldInput(a, i, r, style);
        if (input) out.push(input);
      }
    }
    return out.length ? h("div", { class: "pdf-annots" }, out) : null;
  }

  function fieldInput(a, i, frame, style) {
    const name = a.fieldName, saved = fieldValues.get(name)?.value;
    const save = (value) => { marks.setField({ page: i, name, value, frame }); fieldValues = marks.fields(); };
    const fontSize = a.defaultAppearanceData?.fontSize || Math.min(12, frame.h * 0.65);
    const sized = `${style};font-size:calc(var(--scale-factor, 1) * ${fontSize}px)`;
    const common = { "data-field": name, title: a.alternativeText || name, "aria-label": a.alternativeText || name, disabled: a.readOnly ? true : null };
    if (a.fieldType === "Tx") {
      const el = h(a.multiLine ? "textarea" : "input", { ...common, class: "pdf-field", style: sized, ...(a.multiLine ? {} : { type: "text" }), maxlength: a.maxLen > 0 ? String(a.maxLen) : null, spellcheck: "false" });
      el.value = typeof saved === "string" ? saved : typeof a.fieldValue === "string" ? a.fieldValue : "";
      let timer = null;
      el.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(() => save(el.value), 700); });
      el.addEventListener("change", () => { clearTimeout(timer); save(el.value); });
      el.dataset.kind = "text";
      return el;
    }
    if (a.fieldType === "Btn" && (a.checkBox || a.radioButton)) {
      const el = h("input", { ...common, class: "pdf-field pdf-check", style, type: a.radioButton ? "radio" : "checkbox", name: a.radioButton ? `${group}-${name}` : null });
      el.dataset.kind = a.radioButton ? "radio" : "check";
      el.dataset.value = a.radioButton ? a.buttonValue : a.exportValue ?? "";
      el.checked = isOn(el, saved !== undefined ? saved : a.fieldValue);
      el.addEventListener("change", () => { if (a.radioButton) { if (el.checked) save(a.buttonValue); } else save(el.checked); });
      return el;
    }
    if (a.fieldType === "Ch" && Array.isArray(a.options)) {
      const el = h("select", { ...common, class: "pdf-field", style: sized, multiple: a.multiSelect ? true : null },
        a.combo || a.multiSelect ? null : h("option", { value: "", text: "" }),
        a.options.map((o) => h("option", { value: o.exportValue, text: o.displayValue ?? o.exportValue })));
      el.dataset.kind = "choice";
      setChoice(el, saved !== undefined ? saved : a.fieldValue);
      el.addEventListener("change", () => save(el.multiple ? [...el.selectedOptions].map((o) => o.value) : el.value));
      return el;
    }
    return null;
  }
  const isOn = (el, v) => (el.dataset.kind === "radio" ? v === el.dataset.value : v === true || (typeof v === "string" && v !== "Off" && v === el.dataset.value));
  function setChoice(el, v) {
    const chosen = new Set(Array.isArray(v) ? v : typeof v === "string" ? [v] : []);
    for (const o of el.options) o.selected = chosen.has(o.value);
  }

  // ---------- highlighting selected text ----------
  const selbar = h("div", { class: "pdf-selbar", hidden: true, role: "toolbar", "aria-label": "Selected text" });
  let shownFor = null; // the highlight a tap opened, or null for the selection
  function showBar(rect, forId = null) {
    shownFor = forId;
    const rr = root.getBoundingClientRect();
    const swatches = HIGHLIGHT_COLORS.map((c) => h("button", { type: "button", class: "ink-swatch pdf-swatch", style: `--swatch:${c}`,
      "aria-label": forId ? `Make it ${COLOUR_NAMES[c] ?? c}` : `Highlight in ${COLOUR_NAMES[c] ?? c}`, title: forId ? "Colour" : "Highlight",
      onmousedown: (e) => e.preventDefault(), onclick: () => (forId ? recolour(forId, c) : highlightSelection(c)) }));
    selbar.replaceChildren(...swatches,
      h("button", { type: "button", class: "secondary small", onmousedown: (e) => e.preventDefault(), title: "Keep it in Quotes & Highlights",
        onclick: () => (forId ? quoteHighlight(forId) : highlightSelection(lastColour, true)) }, icon("quote"), " Quote"),
      h("button", { type: "button", class: "secondary small", onmousedown: (e) => e.preventDefault(), onclick: () => copyText(forId) }, "Copy"),
      forId ? h("button", { type: "button", class: "secondary small danger", onclick: () => removeHighlight(forId) }, "Remove") : null);
    selbar.hidden = false;
    const width = Math.min(selbar.offsetWidth || 320, rr.width - 16);
    selbar.style.left = `${Math.max(8, Math.min(rr.width - width - 8, rect.left - rr.left))}px`;
    selbar.style.top = `${Math.max(bar.offsetHeight + 4, rect.bottom - rr.top + 8)}px`;
  }
  const hideBar = () => { selbar.hidden = true; shownFor = null; };
  let lastColour = HIGHLIGHT_COLORS[0];

  /** The selection inside this viewer's text, or null. */
  function selectionRange() {
    const sel = getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    const range = sel.getRangeAt(0);
    return pages.contains(range.commonAncestorContainer) && range.toString().trim() ? range : null;
  }

  /** Per page: the selected text's boxes (page points) and its words. */
  function selectionByPage(range) {
    const out = new Map();
    const rects = [...range.getClientRects()];
    for (let i = 0; i < count; i++) {
      const el = pageEl(i), layer = el.querySelector(".textLayer"), box = boxes[i];
      if (!layer || !box || !range.intersectsNode(layer)) continue;
      const pr = el.getBoundingClientRect();
      const toPage = (r) => ({ x: ((r.left - pr.left) / pr.width) * box.width, y: ((r.top - pr.top) / pr.height) * box.height,
        w: (r.width / pr.width) * box.width, h: (r.height / pr.height) * box.height });
      const inside = rects.filter((r) => r.width > 0 && r.height > 0 && r.left + r.width / 2 >= pr.left && r.left + r.width / 2 <= pr.right
        && r.top + r.height / 2 >= pr.top && r.top + r.height / 2 <= pr.bottom);
      const part = document.createRange();
      part.selectNodeContents(layer);
      if (range.compareBoundaryPoints(Range.START_TO_START, part) > 0) part.setStart(range.startContainer, range.startOffset);
      if (range.compareBoundaryPoints(Range.END_TO_END, part) < 0) part.setEnd(range.endContainer, range.endOffset);
      if (inside.length) out.set(i, { boxes: inside.map(toPage), text: part.toString() });
    }
    return out;
  }

  function highlightSelection(color, quote = false) {
    const range = selectionRange();
    if (!range || !marks) return;
    lastColour = color;
    const words = [];
    for (const [page, { boxes: b, text }] of selectionByPage(range)) {
      if (marks.highlight({ page, boxes: b, quote: text, color })) words.push({ page, text });
      drawOverlay(page);
    }
    getSelection().removeAllRanges();
    hideBar();
    if (quote && words.length) marks.quote({ text: words.map((w) => w.text).join(" "), page: words[0].page });
  }

  const highlightById = (id) => { for (let i = 0; i < count; i++) { const e = marks?.elements(i).find((x) => x.id === id); if (e) return { e, page: i }; } return null; };
  function recolour(id, color) { marks.recolour(id, color); lastColour = color; const f = highlightById(id); if (f) drawOverlay(f.page); hideBar(); }
  function removeHighlight(id) { const f = highlightById(id); marks.remove(id); if (f) drawOverlay(f.page); hideBar(); }
  function quoteHighlight(id) { const f = highlightById(id); if (f?.e.quote) marks.quote({ text: f.e.quote, page: f.page }); hideBar(); }
  function copyText(id) {
    const text = id ? highlightById(id)?.e.quote ?? "" : selectionRange()?.toString() ?? "";
    navigator.clipboard?.writeText(text.replace(/\s+/g, " ").trim()).then(() => marks?.notify?.("Copied")).catch(() => {});
    hideBar();
  }

  if (marks) {
    let pending = 0;
    const check = () => {
      cancelAnimationFrame(pending);
      pending = requestAnimationFrame(() => {
        if (!root.isConnected) return;
        const range = selectionRange();
        if (range) { const rects = range.getClientRects(); showBar(rects[rects.length - 1] ?? range.getBoundingClientRect()); } else if (!shownFor) hideBar();
      });
    };
    pages.addEventListener("pointerup", check);
    pages.addEventListener("keyup", check);
    // A tap on a highlight opens it (colour, quote, copy, remove).
    pages.addEventListener("click", (e) => {
      if (selectionRange() || e.target.closest(".pdf-annots > *")) return;
      const el = e.target.closest(".pdf-page");
      const i = Number(el?.dataset.page) - 1, box = boxes[i];
      if (!box) return;
      const pr = el.getBoundingClientRect();
      const p = { x: ((e.clientX - pr.left) / pr.width) * box.width, y: ((e.clientY - pr.top) / pr.height) * box.height };
      const hit = (marks.elements(i) ?? []).filter((x) => x.type === "highlight").reverse()
        .find((x) => highlightRects(x).some((r) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h));
      if (hit) showBar({ left: e.clientX - 40, bottom: e.clientY + 4 }, hit.id); else hideBar();
    });
    pages.addEventListener("scroll", () => { if (!selbar.hidden) hideBar(); }, { passive: true });
  }

  const io = new IntersectionObserver((entries) => { for (const e of entries) if (e.isIntersecting) render(e.target).catch(() => {}); }, { rootMargin: "600px" });
  const observeAll = () => { for (const p of pages.children) { io.unobserve(p); io.observe(p); } };
  observeAll();
  // A PDF with no text for search yet (added on the website): read it once the pages are showing.
  if (marks?.indexText) {
    const idle = globalThis.requestIdleCallback ?? ((fn) => setTimeout(fn, 1500));
    idle(() => { documentText(doc).then((text) => { if (text) marks.indexText(text); }).catch(() => {}); }, { timeout: 4000 });
  }

  root.append(bar, findRow, exportMenu, pages, selbar);
  root.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") { e.preventDefault(); toggleFind(true); }
  });
  /** Re-reads highlights and form values (after a sync or an edit elsewhere). */
  root.refreshMarks = () => {
    if (!marks) return;
    fieldValues = marks.fields();
    drawAllOverlays();
    for (const el of pages.querySelectorAll(".pdf-field")) {
      if (el === document.activeElement || !fieldValues.has(el.dataset.field)) continue;
      const v = fieldValues.get(el.dataset.field).value;
      if (el.dataset.kind === "text") el.value = typeof v === "string" ? v : "";
      else if (el.dataset.kind === "choice") setChoice(el, v);
      else el.checked = isOn(el, v);
    }
  };
  return root;
}

/**
 * What the viewer saves to the vault for a PDF on an item: highlights, quotes and form values on
 * the file's layer. `changed()` runs after each edit (to sync), `notify(text)` shows a message,
 * `saveVersion(bytes)` (optional) saves an exported file as the item's new version, `indexText(text)`
 * (optional) saves the PDF's text for search when it has none.
 */
export function pdfMarks(vault, itemId, att, { changed = () => {}, notify = () => {}, saveVersion = null, indexText = null } = {}) {
  const on = itemId, layer = att.id;
  return {
    notify, saveVersion, indexText,
    elements: (page) => vault.elements(on, layer, page),
    fields: () => vault.pdfFields(on, layer),
    highlight: ({ page, boxes, quote, color }) => { const id = vault.addHighlight({ on, layer, page, boxes, quote, color }); changed(); return id; },
    recolour: (id, color) => { vault.updateElement(id, { color }); changed(); },
    remove: (id) => { vault.deleteElements([id]); changed(); },
    quote: ({ text, page }) => { const id = vault.addQuote({ text, from: on, page }); if (id) { notify("Kept in Quotes & Highlights"); changed(); } return id; },
    setField: ({ page, name, value, frame }) => { vault.setPdfField({ on, layer, page, name, value, frame }); changed(); },
  };
}
