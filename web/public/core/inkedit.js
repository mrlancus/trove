// Editing ink faster (ROADMAP S3, PROTOCOL.md §10 "Editing"): turning and flipping elements,
// shapes from the shape picker with handles you can drag, connectors that follow the shapes they
// join, the ruler and protractor, straightening and the elements library
// (`sticker` records). A port of InkEditing.swift / InkStickers.swift; both check
// Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-editing.json (made by web/test/make-editing-fixture.mjs).
import { bounds, CLOSED_SHAPES, pointFields, strokePoints, transformPoint } from "./ink.js";

const TAU = Math.PI * 2;
/** An angle in (−π, π], with tiny values made 0. */
export function normalAngle(a) {
  let out = a % TAU;
  if (out > Math.PI) out -= TAU;
  if (out <= -Math.PI) out += TAU;
  return Math.abs(out) < 1e-9 ? 0 : out;
}

// ---------- elements: turning and flipping ----------

/** The four corners of an element as drawn (turned about its centre by `rotate`). */
export function elementCorners(e) {
  const cx = e.x + e.w / 2, cy = e.y + e.h / 2, c = Math.cos(e.rotate || 0), s = Math.sin(e.rotate || 0);
  return [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([u, v]) => {
    const x = (u * e.w) / 2, y = (v * e.h) / 2;
    return { x: cx + c * x - s * y, y: cy + s * x + c * y };
  });
}

/** The box around an element as drawn. */
export const elementBounds = (e) => (e.rotate ? bounds(elementCorners(e)) : { x: e.x, y: e.y, w: e.w, h: e.h });

/** A page point in the element's own (unturned) box, so hit tests can use x, y, w, h. */
export function toElementSpace(e, p) {
  if (!e.rotate) return { x: p.x, y: p.y };
  const cx = e.x + e.w / 2, cy = e.y + e.h / 2, c = Math.cos(-e.rotate), s = Math.sin(-e.rotate);
  const x = p.x - cx, y = p.y - cy;
  return { x: cx + c * x - s * y, y: cy + s * x + c * y };
}

/** True if a page point is on the element (its turned box). `h` overrides its height (a text box's wrapped lines). */
export function elementContains(e, p, h = e.h) {
  const q = toElementSpace({ ...e, h }, p);
  return q.x >= e.x && q.x <= e.x + e.w && q.y >= e.y && q.y <= e.y + h;
}

/**
 * An element after a lasso transform: its centre moves like a point, its size scales by |sx|, |sy|,
 * and it turns with `r`. A mirror (one of sx, sy negative) turns it the other way; a picture is
 * mirrored too (`flip`), and flipped upside down it turns half round as well. Text and tape stay
 * readable (never mirrored). Returns {x, y, w, h, rotate, flip}.
 */
export function transformElement(t, e) {
  const cx = e.x + e.w / 2, cy = e.y + e.h / 2;
  const c = transformPoint(t, { x: cx, y: cy });
  const w = e.w * Math.abs(t.sx), h = e.h * Math.abs(t.sy);
  const mirror = (t.sx < 0) !== (t.sy < 0), both = t.sx < 0 && t.sy < 0, image = e.type === "image";
  let rotate = mirror ? -(e.rotate || 0) : e.rotate || 0;
  if (both) rotate += Math.PI;
  if (mirror && image && t.sy < 0) rotate += Math.PI;
  rotate = normalAngle(rotate + (t.r || 0));
  return { x: c.x - w / 2, y: c.y - h / 2, w, h, rotate, flip: image && mirror ? !e.flip : Boolean(e.flip) };
}

/** Turning by `r` about (ox, oy); flipping left–right (`axis` "x") or upside down ("y") about it. */
export const rotateAbout = (r, ox, oy) => ({ sx: 1, sy: 1, ox, oy, dx: 0, dy: 0, r });
export const flipAbout = (axis, ox, oy) => ({ sx: axis === "x" ? -1 : 1, sy: axis === "y" ? -1 : 1, ox, oy, dx: 0, dy: 0 });

/** A turn snapped to the nearest 15° when within 3° of it (the rotate handle). */
export function snapRotation(r) {
  const step = Math.PI / 12, near = Math.round(r / step) * step;
  return Math.abs(r - near) <= (3 * Math.PI) / 180 ? normalAngle(near) : normalAngle(r);
}

// ---------- shapes from the picker ----------

/** The shapes the picker draws (plus `line`; an arrow is a `line` with `arrow`). */
export const PICKER_SHAPES = ["line", "rectangle", "ellipse", "circle", "triangle", "diamond", "star", "heart", "bubble"];
export const CURVE_STEPS = 32;

const pt = (x, y) => ({ x, y, p: 0.5, t: 0 });
/** Points scaled so their box is exactly `box`. */
function fit(points, box) {
  const b = bounds(points);
  const kx = b.w ? box.w / b.w : 0, ky = b.h ? box.h / b.h : 0;
  return points.map((p) => pt(box.x + (p.x - b.x) * kx, box.y + (p.y - b.y) * ky));
}
const closeLoop = (pts) => [...pts, { ...pts[0] }];

/**
 * A clean shape filling the box dragged from `a` to `b` (page points), as stroke points (pressure
 * 0.5, time 0). Closed shapes end where they start. `line` runs from a to b.
 */
export function shapePoints(shape, a, b) {
  const box = { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) };
  const { x, y, w, h } = box;
  switch (shape) {
    case "line": return [pt(a.x, a.y), pt(b.x, b.y)];
    case "rectangle": return closeLoop([pt(x, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)]);
    case "triangle": return closeLoop([pt(x + w / 2, y), pt(x + w, y + h), pt(x, y + h)]);
    case "diamond": return closeLoop([pt(x + w / 2, y), pt(x + w, y + h / 2), pt(x + w / 2, y + h), pt(x, y + h / 2)]);
    case "circle":
    case "ellipse": {
      const r = Math.min(w, h) / 2, cx = x + w / 2, cy = y + h / 2;
      const rx = shape === "circle" ? r : w / 2, ry = shape === "circle" ? r : h / 2;
      return Array.from({ length: 65 }, (_, i) => { const t = (i / 64) * TAU; return pt(cx + rx * Math.cos(t), cy + ry * Math.sin(t)); });
    }
    case "star": {
      const raw = Array.from({ length: 10 }, (_, i) => {
        const r = i % 2 ? 0.382 : 1, t = -Math.PI / 2 + (i * Math.PI) / 5;
        return pt(r * Math.cos(t), r * Math.sin(t));
      });
      return closeLoop(fit(raw, box));
    }
    case "heart": {
      const raw = Array.from({ length: 48 }, (_, i) => {
        const t = (i / 48) * TAU;
        return pt(16 * Math.sin(t) ** 3, -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t)));
      });
      return closeLoop(fit(raw, box));
    }
    case "bubble": {
      // A rounded box over the top 80 %, with a tail down to the left.
      const by = y + h * 0.8, r = Math.min(w, h * 0.8) * 0.15;
      const corner = (cx, cy, from) => Array.from({ length: 5 }, (_, i) => { const t = from + (i / 4) * (Math.PI / 2); return pt(cx + r * Math.cos(t), cy + r * Math.sin(t)); });
      return closeLoop([
        ...corner(x + w - r, y + r, -Math.PI / 2), ...corner(x + w - r, by - r, 0),
        pt(x + w * 0.4, by), pt(x + w * 0.15, y + h), pt(x + w * 0.25, by),
        ...corner(x + r, by - r, Math.PI / 2), ...corner(x + r, y + r, Math.PI),
      ]);
    }
    default: return null;
  }
}

/** A quadratic curve from a to b bent towards c, as CURVE_STEPS + 1 points (the middle one is where it bends most). */
export function curvePoints(a, c, b, p = 0.5) {
  return Array.from({ length: CURVE_STEPS + 1 }, (_, i) => {
    const t = i / CURVE_STEPS, u = 1 - t;
    return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y, p, t: 0 };
  });
}

const isClosed = (pts) => pts.length > 2 && Math.hypot(pts[0].x - pts.at(-1).x, pts[0].y - pts.at(-1).y) < 1e-6;
/** Shapes whose corners can be dragged one by one. */
const CORNERED = ["polyline", "triangle", "rectangle", "polygon", "diamond"];

/**
 * The handles a clean shape shows when it's selected on its own: a line's ends and its middle
 * (drag it to bend the line), a curve's ends and its middle point, a polyline's or polygon's
 * corners. Others (circles, stars, hearts, bubbles) have none; they resize and turn with the box.
 */
export function shapeHandles(s) {
  const pts = s.points;
  if (s.shape === "line" && pts.length >= 2) {
    const a = pts[0], b = pts.at(-1);
    return [pt(a.x, a.y), pt(b.x, b.y), pt((a.x + b.x) / 2, (a.y + b.y) / 2)];
  }
  if (s.shape === "curve" && pts.length >= 3) {
    const m = pts[Math.floor(pts.length / 2)];
    return [pt(pts[0].x, pts[0].y), pt(pts.at(-1).x, pts.at(-1).y), pt(m.x, m.y)];
  }
  if (CORNERED.includes(s.shape)) return (isClosed(pts) ? pts.slice(0, -1) : pts).map((p) => pt(p.x, p.y));
  return [];
}

/**
 * The shape with handle `index` dragged to `to`: {shape, points}. A line's middle handle bends it
 * into a `curve` through `to`; a moved rectangle corner makes it a `polygon`.
 */
export function moveShapeHandle(s, index, to) {
  const pts = s.points, p = pts[0]?.p ?? 0.5;
  if (s.shape === "line" || s.shape === "curve") {
    const [a, b, m] = shapeHandles(s);
    if (index === 2) {
      const c = { x: 2 * to.x - (a.x + b.x) / 2, y: 2 * to.y - (a.y + b.y) / 2 };
      return { shape: "curve", points: curvePoints(a, c, b, p) };
    }
    const a2 = index === 0 ? to : a, b2 = index === 1 ? to : b;
    if (s.shape === "line") return { shape: "line", points: [{ ...pts[0], x: a2.x, y: a2.y }, { ...pts.at(-1), x: b2.x, y: b2.y }] };
    const c = { x: 2 * m.x - (a.x + b.x) / 2, y: 2 * m.y - (a.y + b.y) / 2 };
    return { shape: "curve", points: curvePoints(a2, c, b2, p) };
  }
  if (!CORNERED.includes(s.shape)) return { shape: s.shape, points: pts };
  const closed = isClosed(pts);
  const out = pts.map((q) => ({ ...q }));
  out[index] = { ...out[index], x: to.x, y: to.y };
  if (closed && index === 0) out[out.length - 1] = { ...out[0] };
  return { shape: s.shape === "rectangle" ? "polygon" : s.shape, points: out };
}

// ---------- connectors ----------

/** Things a connector can join: closed shapes and any element. */
export const connectable = (s) => Boolean(s.shape && CLOSED_SHAPES.includes(s.shape) && !s.from && !s.to);
export const CONNECTOR_GAP = 4;

/** Where a line from the box's centre towards `toward` leaves the box, `gap` further out; the centre if `toward` is inside. */
export function boxExit(box, toward, gap = CONNECTOR_GAP) {
  const cx = box.x + box.w / 2, cy = box.y + box.h / 2, dx = toward.x - cx, dy = toward.y - cy;
  if (!dx && !dy) return { x: cx, y: cy };
  const k = Math.min(dx ? box.w / 2 / Math.abs(dx) : Infinity, dy ? box.h / 2 / Math.abs(dy) : Infinity);
  if (k >= 1) return { x: cx, y: cy };
  const d = Math.hypot(dx, dy), g = Math.min(gap / d, 1 - k);
  return { x: cx + dx * (k + g), y: cy + dy * (k + g) };
}

/**
 * A connector's ends: an end joined to a box (`fromBox`, `toBox`) sits where the line between the
 * boxes' centres (or the free end) leaves that box; a free end stays at `a` or `b`.
 */
export function connectorEnds(a, b, fromBox, toBox) {
  const ca = fromBox ? { x: fromBox.x + fromBox.w / 2, y: fromBox.y + fromBox.h / 2 } : a;
  const cb = toBox ? { x: toBox.x + toBox.w / 2, y: toBox.y + toBox.h / 2 } : b;
  return [fromBox ? boxExit(fromBox, cb) : { x: a.x, y: a.y }, toBox ? boxExit(toBox, ca) : { x: b.x, y: b.y }];
}

// ---------- ruler and protractor (on this device only) ----------

export const RULER_LENGTH = 720, RULER_WIDTH = 64, PROTRACTOR_RADIUS = 160;

/** A point in the ruler's frame: u along it from its centre, v across it (positive below when level). */
function local(tool, p) {
  const c = Math.cos(tool.angle), s = Math.sin(tool.angle), dx = p.x - tool.x, dy = p.y - tool.y;
  return { u: dx * c + dy * s, v: -dx * s + dy * c };
}
function world(tool, u, v) {
  const c = Math.cos(tool.angle), s = Math.sin(tool.angle);
  return { x: tool.x + u * c - v * s, y: tool.y + u * s + v * c };
}

/** The ruler's edge a point is within `tolerance` of: −1 (top), 1 (bottom) or 0 (neither). */
export function rulerEdge(ruler, p, tolerance) {
  const { u, v } = local(ruler, p), half = (ruler.length ?? RULER_LENGTH) / 2, w = (ruler.width ?? RULER_WIDTH) / 2;
  if (Math.abs(u) > half + tolerance) return 0;
  const top = Math.abs(v + w), bottom = Math.abs(v - w);
  if (Math.min(top, bottom) > tolerance) return 0;
  return top <= bottom ? -1 : 1;
}

/** A point moved onto a ruler edge (−1 top, 1 bottom), pressure and time kept. */
export function onRulerEdge(ruler, edge, p) {
  const { u } = local(ruler, p), w = (ruler.width ?? RULER_WIDTH) / 2;
  return { ...p, ...world(ruler, u, edge * w) };
}

/** True if a point is on the ruler's body (where dragging moves it). */
export function onRuler(ruler, p) {
  const { u, v } = local(ruler, p);
  return Math.abs(u) <= (ruler.length ?? RULER_LENGTH) / 2 && Math.abs(v) <= (ruler.width ?? RULER_WIDTH) / 2;
}

/** The angle shown on a tool, in degrees from 0 to 180, counter-clockwise from level (as maths draws it). */
export function toolDegrees(angle) {
  const d = ((-angle * 180) / Math.PI) % 180;
  const out = d < 0 ? d + 180 : d;
  return out >= 180 - 1e-9 || out === 0 ? 0 : out;
}

/** True if a point is within `tolerance` of the protractor's arc (the half above its base line). */
export function onProtractorArc(pro, p, tolerance) {
  const { u, v } = local(pro, p);
  return v <= tolerance && Math.abs(Math.hypot(u, v) - (pro.radius ?? PROTRACTOR_RADIUS)) <= tolerance;
}

/** A point moved onto the protractor's arc. */
export function onArc(pro, p) {
  const { u, v } = local(pro, p), r = pro.radius ?? PROTRACTOR_RADIUS;
  // The upper half only: below the base line, the nearer end of the arc.
  const a = v <= 0 ? Math.atan2(v, u) : u >= 0 ? 0 : -Math.PI;
  return { ...p, ...world(pro, r * Math.cos(a), r * Math.sin(a)) };
}

/** The angle of a point seen from the protractor's centre, 0 to 180 degrees from its base line. */
export function protractorDegrees(pro, p) {
  const { u, v } = local(pro, p);
  const d = (Math.atan2(-v, u) * 180) / Math.PI;
  return Math.max(0, Math.min(180, d));
}

// ---------- straighten ----------

/**
 * The turn (radians) that levels ink written on a slant: the main direction of the points (their
 * principal axis) brought to the nearest of level or upright. 0 for fewer than 2 points or no direction.
 */
export function straightenAngle(points) {
  if (points.length < 2) return 0;
  let mx = 0, my = 0;
  for (const p of points) { mx += p.x; my += p.y; }
  mx /= points.length; my /= points.length;
  let sxx = 0, syy = 0, sxy = 0;
  for (const p of points) { const dx = p.x - mx, dy = p.y - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy; }
  if (sxx + syy < 1e-9) return 0;
  const theta = 0.5 * Math.atan2(2 * sxy, sxx - syy);
  const quarter = Math.PI / 2;
  let off = theta - Math.round(theta / quarter) * quarter;
  if (Math.abs(off) < 1e-9) off = 0;
  return off === 0 ? 0 : -off;
}

// ---------- groups ----------

/** The ids picked plus every other member of their groups. `all` is [{id, group}] on the page. */
export function withGroups(ids, all) {
  const picked = new Set(ids);
  const groups = new Set(all.filter((x) => picked.has(x.id) && x.group).map((x) => x.group));
  if (!groups.size) return [...picked];
  for (const x of all) if (x.group && groups.has(x.group)) picked.add(x.id);
  return [...picked];
}

// ---------- the elements library (`sticker` records) ----------

export const STICKER_KIND = "sticker";
const STROKE_KEYS = ["tool", "color", "width", "shape", "fill", "dash", "arrow", "nib"];
const ELEMENT_KEYS = ["type", "x", "y", "w", "h", "text", "size", "color", "image", "rotate", "flip", "font", "bold", "italic"];

/**
 * A sticker's fields from strokes and elements on a page (views from ink.js), moved so their box
 * starts at 0, 0: {name, folder, w, h, strokes: [...], elements: [...]}. Strokes keep their look;
 * points are `points2` when the vault writes compact points.
 */
export function stickerFields({ name, folder = "", strokes = [], elements = [], compact = false }) {
  let box = null;
  const grow = (b) => { if (!b) return; box = box ? { x: Math.min(box.x, b.x), y: Math.min(box.y, b.y), x2: Math.max(box.x2, b.x + b.w), y2: Math.max(box.y2, b.y + b.h) } : { x: b.x, y: b.y, x2: b.x + b.w, y2: b.y + b.h }; };
  for (const s of strokes) grow(bounds(s.points, s.width / 2));
  for (const e of elements) grow(elementBounds(e));
  const ox = box?.x ?? 0, oy = box?.y ?? 0;
  const out = {
    name: String(name || "Element").slice(0, 80), folder: String(folder ?? "").slice(0, 80),
    w: box ? box.x2 - box.x : 0, h: box ? box.y2 - box.y : 0,
    strokes: strokes.map((s) => {
      const f = {};
      for (const k of STROKE_KEYS) if (s[k] !== null && s[k] !== undefined && s[k] !== "") f[k] = s[k];
      return { ...f, ...pointFields(s.points.map((p) => ({ ...p, x: p.x - ox, y: p.y - oy })), compact) };
    }),
    elements: elements.map((e) => {
      const f = {};
      for (const k of ELEMENT_KEYS) if (e[k] !== null && e[k] !== undefined && e[k] !== "" && e[k] !== false && !(k === "rotate" && !e[k]) && !(k === "font" && e[k] === "sans")) f[k] = e[k];
      f.x = e.x - ox; f.y = e.y - oy;
      return f;
    }),
  };
  return out;
}

const str = (v, d = "") => (typeof v === "string" ? v : d);
const num = (v, d = 0) => (typeof v === "number" && Number.isFinite(v) ? v : d);

/** A sticker record (or a built-in's fields) as {id, name, folder, w, h, strokes, elements, builtin}. Bad entries are dropped. */
export function stickerView(id, f, builtin = false) {
  const strokes = (Array.isArray(f.strokes) ? f.strokes : []).filter((s) => s && typeof s === "object").map((s) => ({
    tool: str(s.tool, "pen"), color: str(s.color, "#000000"), width: num(s.width, 2), shape: typeof s.shape === "string" ? s.shape : null,
    fill: typeof s.fill === "string" ? s.fill : null, dash: typeof s.dash === "string" ? s.dash : null, arrow: typeof s.arrow === "string" ? s.arrow : null,
    nib: typeof s.nib === "number" ? s.nib : null, points: Array.isArray(s.points) ? s.points.map(([x, y, p = 0.5, t = 0]) => ({ x, y, p, t })) : strokePoints(s),
  })).filter((s) => s.points.length);
  const elements = (Array.isArray(f.elements) ? f.elements : []).filter((e) => e && typeof e === "object" && ["text", "image", "tape"].includes(e.type)).map((e) => ({
    type: e.type, x: num(e.x), y: num(e.y), w: Math.max(1, num(e.w, 100)), h: Math.max(1, num(e.h, 40)), text: str(e.text), size: num(e.size, 20),
    color: str(e.color, "#000000"), image: e.image && typeof e.image.id === "string" ? e.image : null, rotate: num(e.rotate), flip: e.flip === true,
    font: str(e.font, "sans"), bold: e.bold === true, italic: e.italic === true,
  }));
  return { id, name: str(f.name, "Element"), folder: str(f.folder), w: num(f.w), h: num(f.h), strokes, elements, builtin };
}

/**
 * What placing a sticker adds: its strokes and elements moved so its box is centred on `at` (and
 * scaled by `scale`), ready for addStroke / addElement.
 */
export function placeSticker(sticker, at, scale = 1) {
  const ox = at.x - (sticker.w * scale) / 2, oy = at.y - (sticker.h * scale) / 2;
  return {
    strokes: sticker.strokes.map((s) => ({
      tool: s.tool, color: s.color, width: s.width * scale, shape: s.shape,
      style: { fill: s.fill, dash: s.dash, arrow: s.arrow, nib: s.nib },
      points: s.points.map((p) => ({ ...p, x: ox + p.x * scale, y: oy + p.y * scale })),
    })),
    elements: sticker.elements.map((e) => ({ ...e, x: ox + e.x * scale, y: oy + e.y * scale, w: e.w * scale, h: e.h * scale, size: e.size * scale })),
  };
}

/** The elements Trove comes with (not records; the same on every device). Points as [x, y]. */
export function builtInStickers() {
  const line = (a, b) => [[a[0], a[1]], [b[0], b[1]]];
  const flat = (pts) => pts.map((p) => [p.x, p.y]);
  const box = (x, y, w, h) => flat(shapePoints("rectangle", { x, y }, { x: x + w, y: y + h }));
  const s = (points, more) => ({ tool: "pen", color: "#1c1c1e", width: 3, ...more, points });
  const list = [
    ["arrow-right", "Arrow", "Arrows", [s(line([0, 12], [120, 12]), { shape: "line", arrow: "end" })]],
    ["arrow-both", "Two-way arrow", "Arrows", [s(line([0, 12], [120, 12]), { shape: "line", arrow: "both" })]],
    ["arrow-curve", "Curved arrow", "Arrows", [s(flat(curvePoints({ x: 0, y: 60 }, { x: 60, y: -20 }, { x: 120, y: 60 })), { shape: "curve" })]],
    ["checkbox", "Checkbox", "Checkboxes", [s(box(0, 0, 28, 28), { shape: "rectangle", width: 2.5 })]],
    ["checkbox-ticked", "Ticked box", "Checkboxes", [s(box(0, 0, 28, 28), { shape: "rectangle", width: 2.5 }),
      s([[6, 15], [12, 22], [24, 6]], { shape: "polyline", color: "#34c759", width: 3.5 })]],
    ["divider", "Divider", "Dividers", [s(line([0, 0], [480, 0]), { shape: "line", color: "#8e8e93", width: 2 })]],
    ["divider-dots", "Dotted divider", "Dividers", [s(line([0, 0], [480, 0]), { shape: "line", color: "#8e8e93", width: 3, dash: "dot" })]],
    ["star", "Star", "Shapes", [s(flat(shapePoints("star", { x: 0, y: 0 }, { x: 60, y: 57 })), { shape: "star", color: "#ff9500", fill: "#ffd60a", width: 2 })]],
    ["heart", "Heart", "Shapes", [s(flat(shapePoints("heart", { x: 0, y: 0 }, { x: 60, y: 54 })), { shape: "heart", color: "#ff3b30", fill: "#ff6b6b", width: 2 })]],
  ];
  const tags = [["important", "Important", "#ff3b30", "#ffe1e1"], ["todo", "To do", "#0a84ff", "#e1efff"], ["done", "Done", "#34c759", "#e3f7e8"],
    ["due", "Due", "#ff9500", "#fff0db"]];
  const out = list.map(([id, name, folder, strokes]) => ({ id: `builtin.${id}`, name, folder, strokes }));
  for (const [id, name, color, fill] of tags) {
    out.push({ id: `builtin.${id}`, name, folder: "Planner", strokes: [s(box(0, 0, 120, 36), { shape: "rectangle", color, fill, width: 2 })],
      elements: [{ type: "text", x: 12, y: 7, w: 100, h: 22, text: name, size: 18, color, bold: true }] });
  }
  return out.map((b) => {
    const strokes = b.strokes.map((x) => ({ ...x, points: x.points.map(([px, py]) => [px, py, 0.5, 0]) }));
    let bx = null;
    for (const x of strokes) {
      const r = bounds(x.points.map(([px, py]) => ({ x: px, y: py })), x.width / 2);
      bx = bx ? { x: Math.min(bx.x, r.x), y: Math.min(bx.y, r.y), x2: Math.max(bx.x2, r.x + r.w), y2: Math.max(bx.y2, r.y + r.h) } : { x: r.x, y: r.y, x2: r.x + r.w, y2: r.y + r.h };
    }
    // Moved so the box starts at 0, 0, like a saved sticker.
    const moved = strokes.map((x) => ({ ...x, points: x.points.map(([px, py, p, t]) => [px - bx.x, py - bx.y, p, t]) }));
    const elements = (b.elements ?? []).map((e) => ({ ...e, x: e.x - bx.x, y: e.y - bx.y }));
    return stickerView(b.id, { name: b.name, folder: b.folder, w: bx.x2 - bx.x, h: bx.y2 - bx.y, strokes: moved, elements }, true);
  });
}

