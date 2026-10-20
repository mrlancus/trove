// The connections graph: items as glowing points, sized by how connected they are and coloured by
// their top folder. Links come from [[wikilinks]] and hand-made connections; shared tags and
// folders can join in as their own small nodes. Canvas 2D with a little force simulation.
import { h } from "./dom.js";
import { linkGraph } from "./core/links.js";
import { folderPathOf } from "./core/organize.js";

export const PALETTE = ["#ff9f43", "#ff4f8b", "#a55eea", "#54a0ff", "#1dd1a1", "#feca57", "#ff6b6b", "#48dbfb", "#c8d6e5"];

/** A colour per top-level folder, from its id, so it never changes when folders come and go. */
export function folderColor(topId) {
  if (!topId) return "#8395a7";
  let hash = 0;
  for (const ch of topId) hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
  return PALETTE[hash % (PALETTE.length - 1)];
}

/** Nodes and edges for the current options. */
export function buildGraph(items, folders, { tags = true, folderNodes = false, unlinked = false, focus = null, depth = 2 } = {}) {
  const links = linkGraph(items);
  const nodes = new Map(), edges = [];
  const topOf = (item) => (item.folder ? folderPathOf(item.folder, folders)[0]?.id ?? null : null);
  const addItem = (item) => {
    if (!nodes.has(item.id)) nodes.set(item.id, { id: item.id, type: "item", label: item.displayTitle, color: folderColor(topOf(item), folders), item, degree: 0 });
  };
  const byId = new Map(items.map((i) => [i.id, i]));
  for (const [from, tos] of Object.entries(links.outgoing)) for (const to of tos) {
    if (!byId.has(from) || !byId.has(to)) continue;
    addItem(byId.get(from)); addItem(byId.get(to));
    edges.push({ a: from, b: to, kind: "link" });
  }
  if (tags) {
    const byTag = new Map();
    for (const i of items) for (const t of i.tags) { if (!byTag.has(t)) byTag.set(t, []); byTag.get(t).push(i); }
    for (const [t, members] of byTag) {
      if (members.length < 2) continue;
      const id = `#${t}`;
      nodes.set(id, { id, type: "tag", label: `#${t}`, color: "#8395a7", degree: 0 });
      for (const m of members) { addItem(m); edges.push({ a: m.id, b: id, kind: "tag" }); }
    }
  }
  if (folderNodes) {
    for (const i of items) {
      if (!i.folder || (!nodes.has(i.id) && !unlinked)) continue;
      const f = folders.find((x) => x.id === i.folder);
      if (!f) continue;
      const id = `folder:${f.id}`;
      if (!nodes.has(id)) nodes.set(id, { id, type: "folder", label: f.name, color: folderColor(folderPathOf(f.id, folders)[0]?.id, folders), degree: 0 });
      addItem(i);
      edges.push({ a: i.id, b: id, kind: "folder" });
    }
  }
  if (unlinked) for (const i of items) addItem(i);
  for (const e of edges) { nodes.get(e.a).degree++; nodes.get(e.b).degree++; }
  if (focus) {
    const keep = new Set([focus]);
    let frontier = [focus];
    for (let d = 0; d < depth; d++) {
      const next = [];
      for (const e of edges) for (const [x, y] of [[e.a, e.b], [e.b, e.a]]) if (frontier.includes(x) && !keep.has(y)) { keep.add(y); next.push(y); }
      frontier = next;
    }
    if (!nodes.has(focus) && byId.has(focus)) addItem(byId.get(focus));
    keep.add(focus);
    return { nodes: [...nodes.values()].filter((n) => keep.has(n.id)), edges: edges.filter((e) => keep.has(e.a) && keep.has(e.b)) };
  }
  return { nodes: [...nodes.values()], edges };
}

/**
 * Draws a graph into `container`. Returns a function that stops it.
 * options: {onOpen(id), focus, compact}
 */
export function graphCanvas(container, data, { onOpen, focus = null, compact = false } = {}) {
  const canvas = h("canvas", { class: "graph-canvas", role: "img", "aria-label": `Connections graph with ${data.nodes.length} items` });
  const tip = h("div", { class: "graph-tip", hidden: true });
  container.replaceChildren(canvas, tip);
  const ctx = canvas.getContext("2d");
  const nodes = data.nodes.map((n, i) => {
    const angle = i * 2.399963, r = 30 * Math.sqrt(i + 1);
    return { ...n, x: Math.cos(angle) * r, y: Math.sin(angle) * r, vx: 0, vy: 0, r: n.type === "item" ? 4 + Math.min(10, Math.sqrt(n.degree) * 2.4) : n.type === "folder" ? 9 : 3.5 };
  });
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const edges = data.edges.map((e) => ({ ...e, a: byId.get(e.a), b: byId.get(e.b) })).filter((e) => e.a && e.b);
  const neighbours = new Map(nodes.map((n) => [n.id, new Set()]));
  for (const e of edges) { neighbours.get(e.a.id).add(e.b.id); neighbours.get(e.b.id).add(e.a.id); }
  let view = { x: 0, y: 0, k: compact ? 1.1 : 1 }, alpha = 1, hover = null, dragging = null, raf = 0, stopped = false;
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue("--fg").trim() || "#222", muted = css.getPropertyValue("--muted").trim() || "#888", accent = css.getPropertyValue("--accent").trim() || "#e8661a";

  const resize = () => {
    const r = container.getBoundingClientRect(), dpr = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.max(1, r.width * dpr); canvas.height = Math.max(1, r.height * dpr);
    canvas.style.width = `${r.width}px`; canvas.style.height = `${r.height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    draw();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(container);

  const step = () => {
    const n = nodes.length;
    for (let i = 0; i < n; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < n; j++) {
        const b = nodes[j];
        let dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy;
        if (d2 > 90000) continue;
        if (d2 < 1) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; d2 = 1; }
        const f = (900 * alpha) / d2;
        a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f;
      }
    }
    for (const e of edges) {
      const dx = e.b.x - e.a.x, dy = e.b.y - e.a.y, d = Math.hypot(dx, dy) || 1;
      const rest = e.kind === "link" ? 70 : e.kind === "folder" ? 55 : 45;
      const f = ((d - rest) / d) * (e.kind === "link" ? 0.06 : 0.035) * alpha;
      e.a.vx += dx * f; e.a.vy += dy * f; e.b.vx -= dx * f; e.b.vy -= dy * f;
    }
    for (const p of nodes) {
      p.vx -= p.x * 0.004 * alpha; p.vy -= p.y * 0.004 * alpha;
      if (p === dragging) { p.vx = p.vy = 0; continue; }
      p.vx *= 0.6; p.vy *= 0.6;
      p.x += p.vx; p.y += p.vy;
    }
    alpha = Math.max(0, alpha * 0.985 - 0.0005);
  };

  const toScreen = (p) => {
    const r = canvas.getBoundingClientRect();
    return [r.width / 2 + (p.x + view.x) * view.k, r.height / 2 + (p.y + view.y) * view.k];
  };
  const toWorld = (sx, sy) => {
    const r = canvas.getBoundingClientRect();
    return [(sx - r.width / 2) / view.k - view.x, (sy - r.height / 2) / view.k - view.y];
  };

  function draw() {
    const r = canvas.getBoundingClientRect();
    ctx.clearRect(0, 0, r.width, r.height);
    const lit = hover ? neighbours.get(hover.id) : null;
    const isLit = (n) => !hover || n === hover || lit.has(n.id);
    ctx.lineWidth = 1;
    for (const e of edges) {
      const [x1, y1] = toScreen(e.a), [x2, y2] = toScreen(e.b);
      const on = hover && (e.a === hover || e.b === hover);
      ctx.strokeStyle = on ? accent : muted;
      ctx.globalAlpha = on ? 0.9 : hover ? 0.06 : e.kind === "link" ? 0.45 : 0.18;
      ctx.setLineDash(e.kind === "link" ? [] : [3, 4]);
      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    }
    ctx.setLineDash([]);
    for (const n of nodes) {
      const [x, y] = toScreen(n), rad = n.r * Math.sqrt(view.k);
      ctx.globalAlpha = isLit(n) ? 1 : 0.15;
      if (n.type === "item") {
        const glow = ctx.createRadialGradient(x, y, 0, x, y, rad * 2.6);
        glow.addColorStop(0, n.color + "66"); glow.addColorStop(1, n.color + "00");
        ctx.fillStyle = glow;
        ctx.beginPath(); ctx.arc(x, y, rad * 2.6, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = n.color;
        ctx.beginPath(); ctx.arc(x, y, rad, 0, Math.PI * 2); ctx.fill();
        if (n.id === focus) { ctx.strokeStyle = fg; ctx.lineWidth = 2; ctx.stroke(); ctx.lineWidth = 1; }
      } else if (n.type === "tag") {
        ctx.fillStyle = muted;
        ctx.save(); ctx.translate(x, y); ctx.rotate(Math.PI / 4); ctx.fillRect(-rad, -rad, rad * 2, rad * 2); ctx.restore();
      } else {
        ctx.fillStyle = n.color;
        ctx.beginPath(); ctx.roundRect(x - rad, y - rad * 0.8, rad * 2, rad * 1.6, 3); ctx.fill();
      }
      const showLabel = n === hover || (lit && lit.has(n.id)) || n.id === focus || view.k > 1.7 || (view.k > 0.75 && n.degree >= 3) || nodes.length <= (compact ? 14 : 40);
      if (showLabel && ctx.globalAlpha > 0.5) {
        ctx.fillStyle = n.type === "item" ? fg : muted;
        ctx.font = `${n === hover ? 600 : 500} ${n.type === "item" ? 12 : 11}px -apple-system, system-ui, sans-serif`;
        ctx.textAlign = "center";
        const label = n.label.length > 34 ? n.label.slice(0, 33) + "…" : n.label;
        ctx.fillText(label, x, y + rad + 13);
      }
    }
    ctx.globalAlpha = 1;
  }

  const loop = () => {
    if (stopped) return;
    if (alpha > 0.002 || dragging) step();
    draw();
    raf = requestAnimationFrame(loop);
  };
  raf = requestAnimationFrame(loop);

  const hit = (sx, sy) => {
    const [wx, wy] = toWorld(sx, sy);
    let best = null, bestD = Infinity;
    for (const n of nodes) {
      const d = Math.hypot(n.x - wx, n.y - wy);
      if (d < Math.max(10, n.r + 6) / view.k && d < bestD) { best = n; bestD = d; }
    }
    return best;
  };
  const pointers = new Map();
  let pan = null, moved = 0, pinch = null;
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, [e.offsetX, e.offsetY]);
    moved = 0;
    if (pointers.size === 2) {
      const [[x1, y1], [x2, y2]] = [...pointers.values()];
      pinch = { d: Math.hypot(x2 - x1, y2 - y1), k: view.k };
      dragging = null; pan = null;
      return;
    }
    const n = hit(e.offsetX, e.offsetY);
    if (n) { dragging = n; alpha = Math.max(alpha, 0.3); } else pan = { x: e.offsetX, y: e.offsetY, vx: view.x, vy: view.y };
  });
  canvas.addEventListener("pointermove", (e) => {
    if (pointers.has(e.pointerId)) pointers.set(e.pointerId, [e.offsetX, e.offsetY]);
    if (pinch && pointers.size === 2) {
      const [[x1, y1], [x2, y2]] = [...pointers.values()];
      view.k = Math.min(4, Math.max(0.2, pinch.k * Math.hypot(x2 - x1, y2 - y1) / pinch.d));
      return;
    }
    if (dragging) {
      const [wx, wy] = toWorld(e.offsetX, e.offsetY);
      dragging.x = wx; dragging.y = wy; moved++;
      return;
    }
    if (pan) {
      view.x = pan.vx + (e.offsetX - pan.x) / view.k; view.y = pan.vy + (e.offsetY - pan.y) / view.k; moved++;
      return;
    }
    const n = hit(e.offsetX, e.offsetY);
    if (n !== hover) {
      hover = n;
      canvas.style.cursor = n ? "pointer" : "grab";
      tip.hidden = !n || n.type === "item";
      if (n && n.type !== "item") { tip.textContent = `${n.label} · ${n.degree}`; tip.style.left = `${e.offsetX + 12}px`; tip.style.top = `${e.offsetY + 12}px`; }
    }
  });
  const end = (e) => {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
    if (dragging && moved < 3 && dragging.type === "item") onOpen?.(dragging.id);
    dragging = null; pan = null;
  };
  canvas.addEventListener("pointerup", end);
  canvas.addEventListener("pointercancel", end);
  canvas.addEventListener("pointerleave", () => { if (!pointers.size) hover = null; });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const [wx, wy] = toWorld(e.offsetX, e.offsetY);
    view.k = Math.min(4, Math.max(0.2, view.k * Math.exp(-e.deltaY * 0.0015)));
    const [nx, ny] = toWorld(e.offsetX, e.offsetY);
    view.x += nx - wx; view.y += ny - wy;
  }, { passive: false });

  return {
    stop() { stopped = true; cancelAnimationFrame(raf); ro.disconnect(); },
    highlight(query) {
      const q = query.trim().toLowerCase();
      hover = q ? nodes.find((n) => n.label.toLowerCase().includes(q)) ?? null : null;
    },
  };
}
