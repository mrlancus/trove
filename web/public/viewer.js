// File previews for the item panel: PDFs (pdf.js, vendored), images, GoodNotes notebooks, Word,
// Excel, PowerPoint, Pages/Keynote/Numbers, text and CSV (editable, each save a new version),
// audio and video. Plus small JPEG thumbnails for cards.
import { h } from "./dom.js";
import { icon } from "./icons.js";
import { docxParagraphs, goodnotesParts, iworkPreview, parseDelimited, pptxSlides, previewKind, typeLabel, xlsxRows } from "./core/files.js";
import { backgroundLayers, GN_SCALE, isHighlighter, readNotebook, runPath, strokeOpacity, strokeWidth } from "./core/goodnotes.js";
import { drawStrokes } from "./core/ink.js";
import { renderMarkdown } from "./markdown.js";

let pdfjs = null;
async function loadPdfjs() {
  if (!pdfjs) {
    pdfjs = await import("/vendor/pdfjs/pdf.min.mjs");
    pdfjs.GlobalWorkerOptions.workerSrc = "/vendor/pdfjs/pdf.worker.min.mjs";
  }
  return pdfjs;
}

async function openPdf(bytes) {
  const lib = await loadPdfjs();
  // pdf.js takes ownership of the buffer, so give it a copy.
  return lib.getDocument({ data: bytes.slice(), isEvalSupported: false, useSystemFonts: true }).promise;
}

const objectURLs = new Set();
function urlFor(bytes, mime) {
  const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
  objectURLs.add(url);
  return url;
}

/** Shows an image full screen; click or Escape closes it. */
export function lightbox(src, alt = "") {
  const close = () => { box.remove(); removeEventListener("keydown", onKey); };
  const onKey = (e) => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
  const img = h("img", { src, alt });
  const box = h("div", { class: "lightbox", role: "dialog", "aria-label": alt || "Image", onclick: (e) => { if (e.target !== img || !img.classList.contains("zoomed")) close(); } }, img,
    h("button", { type: "button", class: "icon-button lightbox-close", "aria-label": "Close", onclick: close }, icon("close")));
  img.addEventListener("dblclick", (e) => { e.stopPropagation(); img.classList.toggle("zoomed"); });
  addEventListener("keydown", onKey);
  document.body.append(box);
}

/** A scrolling PDF: pages render as they come into view; zoom buttons. */
export async function pdfViewer(bytes, { onExpand, ink } = {}) {
  const doc = await openPdf(bytes);
  let zoom = 1;
  const pages = h("div", { class: "pdf-pages" });
  const label = h("span", { class: "saved", text: `${doc.numPages} page${doc.numPages === 1 ? "" : "s"}` });
  const setZoom = (z) => { zoom = Math.min(4, Math.max(0.5, z)); pages.style.setProperty("--zoom", zoom); for (const p of pages.children) p.dataset.rendered = ""; observeAll(); };
  const bar = h("div", { class: "viewer-bar" }, label, h("span", { class: "spacer" }),
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom out", onclick: () => setZoom(zoom / 1.25) }, "−"),
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom in", onclick: () => setZoom(zoom * 1.25) }, "+"),
    onExpand ? h("button", { type: "button", class: "secondary small", onclick: onExpand }, "⤢ Wide") : null);
  const first = await doc.getPage(1);
  const base = first.getViewport({ scale: 1 });
  for (let n = 1; n <= doc.numPages; n++) {
    pages.append(h("div", { class: "pdf-page", "data-page": n, style: `aspect-ratio: ${base.width} / ${base.height}` }));
  }
  const render = async (el) => {
    const n = Number(el.dataset.page);
    const width = el.clientWidth;
    if (!width || el.dataset.rendered === String(width)) return;
    el.dataset.rendered = String(width);
    const page = await doc.getPage(n);
    const vp1 = page.getViewport({ scale: 1 });
    el.style.aspectRatio = `${vp1.width} / ${vp1.height}`;
    const scale = (width / vp1.width) * Math.min(devicePixelRatio || 1, 2);
    const vp = page.getViewport({ scale });
    const canvas = h("canvas", { width: Math.floor(vp.width), height: Math.floor(vp.height), "aria-label": `Page ${n}` });
    await page.render({ canvasContext: canvas.getContext("2d"), viewport: vp }).promise;
    const strokes = ink?.(n - 1) ?? [];
    if (strokes.length) {
      const ctx = canvas.getContext("2d");
      ctx.setTransform(scale, 0, 0, scale, 0, 0);
      drawStrokes(ctx, strokes);
    }
    el.replaceChildren(canvas);
  };
  const io = new IntersectionObserver((entries) => { for (const e of entries) if (e.isIntersecting) render(e.target).catch(() => {}); }, { rootMargin: "600px" });
  const observeAll = () => { for (const p of pages.children) { io.unobserve(p); io.observe(p); } };
  observeAll();
  return h("div", { class: "pdf-viewer" }, bar, pages);
}

/** Pages to draw on for a PDF or an image: [{width, height, background(ctx, pxPerPoint)}], in PDF points or image pixels. */
export async function inkPages(att, bytes, notebook = null) {
  if (previewKind(att.name, att.mime) === "goodnotes") {
    // GoodNotes: its backgrounds and pictures under the ink (which Trove's editor now holds).
    notebook ??= await readNotebook(bytes);
    const draw = notebookPainter(notebook);
    const out = [];
    for (const page of notebook.pages) {
      const s = await draw.size(page);
      out.push({ width: s.width, height: s.height, background: async (ctx, k) => draw.page(ctx, page, k, { only: backgroundLayers(page) }) });
    }
    return out;
  }
  if (previewKind(att.name, att.mime) === "pdf") {
    const doc = await openPdf(bytes);
    const pages = [];
    for (let n = 1; n <= doc.numPages; n++) {
      const page = await doc.getPage(n);
      const vp = page.getViewport({ scale: 1 });
      pages.push({ width: vp.width, height: vp.height, background: async (ctx, k) => {
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        await page.render({ canvasContext: ctx, viewport: page.getViewport({ scale: k }) }).promise;
        ctx.restore();
      } });
    }
    return pages;
  }
  const bitmap = await createImageBitmap(new Blob([bytes], { type: att.mime }));
  return [{ width: bitmap.width, height: bitmap.height, background: (ctx) => ctx.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height) }];
}

/** Whether a file can be drawn on (PDFs and images the browser can show). */
export const canInk = (att) => ["pdf", "image", "goodnotes"].includes(previewKind(att.name, att.mime)) && !/heic|heif|svg/.test(att.mime);

/**
 * A GoodNotes notebook drawn from its own data (core/goodnotes.js): each page's PDF or image
 * background, then its ink, shapes, typed text and pictures in GoodNotes' order. Pages draw as they
 * scroll into view.
 */
export function notebookViewer(notebook, { onExpand, ink = null, elements = null } = {}) {
  let zoom = 1;
  const draw = notebookPainter(notebook);
  const pages = h("div", { class: "pdf-pages notebook-pages" });
  const count = notebook.pages.length;
  const unread = notebook.pages.reduce((n, p) => n + (p.unread ?? 0), 0);
  const setZoom = (z) => { zoom = Math.min(4, Math.max(0.5, z)); pages.style.setProperty("--zoom", zoom); for (const p of pages.children) p.dataset.rendered = ""; observeAll(); };
  const bar = h("div", { class: "viewer-bar" },
    h("span", { class: "saved", text: `GoodNotes notebook · ${count} page${count === 1 ? "" : "s"}` }),
    unread ? h("span", { class: "saved", title: "Trove couldn't read some of this notebook's ink. Send the notebook (or a copy with one such stroke) to get it fixed.",
      text: ` · ${unread} stroke${unread === 1 ? "" : "s"} couldn't be read` }) : null,
    h("span", { class: "spacer" }),
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom out", onclick: () => setZoom(zoom / 1.25) }, "−"),
    h("button", { type: "button", class: "secondary small", "aria-label": "Zoom in", onclick: () => setZoom(zoom * 1.25) }, "+"),
    onExpand ? h("button", { type: "button", class: "secondary small", onclick: onExpand }, "⤢ Wide") : null);
  notebook.pages.forEach((page, i) => pages.append(h("div", { class: "pdf-page", "data-page": i, style: `aspect-ratio: ${page.width} / ${page.height}` })));

  const render = async (el) => {
    const index = Number(el.dataset.page), page = notebook.pages[index];
    const width = el.clientWidth;
    if (!width || el.dataset.rendered === String(width)) return;
    el.dataset.rendered = String(width);
    const size = await draw.size(page);
    el.style.aspectRatio = `${size.width} / ${size.height}`;
    // A big whiteboard would need a canvas bigger than browsers allow: draw it softer instead.
    const px = Math.min((width / size.width) * Math.min(devicePixelRatio || 1, 2), 16000 / size.height, Math.sqrt(30e6 / (size.width * size.height)));
    const canvas = h("canvas", { width: Math.floor(size.width * px), height: Math.floor(size.height * px), "aria-label": `Page ${index + 1}` });
    const ctx = canvas.getContext("2d");
    // Edited in Trove: GoodNotes' background and pictures, then Trove's copy of the ink and text.
    await draw.page(ctx, page, px, { only: ink ? backgroundLayers(page) : null });
    if (ink) {
      ctx.save();
      ctx.setTransform(px, 0, 0, px, 0, 0);
      drawStrokes(ctx, ink(index));
      for (const e of elements?.(index) ?? []) if (e.type === "text") drawPlainText(ctx, e);
      ctx.restore();
    }
    el.replaceChildren(canvas);
  };
  const io = new IntersectionObserver((entries) => { for (const e of entries) if (e.isIntersecting) render(e.target).catch(() => {}); }, { rootMargin: "600px" });
  const observeAll = () => { for (const p of pages.children) { io.unobserve(p); io.observe(p); } };
  observeAll();
  return h("div", { class: "pdf-viewer notebook" }, bar, pages);
}

/** A Trove text box (PROTOCOL.md §10): wrapped to its width, lines 1.25 × size apart. */
function drawPlainText(ctx, e) {
  ctx.save();
  ctx.fillStyle = e.color ?? "#000";
  ctx.font = `${e.size}px -apple-system, system-ui, sans-serif`;
  ctx.textBaseline = "top";
  let y = e.y;
  for (const para of String(e.text ?? "").split("\n")) {
    let line = "";
    for (const word of para.split(/(\s+)/)) {
      if (line && ctx.measureText(line + word).width > e.w) { ctx.fillText(line.trimEnd(), e.x, y); y += e.size * 1.25; line = word.trimStart(); }
      else line += word;
    }
    ctx.fillText(line, e.x, y);
    y += e.size * 1.25;
  }
  ctx.restore();
}

/**
 * Draws notebook pages: `size(page)` in points (the background PDF's own when it has one), and
 * `page(ctx, page, px, {only})` paints white, the background, then the layers (or just `only`)
 * at `px` canvas pixels per point. Shared by the viewer and the drawing editor.
 */
export function notebookPainter(notebook) {
  const pdfs = new Map(), bitmaps = new Map();
  const pdfFor = (id) => { if (!pdfs.has(id)) pdfs.set(id, openPdf(notebook.attachments.get(id).bytes)); return pdfs.get(id); };
  const bitmapFor = (id) => {
    if (!bitmaps.has(id)) { const a = notebook.attachments.get(id); bitmaps.set(id, createImageBitmap(new Blob([a.bytes], { type: a.mime }))); }
    return bitmaps.get(id);
  };
  const pdfPageOf = async (page) => {
    const bg = page.background && notebook.attachments.get(page.background.attachment);
    if (bg?.mime !== "application/pdf") return null;
    try {
      const doc = await pdfFor(page.background.attachment);
      return await doc.getPage(Math.min(Math.max(1, page.background.page), doc.numPages));
    } catch { return null; }
  };
  const size = async (page) => {
    const pdfPage = await pdfPageOf(page);
    if (!pdfPage) return { width: page.width, height: page.height };
    const vp = pdfPage.getViewport({ scale: 1 });
    return { width: vp.width, height: vp.height };
  };
  const paint = async (ctx, page, px, { only = null } = {}) => {
    const s = await size(page);
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, Math.ceil(s.width * px), Math.ceil(s.height * px));
    const bg = page.background && notebook.attachments.get(page.background.attachment);
    const pdfPage = await pdfPageOf(page);
    if (pdfPage) await pdfPage.render({ canvasContext: ctx, viewport: pdfPage.getViewport({ scale: px }) }).promise;
    else if (bg?.mime.startsWith("image/")) { try { ctx.drawImage(await bitmapFor(page.background.attachment), 0, 0, s.width * px, s.height * px); } catch { /* no background */ } }
    const k = px * GN_SCALE;
    for (const layer of only ?? page.layers) {
      if (layer.kind === "ink" && layer.fill) {
        ctx.save();
        ctx.fillStyle = `rgb(${layer.rgb.map((c) => Math.round(c * 255)).join(",")})`;
        ctx.globalAlpha = layer.alpha;
        for (const run of layer.runs) ctx.fill(new Path2D(runPath(run, k, true) + "Z"));
        ctx.restore();
      } else if (layer.kind === "ink") {
        ctx.save();
        ctx.strokeStyle = `rgb(${layer.rgb.map((c) => Math.round(c * 255)).join(",")})`;
        ctx.globalAlpha = strokeOpacity(layer);
        if (isHighlighter(layer)) ctx.globalCompositeOperation = "multiply";
        ctx.lineWidth = strokeWidth(layer) * k;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        for (const run of layer.runs) ctx.stroke(new Path2D(runPath(run, k, layer.shape)));
        ctx.restore();
      } else if (layer.kind === "image") {
        try { ctx.drawImage(await bitmapFor(layer.attachment), layer.x * k, layer.y * k, layer.w * k, layer.h * k); } catch { /* missing picture */ }
      } else if (layer.kind === "text") {
        drawTextBox(ctx, layer, k);
      }
    }
    ctx.restore();
  };
  return { size, page: paint };
}

/** Typed text, wrapped to its box. Style runs flow on inside a paragraph; "\n" starts a new one. */
function drawTextBox(ctx, box, k) {
  const left = box.x * k, maxWidth = Math.max(box.w * k, 40);
  let x = 0, y = box.y * k, lineHeight = 0;
  const newLine = () => { y += (lineHeight || box.runs[0].size * k) * 1.25; x = 0; lineHeight = 0; };
  ctx.save();
  ctx.textBaseline = "top";
  for (const run of box.runs) {
    const size = run.size * k;
    ctx.font = `${run.italic ? "italic " : ""}${run.bold ? "700" : "400"} ${size}px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif`;
    ctx.fillStyle = `rgb(${run.rgb.map((c) => Math.round(c * 255)).join(",")})`;
    for (const token of run.text.split(/(\n|[^\S\n]+)/)) {
      if (!token) continue;
      if (token === "\n") { newLine(); continue; }
      const w = ctx.measureText(token).width;
      if (x > 0 && x + w > maxWidth && token.trim()) newLine();
      if (x === 0 && !token.trim()) continue;
      lineHeight = Math.max(lineHeight, size);
      ctx.fillText(token, left + x, y);
      x += w;
    }
  }
  ctx.restore();
}

function table(rows) {
  const width = Math.max(0, ...rows.map((r) => r.length));
  return h("div", { class: "table-wrap" }, h("table", { class: "sheet" },
    rows.map((r, i) => h("tr", {}, Array.from({ length: width }, (_, c) => h(i === 0 ? "th" : "td", { text: r[c] ?? "" }))))));
}

/**
 * The preview for one attachment. `load()` returns its decrypted bytes. `edit(bytes)` saves an
 * edited version (text files only). Returns an element that fills in as it loads.
 */
export function attachmentPreview(att, { load, edit, onExpand, eager = true, ink = null, elements = null, inkEdited = false }) {
  const kind = previewKind(att.name, att.mime);
  const box = h("div", { class: `viewer viewer-${kind}` });
  const start = async () => {
    box.replaceChildren(h("p", { class: "saved", text: `Decrypting ${att.name}…` }));
    try {
      const bytes = await load();
      box.replaceChildren(await build(kind, att, bytes, { edit, onExpand, ink, elements, inkEdited }));
    } catch (e) {
      box.replaceChildren(h("p", { class: "danger", text: `Couldn't open ${att.name}: ${e.message}` }));
    }
  };
  if (eager) start();
  else box.append(h("button", { type: "button", class: "secondary", onclick: start }, `Show ${att.name}`));
  return box;
}

async function build(kind, att, bytes, { edit, onExpand, ink, elements, inkEdited }) {
  switch (kind) {
    case "image": {
      const url = urlFor(bytes, att.mime);
      const img = h("img", { src: url, alt: att.name, class: "zoomable", onclick: () => lightbox(url, att.name) });
      img.addEventListener("error", () => img.replaceWith(h("p", { class: "saved", text: "This browser can't show this image type (HEIC shows in Safari). Download it to open it." })));
      const strokes = ink?.(0) ?? [];
      if (!strokes.length) return img;
      // Ink on top, in image pixels.
      const overlay = h("canvas", { class: "ink-overlay", "aria-hidden": "true" });
      img.addEventListener("load", () => {
        const k = Math.min(1, 2400 / Math.max(img.naturalWidth, 1));
        overlay.width = Math.round(img.naturalWidth * k);
        overlay.height = Math.round(img.naturalHeight * k);
        const ctx = overlay.getContext("2d");
        ctx.setTransform(k, 0, 0, k, 0, 0);
        drawStrokes(ctx, strokes);
      });
      return h("div", { class: "inked-image" }, img, overlay);
    }
    case "pdf": return pdfViewer(bytes, { onExpand, ink });
    case "audio": case "video": return h(kind, { src: urlFor(bytes, att.mime), controls: true, preload: "metadata" });
    case "goodnotes": {
      let notebook = null;
      try { notebook = await readNotebook(bytes); } catch { notebook = null; }
      if (notebook?.pages.length) return notebookViewer(notebook, { onExpand, ink: inkEdited ? ink : null, elements: inkEdited ? elements : null });
      const parts = await goodnotesParts(bytes);
      const out = h("div", { class: "goodnotes" });
      const head = h("div", { class: "goodnotes-head" });
      if (parts.thumbnail) {
        const url = urlFor(parts.thumbnail.bytes, parts.thumbnail.mime);
        head.append(h("img", { src: url, alt: "Notebook cover", class: "cover zoomable", onclick: () => lightbox(url, att.name) }));
      }
      head.append(h("div", {}, h("strong", { text: "GoodNotes notebook" }),
        h("p", { class: "saved", text: "Couldn't read the pages of this notebook. Its cover and the documents inside are below." })));
      out.append(head);
      for (const a of parts.attachments) {
        if (a.mime === "application/pdf") out.append(h("p", { class: "section-title", text: "Document inside" }), await pdfViewer(a.bytes, { onExpand }));
        else { const url = urlFor(a.bytes, a.mime); out.append(h("img", { src: url, alt: "", class: "zoomable", onclick: () => lightbox(url) })); }
      }
      return out;
    }
    case "iwork": {
      const preview = await iworkPreview(bytes);
      if (!preview) return h("p", { class: "saved", text: "This file has no saved preview. Download it to open it in Pages, Keynote or Numbers." });
      const url = urlFor(preview.bytes, preview.mime);
      return h("div", {}, h("img", { src: url, alt: att.name, class: "zoomable", onclick: () => lightbox(url, att.name) }),
        h("p", { class: "saved", text: "The preview saved with the file (first page or slide)." }));
    }
    case "docx": {
      const paras = await docxParagraphs(bytes);
      if (!paras.length) return h("p", { class: "saved", text: "No text found in this document." });
      const doc = h("article", { class: "doc-page" });
      let list = null;
      for (const p of paras) {
        if (p.style === "li") { if (!list) { list = h("ul"); doc.append(list); } list.append(h("li", { text: p.text })); continue; }
        list = null;
        doc.append(h(p.style === "p" ? "p" : p.style, { text: p.text || " " }));
      }
      return doc;
    }
    case "xlsx": {
      const rows = await xlsxRows(bytes);
      return rows.length ? h("div", {}, table(rows), h("p", { class: "saved", text: "First sheet" + (rows.length >= 200 ? ", first 200 rows" : "") })) : h("p", { class: "saved", text: "This sheet is empty." });
    }
    case "pptx": {
      const slides = await pptxSlides(bytes);
      return h("ol", { class: "slides" }, slides.map((lines) => h("li", { class: "slide" }, lines.map((l, i) => h(i === 0 ? "strong" : "p", { text: l })))));
    }
    case "text": case "csv": return textViewer(kind, att, bytes, edit);
    default:
      return h("div", { class: "no-preview" }, h("div", { class: "type-tile large", text: typeLabel(att.name, att.mime) }),
        h("p", { class: "saved", text: "There's no preview for this kind of file. Download it to open it." }));
  }
}

function textViewer(kind, att, bytes, edit) {
  let text;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { return h("p", { class: "saved", text: "This file isn't plain text." }); }
  const wrap = h("div", { class: "text-viewer" });
  const isMarkdown = /\.(md|markdown)$/i.test(att.name);
  const show = () => {
    let view;
    if (kind === "csv") view = table(parseDelimited(text, /\.tsv$/i.test(att.name) ? "\t" : ","));
    else if (isMarkdown) { view = h("div", { class: "preview" }); view.innerHTML = renderMarkdown(text); } // escaped by renderMarkdown
    else view = h("pre", { class: "file-text", text: text.length > 400_000 ? text.slice(0, 400_000) + "\n…" : text });
    wrap.replaceChildren(edit ? h("div", { class: "viewer-bar" }, h("span", { class: "spacer" }),
      h("button", { type: "button", class: "secondary small", onclick: editMode }, "Edit")) : null, view);
  };
  const editMode = () => {
    const area = h("textarea", { class: "body-input file-edit", "aria-label": `Edit ${att.name}`, spellcheck: "false" });
    area.value = text;
    const status = h("span", { class: "saved" });
    wrap.replaceChildren(h("div", { class: "viewer-bar" }, status, h("span", { class: "spacer" }),
      h("button", { type: "button", class: "secondary small", onclick: show }, "Cancel"),
      h("button", { type: "button", class: "primary small", onclick: async () => {
        status.textContent = "Saving…";
        try { await edit(new TextEncoder().encode(area.value)); text = area.value; show(); } catch (e) { status.textContent = `Couldn't save: ${e.message}`; }
      } }, "Save as new version")), area);
    area.focus();
  };
  show();
  return wrap;
}

/** A small JPEG preview of a file for cards, or null when there's nothing to draw. */
export async function makeThumbnail(att, bytes, size = 480) {
  const kind = previewKind(att.name, att.mime);
  let source = null;
  if (kind === "image" && !/svg/.test(att.mime)) source = new Blob([bytes], { type: att.mime });
  else if (kind === "goodnotes") {
    const parts = await goodnotesParts(bytes);
    if (parts.thumbnail) source = new Blob([parts.thumbnail.bytes], { type: parts.thumbnail.mime });
    else if (parts.attachments[0]?.mime === "application/pdf") return pdfThumbnail(parts.attachments[0].bytes, size);
    else if (parts.attachments[0]) source = new Blob([parts.attachments[0].bytes], { type: parts.attachments[0].mime });
  } else if (kind === "iwork") {
    const p = await iworkPreview(bytes);
    if (p) source = new Blob([p.bytes], { type: p.mime });
  } else if (kind === "pdf") return pdfThumbnail(bytes, size);
  if (!source) return null;
  const bitmap = await createImageBitmap(source);
  const scale = Math.min(1, size / Math.max(bitmap.width, bitmap.height));
  const canvas = h("canvas", { width: Math.max(1, Math.round(bitmap.width * scale)), height: Math.max(1, Math.round(bitmap.height * scale)) });
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return canvasJPEG(canvas);
}

async function pdfThumbnail(bytes, size) {
  const doc = await openPdf(bytes);
  const page = await doc.getPage(1);
  const vp1 = page.getViewport({ scale: 1 });
  const vp = page.getViewport({ scale: size / Math.max(vp1.width, vp1.height) });
  const canvas = h("canvas", { width: Math.round(vp.width), height: Math.round(vp.height) });
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  await page.render({ canvasContext: ctx, viewport: vp }).promise;
  doc.destroy();
  return canvasJPEG(canvas);
}

async function canvasJPEG(canvas) {
  const blob = await new Promise((ok) => canvas.toBlob(ok, "image/jpeg", 0.8));
  return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
}

/** Whether a card should try to make a thumbnail for this file (and it's small enough to fetch). */
export function wantsThumbnail(att) {
  const kind = previewKind(att.name, att.mime);
  const limit = kind === "image" ? 25e6 : kind === "pdf" ? 60e6 : 120e6;
  return ["image", "pdf", "goodnotes", "iwork"].includes(kind) && (!att.size || att.size < limit) && !/heic|svg/.test(att.mime);
}
