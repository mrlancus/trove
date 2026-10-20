// The drawing editor: sketches and ink on PDFs and images (PROTOCOL.md §10, core/ink.js).
// Pens, pencils, markers, highlighters and a stroke eraser; colours and sizes; undo and redo.
// Apple Pencil (or any pen) draws and fingers scroll and pinch; without a pen, one finger draws and
// two fingers scroll and pinch. A mouse or trackpad draws, the wheel scrolls, ⌘/Ctrl + wheel zooms.
import { h } from "./dom.js";
import { drawPaper, drawStroke, drawStrokes, hits, PAPERS } from "./core/ink.js";

const COLORS = ["#1c1c1e", "#8e8e93", "#0a84ff", "#ff3b30", "#34c759", "#ff9500", "#af52de", "#ffd60a"];
const TOOL_INFO = {
  pen: { label: "Pen", key: "p", width: 2.5, color: "#1c1c1e", icon: "M4 20l4-1 10-10-3-3L5 16l-1 4zM14 5l3 3" },
  pencil: { label: "Pencil", key: "n", width: 2, color: "#1c1c1e", icon: "M4 20l2-5 9-9 3 3-9 9-5 2zM15 6l3 3M6 15l3 3" },
  marker: { label: "Marker", key: "m", width: 7, color: "#0a84ff", icon: "M7 21h6M9 17h2l6-6-4-4-6 6v2l2 2zM13 7l4 4" },
  highlighter: { label: "Highlighter", key: "h", width: 22, color: "#ffd60a", icon: "M5 21h8M7 17l2 2 9-9-4-4-9 9 2 2zM14 6l4 4" },
  eraser: { label: "Eraser", key: "e", width: 0, color: "", icon: "M7 20h11M5 15l8-8 6 6-5 5H9l-4-4zM9 11l5 5" },
};
const PAPER_LABEL = { blank: "Blank", lined: "Lined", grid: "Squared", dotted: "Dotted" };

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

/**
 * Opens the editor over the page.
 * - `pages`: [{ width, height, background?(ctx, pxPerPoint) }] in page points (async backgrounds are fine).
 * - `sketch`: { paper, pageCount, setPaper(p), addPage() } for a sketch item's own pages.
 * - `changed()` runs after every edit (to sync); `onClose(edited)` when it closes.
 */
export function openInkEditor({ vault, itemId, layer = "", title = "Drawing", pages, sketch = null, startPage = 0, changed = () => {}, onClose = () => {} }) {
  const prefs = { tool: "pen", colors: {}, widths: {}, ...loadPrefs() };
  let tool = TOOL_INFO[prefs.tool] ? prefs.tool : "pen";
  let zoom = 1;
  let penSeen = false;
  let edited = false;
  let current = null; // the stroke being drawn
  let erasing = null; // {page, strokes: [...]} for one eraser gesture
  const touches = new Map(); // finger pointers when they pan/pinch
  let pinch = null;
  const undo = [], redo = [];

  const colorOf = (t) => prefs.colors[t] ?? TOOL_INFO[t].color;
  const widthOf = (t) => prefs.widths[t] ?? TOOL_INFO[t].width;

  // ---------- toolbar ----------
  const toolButtons = Object.entries(TOOL_INFO).map(([id, info]) => h("button", {
    type: "button", class: `ink-tool tool-${id}`, title: `${info.label} (${info.key.toUpperCase()})`, "aria-label": info.label,
    onclick: () => setTool(id),
  }, icon(info.icon)));
  const swatches = COLORS.map((c) => h("button", { type: "button", class: "ink-swatch", title: c, "aria-label": `Colour ${c}`, style: `--swatch:${c}`, onclick: () => setColor(c) }));
  const custom = h("input", { type: "color", class: "ink-custom", "aria-label": "Any colour", title: "Any colour" });
  custom.addEventListener("input", () => setColor(custom.value));
  const size = h("input", { type: "range", min: "1", max: "40", step: "0.5", class: "ink-size", "aria-label": "Size" });
  const sizeDot = h("span", { class: "ink-size-dot", "aria-hidden": "true" });
  size.addEventListener("input", () => { prefs.widths[tool] = Number(size.value); savePrefs(prefs); refreshToolbar(); });
  const undoButton = h("button", { type: "button", class: "secondary small", title: "Undo (⌘Z)", onclick: doUndo }, "↶ Undo");
  const redoButton = h("button", { type: "button", class: "secondary small", title: "Redo (⇧⌘Z)", onclick: doRedo }, "↷ Redo");
  const zoomLabel = h("span", { class: "saved ink-zoom" });
  let paperSelect = null, addPageButton = null;
  if (sketch) {
    paperSelect = h("select", { class: "folder-select", "aria-label": "Paper" }, PAPERS.map((p) => h("option", { value: p, selected: p === sketch.paper ? true : null, text: PAPER_LABEL[p] })));
    paperSelect.addEventListener("change", () => { sketch.paper = paperSelect.value; sketch.setPaper(sketch.paper); for (const v of views) { v.bgWidth = 0; } renderVisible(); changed(); });
    addPageButton = h("button", { type: "button", class: "secondary small", onclick: addPage }, "+ Page");
  }
  const bar = h("div", { class: "ink-bar", role: "toolbar", "aria-label": "Drawing tools" },
    h("div", { class: "ink-group" }, toolButtons),
    h("div", { class: "ink-group ink-colors" }, swatches, custom),
    h("div", { class: "ink-group" }, sizeDot, size),
    h("div", { class: "ink-group" }, undoButton, redoButton),
    h("div", { class: "ink-group" },
      h("button", { type: "button", class: "secondary small", "aria-label": "Zoom out", onclick: () => setZoom(zoom / 1.25) }, "−"), zoomLabel,
      h("button", { type: "button", class: "secondary small", "aria-label": "Zoom in", onclick: () => setZoom(zoom * 1.25) }, "+")),
    sketch ? h("div", { class: "ink-group" }, paperSelect, addPageButton) : null,
    h("span", { class: "spacer" }),
    h("strong", { class: "ink-title", text: title }),
    h("button", { type: "button", class: "primary", onclick: close }, "Done"));

  // ---------- pages ----------
  const stack = h("div", { class: "ink-pages" });
  const scroller = h("div", { class: "ink-scroller" }, stack);
  const root = h("div", { class: "ink-editor", role: "dialog", "aria-label": `Drawing: ${title}` }, bar, scroller);
  document.body.append(root);
  document.body.classList.add("ink-open");

  const views = [];
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) { const v = views.find((x) => x.el === e.target); if (v) { v.visible = e.isIntersecting; if (e.isIntersecting) renderView(v); } }
  }, { root: scroller, rootMargin: "800px" });

  function addView(index) {
    const page = pages[index];
    const bg = h("canvas", { class: "ink-bg" }), ink = h("canvas", { class: "ink-ink" }), live = h("canvas", { class: "ink-live" });
    const el = h("div", { class: "ink-page", "data-page": index, style: `aspect-ratio: ${page.width} / ${page.height}` }, bg, ink, live,
      h("span", { class: "ink-page-number", text: pages.length > 1 ? `${index + 1}` : "" }));
    const view = { index, page, el, bg, ink, live, bgWidth: 0, inkWidth: 0, visible: false };
    views.push(view);
    stack.append(el);
    wirePointer(view);
    io.observe(el);
    return view;
  }

  function layout() {
    const avail = Math.max(240, scroller.clientWidth - 32);
    for (const v of views) {
      const fit = Math.min(avail, Math.max(avail * 0.6, 900)) / v.page.width;
      v.el.style.width = `${Math.round(v.page.width * fit * zoom)}px`;
    }
    zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
    renderVisible();
  }

  function sizeCanvas(v, canvas) {
    const css = v.el.clientWidth;
    const dpr = Math.min(devicePixelRatio || 1, 3);
    let w = Math.round(css * dpr), hgt = Math.round(css * dpr * v.page.height / v.page.width);
    const cap = 16e6 / Math.max(1, w * hgt);
    if (cap < 1) { w = Math.floor(w * Math.sqrt(cap)); hgt = Math.floor(hgt * Math.sqrt(cap)); }
    if (canvas.width !== w || canvas.height !== hgt) { canvas.width = w; canvas.height = hgt; }
    return w / v.page.width; // device pixels per page point
  }

  async function renderView(v) {
    if (!v.visible || !v.el.clientWidth) return;
    const css = v.el.clientWidth;
    if (v.bgWidth !== css) {
      v.bgWidth = css;
      const k = sizeCanvas(v, v.bg);
      const ctx = v.bg.getContext("2d");
      ctx.setTransform(k, 0, 0, k, 0, 0);
      if (sketch) drawPaper(ctx, sketch.paper, v.page.width, v.page.height);
      else { ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, v.page.width, v.page.height); }
      try { await v.page.background?.(ctx, k); } catch { /* no background */ }
    }
    if (v.inkWidth !== css || v.dirty) { v.inkWidth = css; v.dirty = false; renderInk(v); }
  }
  function renderVisible() { for (const v of views) if (v.visible) renderView(v); }

  function renderInk(v) {
    const k = sizeCanvas(v, v.ink);
    const ctx = v.ink.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, v.ink.width, v.ink.height);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    drawStrokes(ctx, vault.strokes(itemId, layer, v.index));
  }

  function clearLive(v) {
    const ctx = v.live.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, v.live.width, v.live.height);
  }

  // ---------- input ----------
  const toPage = (v, e) => {
    const r = v.live.getBoundingClientRect();
    return { x: ((e.clientX - r.left) / r.width) * v.page.width, y: ((e.clientY - r.top) / r.height) * v.page.height };
  };

  function wirePointer(v) {
    const c = v.live;
    c.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "pen") { penSeen = true; root.classList.add("pen-seen"); }
      if (e.pointerType === "touch" && (penSeen || touches.size > 0 || current?.pointerType === "touch")) {
        // A finger with a pen around, or a second finger: scroll and pinch instead of drawing.
        if (current?.pointerType === "touch") { touches.set(current.pointerId, current.client); cancelStroke(); }
        touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        capture(c, e);
        startPinch();
        e.preventDefault();
        return;
      }
      if (e.button > 0 && e.pointerType === "mouse") return;
      if (current || erasing) return;
      e.preventDefault();
      capture(c, e);
      if (tool === "eraser") { erasing = { view: v, pointerId: e.pointerId, removed: [] }; eraseAt(v, e); return; }
      current = { view: v, pointerId: e.pointerId, pointerType: e.pointerType, start: e.timeStamp, points: [], tool, color: colorOf(tool), width: widthOf(tool) };
      addPoint(e);
      drawLive();
    });
    c.addEventListener("pointermove", (e) => {
      if (touches.has(e.pointerId)) { touches.set(e.pointerId, { x: e.clientX, y: e.clientY }); movePinch(); e.preventDefault(); return; }
      if (erasing?.pointerId === e.pointerId) { for (const ev of coalesced(e)) eraseAt(v, ev); return; }
      if (current?.pointerId !== e.pointerId) { if (tool === "eraser" && e.pointerType !== "touch") showEraser(v, e); return; }
      for (const ev of coalesced(e)) addPoint(ev);
      drawLive();
    });
    const end = (e) => {
      if (touches.delete(e.pointerId)) { startPinch(); return; }
      if (erasing?.pointerId === e.pointerId) { finishErase(); return; }
      if (current?.pointerId === e.pointerId) { if (e.type === "pointercancel") cancelStroke(); else finishStroke(); }
    };
    c.addEventListener("pointerup", end);
    c.addEventListener("pointercancel", end);
    c.addEventListener("pointerleave", () => { if (tool === "eraser" && !erasing) clearLive(v); });
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
    const minGap = 0.6 / (v.el.clientWidth / v.page.width); // ~0.6 screen pixels
    if (last && Math.hypot(last.x - x, last.y - y) < minGap) { last.p = Math.max(last.p, p); return; }
    current.points.push({ x, y, p: Math.max(0, Math.min(1, p)), t: Math.max(0, e.timeStamp - current.start) });
  }

  function drawLive() {
    const v = current.view;
    const k = sizeCanvas(v, v.live);
    const ctx = v.live.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, v.live.width, v.live.height);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    drawStroke(ctx, current);
  }

  function cancelStroke() {
    if (!current) return;
    clearLive(current.view);
    current = null;
  }

  function finishStroke() {
    const s = current;
    current = null;
    if (!s.points.length) return;
    const data = { page: s.view.index, tool: s.tool, color: s.color, width: s.width, points: s.points };
    const id = vault.addStroke({ on: itemId, layer, ...data });
    undo.push({ type: "add", data, id });
    redo.length = 0;
    edited = true;
    renderInk(s.view);
    clearLive(s.view);
    refreshToolbar();
    changed();
  }

  const eraserRadius = (v) => 9 / (v.el.clientWidth / v.page.width);

  function showEraser(v, e) {
    const k = sizeCanvas(v, v.live);
    const ctx = v.live.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, v.live.width, v.live.height);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    const { x, y } = toPage(v, e);
    ctx.beginPath();
    ctx.arc(x, y, eraserRadius(v), 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(120,120,128,0.9)";
    ctx.lineWidth = 1 / k * 1.5;
    ctx.stroke();
  }

  function eraseAt(v, e) {
    showEraser(v, e);
    const { x, y } = toPage(v, e);
    const gone = vault.strokes(itemId, layer, v.index).filter((s) => hits(s, x, y, eraserRadius(v)));
    if (!gone.length) return;
    vault.deleteStrokes(gone.map((s) => s.id));
    erasing.removed.push(...gone.map((s) => ({ page: s.page, tool: s.tool, color: s.color, width: s.width, points: s.points })));
    renderInk(v);
  }

  function finishErase() {
    const { view, removed } = erasing;
    erasing = null;
    clearLive(view);
    if (!removed.length) return;
    undo.push({ type: "erase", data: removed, ids: [] });
    redo.length = 0;
    edited = true;
    refreshToolbar();
    changed();
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
      scroller.scrollBy(pinch.cx - cx, pinch.cy - cy);
      pinch.cx = cx; pinch.cy = cy;
      const dist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      setZoom(pinch.zoom * dist / pinch.dist, { x: cx, y: cy });
    } else if (pts.length === 1 && pinch.x !== undefined) {
      scroller.scrollBy(pinch.x - pts[0].x, pinch.y - pts[0].y);
      pinch.x = pts[0].x; pinch.y = pts[0].y;
    }
  }

  function setZoom(z, anchor = null) {
    const next = Math.min(4, Math.max(0.5, z));
    if (Math.abs(next - zoom) < 0.001) return;
    const r = scroller.getBoundingClientRect();
    const ax = anchor ? anchor.x - r.left : r.width / 2, ay = anchor ? anchor.y - r.top : r.height / 2;
    const fx = (scroller.scrollLeft + ax) / Math.max(1, scroller.scrollWidth), fy = (scroller.scrollTop + ay) / Math.max(1, scroller.scrollHeight);
    zoom = next;
    layout();
    scroller.scrollLeft = fx * scroller.scrollWidth - ax;
    scroller.scrollTop = fy * scroller.scrollHeight - ay;
  }

  scroller.addEventListener("wheel", (e) => {
    if (!(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    setZoom(zoom * Math.exp(-e.deltaY / 300), { x: e.clientX, y: e.clientY });
  }, { passive: false });

  // ---------- undo, tools, pages ----------
  function doUndo() {
    const action = undo.pop();
    if (!action) return;
    if (action.type === "add") vault.deleteStrokes([action.id]);
    else action.ids = action.data.map((d) => vault.addStroke({ on: itemId, layer, ...d }));
    redo.push(action);
    afterHistory(action);
  }

  function doRedo() {
    const action = redo.pop();
    if (!action) return;
    if (action.type === "add") action.id = vault.addStroke({ on: itemId, layer, ...action.data });
    else vault.deleteStrokes(action.ids);
    undo.push(action);
    afterHistory(action);
  }

  function afterHistory(action) {
    edited = true;
    const pagesTouched = new Set(action.type === "add" ? [action.data.page] : action.data.map((d) => d.page));
    for (const v of views) if (pagesTouched.has(v.index)) renderInk(v);
    refreshToolbar();
    changed();
  }

  function setTool(id) {
    tool = id;
    prefs.tool = id;
    savePrefs(prefs);
    for (const v of views) clearLive(v);
    refreshToolbar();
  }

  function setColor(c) {
    if (tool === "eraser") setTool("pen");
    prefs.colors[tool] = c;
    savePrefs(prefs);
    refreshToolbar();
  }

  function refreshToolbar() {
    toolButtons.forEach((b, i) => b.setAttribute("aria-pressed", String(Object.keys(TOOL_INFO)[i] === tool)));
    const c = tool === "eraser" ? null : colorOf(tool);
    swatches.forEach((s, i) => s.setAttribute("aria-pressed", String(COLORS[i] === c)));
    if (c) custom.value = c;
    size.disabled = tool === "eraser";
    size.value = String(tool === "eraser" ? 10 : widthOf(tool));
    const d = Math.max(3, Math.min(22, tool === "eraser" ? 14 : widthOf(tool)));
    sizeDot.style.cssText = `width:${d}px;height:${d}px;background:${c ?? "transparent"};opacity:${tool === "highlighter" ? 0.5 : 1}`;
    undoButton.disabled = !undo.length;
    redoButton.disabled = !redo.length;
    root.dataset.tool = tool;
  }

  function addPage() {
    sketch.pageCount += 1;
    sketch.addPage();
    pages.push({ width: pages[0].width, height: pages[0].height });
    const v = addView(pages.length - 1);
    for (const x of views) x.el.querySelector(".ink-page-number").textContent = String(x.index + 1);
    layout();
    v.el.scrollIntoView({ behavior: "smooth", block: "start" });
    changed();
  }

  // Strokes from other devices show up as they sync.
  let pendingRemote = false;
  const unsubscribe = vault.onChange(() => {
    if (pendingRemote) return;
    pendingRemote = true;
    requestAnimationFrame(() => { pendingRemote = false; if (!current && !erasing) for (const v of views) { v.dirty = true; if (v.visible) renderView(v); } });
  });

  const onKey = (e) => {
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement?.tagName ?? "") && document.activeElement.type !== "range" && document.activeElement.type !== "color") return;
    const mod = e.metaKey || e.ctrlKey;
    let handled = true;
    if (mod && e.key.toLowerCase() === "z") e.shiftKey ? doRedo() : doUndo();
    else if (mod && e.key.toLowerCase() === "y") doRedo();
    else if (e.key === "Escape") close();
    else if (!mod && !e.altKey) {
      const id = Object.keys(TOOL_INFO).find((t) => TOOL_INFO[t].key === e.key.toLowerCase());
      if (id) setTool(id); else if (e.key === "+" || e.key === "=") setZoom(zoom * 1.25); else if (e.key === "-") setZoom(zoom / 1.25); else handled = false;
    } else handled = false;
    if (handled) { e.preventDefault(); e.stopImmediatePropagation(); }
  };
  document.addEventListener("keydown", onKey, true);
  const onResize = () => layout();
  addEventListener("resize", onResize);

  function close() {
    if (current) finishStroke();
    if (erasing) finishErase();
    io.disconnect();
    unsubscribe();
    document.removeEventListener("keydown", onKey, true);
    removeEventListener("resize", onResize);
    root.remove();
    document.body.classList.remove("ink-open");
    onClose(edited);
  }

  pages.forEach((_, i) => addView(i));
  refreshToolbar();
  requestAnimationFrame(() => {
    layout();
    views[Math.min(startPage, views.length - 1)]?.el.scrollIntoView({ block: "start" });
  });
  return { close };
}

/** A small JPEG of a sketch's first page (paper and ink), for its card. */
export async function sketchThumbnail(vault, item, maxWidth = 480) {
  const [w, hgt] = item.pageSize;
  const k = maxWidth / w;
  const canvas = h("canvas", { width: Math.round(w * k), height: Math.round(hgt * k) });
  const ctx = canvas.getContext("2d");
  ctx.setTransform(k, 0, 0, k, 0, 0);
  drawPaper(ctx, item.paper, w, hgt);
  drawStrokes(ctx, vault.strokes(item.id, "", 0));
  const blob = await new Promise((done) => canvas.toBlob(done, "image/jpeg", 0.82));
  return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
}

/** Draws a sketch page (paper and ink) into a canvas sized to `cssWidth`. */
export function renderSketchPage(canvas, vault, item, page, cssWidth) {
  const [w, hgt] = item.pageSize;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  canvas.width = Math.round(cssWidth * dpr);
  canvas.height = Math.round(cssWidth * dpr * hgt / w);
  const k = canvas.width / w;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(k, 0, 0, k, 0, 0);
  drawPaper(ctx, item.paper, w, hgt);
  drawStrokes(ctx, vault.strokes(item.id, "", page));
}
