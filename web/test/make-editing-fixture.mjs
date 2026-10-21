// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-editing.json from core/inkedit.js and
// ink.js, so Swift's InkEditing and InkStickers are checked against the website's.
// Run: node test/make-editing-fixture.mjs
import { writeFileSync } from "node:fs";
import { transformAngle, transformPoint, transformRect } from "../public/core/ink.js";
import {
  boxExit, builtInStickers, connectorEnds, curvePoints, elementBounds, elementContains, isSelectionLoop, moveShapeHandle, onArc, onProtractorArc, onRuler,
  onRulerEdge, PICKER_SHAPES, placeSticker, protractorDegrees, rulerEdge, shapeHandles, shapePoints, snapRotation, stickerFields, stickerView, straightenAngle,
  toolDegrees, transformElement, withGroups,
} from "../public/core/inkedit.js";

const flat = (pts) => pts.map((p) => (typeof p.a === "number" ? [p.x, p.y, p.p, p.t, p.a] : [p.x, p.y, p.p, p.t]));
const xy = (pts) => pts.map((p) => [p.x, p.y]);
const P = (x, y, p = 0.5, t = 0, a) => (a === undefined ? { x, y, p, t } : { x, y, p, t, a });

const pointsIn = [P(10, 20, 0.4, 0, 0.3), P(50, 80, 0.6, 16, 1.2), P(-30, 5, 0.5, 32, 2.9)];
const ts = [
  { sx: 1, sy: 1, ox: 0, oy: 0, dx: 12, dy: -7 },
  { sx: 2, sy: 2, ox: 10, oy: 10, dx: 0, dy: 0 },
  { sx: 1, sy: 1, ox: 40, oy: 30, dx: 0, dy: 0, r: Math.PI / 2 },
  { sx: 1, sy: 1, ox: 40, oy: 30, dx: 5, dy: 5, r: 0.4 },
  { sx: -1, sy: 1, ox: 100, oy: 0, dx: 0, dy: 0 },
  { sx: 1, sy: -1, ox: 0, oy: 50, dx: 0, dy: 0 },
  { sx: -1, sy: -1, ox: 20, oy: 20, dx: 0, dy: 0 },
  { sx: 1.5, sy: 0.5, ox: 0, oy: 0, dx: 0, dy: 0, r: -1 },
];
const transforms = ts.map((t) => ({ t, points: flat(pointsIn), expect: flat(pointsIn.map((p) => transformPoint(t, p))),
  rect: transformRect(t, { x: 10, y: 20, w: 60, h: 30 }), angle: transformAngle(t, 0.7) }));

const elementsIn = [
  { type: "text", x: 10, y: 20, w: 100, h: 40, rotate: 0, flip: false },
  { type: "image", x: 10, y: 20, w: 100, h: 40, rotate: 0.5, flip: false },
  { type: "image", x: 0, y: 0, w: 50, h: 80, rotate: -0.3, flip: true },
  { type: "tape", x: 30, y: 30, w: 80, h: 24, rotate: 2, flip: false },
];
const elements = [];
for (const e of elementsIn) for (const t of ts) elements.push({ t, element: e, expect: transformElement(t, e) });
const boxes = elementsIn.map((e) => ({ element: e, bounds: elementBounds(e),
  hits: [[60, 40], [12, 22], [5, 5], [100, 58]].map(([x, y]) => ({ x, y, inside: elementContains(e, { x, y }) })) }));

const shapes = PICKER_SHAPES.map((shape) => ({ shape, a: [130, 100], b: [10, 20], expect: xy(shapePoints(shape, { x: 130, y: 100 }, { x: 10, y: 20 })) }));
const curve = { a: [0, 0], c: [50, 80], b: [100, 0], expect: xy(curvePoints({ x: 0, y: 0 }, { x: 50, y: 80 }, { x: 100, y: 0 })) };

const shapeStrokes = {
  line: { shape: "line", points: [P(0, 0), P(100, 40)] },
  curve: { shape: "curve", points: curvePoints({ x: 0, y: 0 }, { x: 50, y: 80 }, { x: 100, y: 0 }, 0.7) },
  rectangle: { shape: "rectangle", points: shapePoints("rectangle", { x: 0, y: 0 }, { x: 80, y: 50 }) },
  polyline: { shape: "polyline", points: [P(0, 0), P(50, 50), P(100, 0)] },
  triangle: { shape: "triangle", points: shapePoints("triangle", { x: 0, y: 0 }, { x: 80, y: 50 }) },
  star: { shape: "star", points: shapePoints("star", { x: 0, y: 0 }, { x: 80, y: 80 }) },
};
const handles = Object.entries(shapeStrokes).map(([name, s]) => {
  const hs = shapeHandles(s);
  return { name, stroke: { shape: s.shape, points: flat(s.points) }, handles: xy(hs),
    moves: hs.map((_, i) => { const m = moveShapeHandle(s, i, { x: 33, y: -21 }); return { index: i, to: [33, -21], shape: m.shape, points: flat(m.points) }; }) };
});

const box = (x, y, w, h) => ({ x, y, w, h });
const connectors = {
  exits: [[box(0, 0, 100, 50), [300, 25]], [box(0, 0, 100, 50), [50, 400]], [box(0, 0, 100, 50), [60, 30]], [box(0, 0, 100, 50), [-200, -200]], [box(0, 0, 100, 50), [50, 25]]]
    .map(([b, [x, y]]) => ({ box: b, toward: [x, y], expect: boxExit(b, { x, y }) })),
  ends: [
    [[0, 0], [10, 10], box(0, 0, 100, 50), box(300, 200, 80, 80)],
    [[5, 5], [400, 30], box(0, 0, 100, 50), null],
    [[5, 5], [400, 30], null, box(300, 0, 60, 60)],
    [[5, 5], [400, 30], null, null],
  ].map(([a, b, f, t]) => ({ a, b, from: f, to: t, expect: connectorEnds({ x: a[0], y: a[1] }, { x: b[0], y: b[1] }, f, t) })),
};

const ruler = { x: 300, y: 200, angle: 0.3, length: 720, width: 64 };
const pro = { x: 200, y: 300, angle: -0.2, radius: 160 };
const probe = [[300, 168], [300, 232], [300, 200], [700, 200], [640, 300], [210, 160], [360, 300], [200, 140], [100, 330], [200, 300]];
const tools = {
  ruler, protractor: pro,
  rulerEdges: probe.map(([x, y]) => ({ p: [x, y], tolerance: 12, edge: rulerEdge(ruler, { x, y }, 12), on: onRuler(ruler, { x, y }) })),
  rulerSnaps: probe.map(([x, y]) => ({ p: [x, y], top: xy([onRulerEdge(ruler, -1, { x, y })])[0], bottom: xy([onRulerEdge(ruler, 1, { x, y })])[0] })),
  arcs: probe.map(([x, y]) => ({ p: [x, y], tolerance: 14, near: onProtractorArc(pro, { x, y }, 14), on: xy([onArc(pro, { x, y })])[0], degrees: protractorDegrees(pro, { x, y }) })),
  degrees: [0, 0.3, -0.3, Math.PI / 2, Math.PI, -Math.PI / 4, 3].map((a) => ({ angle: a, expect: toolDegrees(a) })),
  snaps: [0, 0.03, 0.26, 0.3, -1.57, 1.6, 3.14159, -3.1].map((r) => ({ r, expect: snapRotation(r) })),
};

const ring = (cx, cy, r, n, close) => Array.from({ length: n + 1 }, (_, i) => P(cx + r * Math.cos((i / n) * 2 * Math.PI * close), cy + r * Math.sin((i / n) * 2 * Math.PI * close), 0.5, i * 16));
const loops = [
  { name: "circle", points: flat(ring(100, 100, 60, 40, 1)) },
  { name: "open arc", points: flat(ring(100, 100, 60, 40, 0.6)) },
  { name: "tiny", points: flat(ring(100, 100, 8, 20, 1)) },
  { name: "line", points: flat([P(0, 0), P(10, 0), P(20, 0), P(30, 0), P(40, 0), P(50, 0), P(60, 0), P(70, 0), P(80, 0)]) },
].map((c) => ({ ...c, expect: isSelectionLoop(c.points.map(([x, y, p, t]) => P(x, y, p, t))) }));

const slant = (a) => Array.from({ length: 20 }, (_, i) => P(i * 10 * Math.cos(a) + (i % 3), i * 10 * Math.sin(a) + ((i * 7) % 5) - 2));
const straighten = [0.2, -0.3, 1.4, 0, 0.785].map((a) => ({ points: flat(slant(a)), expect: straightenAngle(slant(a)) }));
straighten.push({ points: flat([P(5, 5)]), expect: 0 });

const groups = {
  all: [{ id: "a", group: "g1" }, { id: "b", group: "g1" }, { id: "c", group: "" }, { id: "d", group: "g2" }, { id: "e", group: "g2" }, { id: "f", group: "" }],
  cases: [["a"], ["c"], ["b", "f"], ["d", "c"], []].map((ids) => ({ ids, expect: withGroups(ids, [{ id: "a", group: "g1" }, { id: "b", group: "g1" }, { id: "c", group: "" },
    { id: "d", group: "g2" }, { id: "e", group: "g2" }, { id: "f", group: "" }]).sort() })),
};

const sample = {
  name: "Tick and note", folder: "Mine",
  strokes: [
    { tool: "pen", color: "#1c1c1e", width: 3, shape: null, fill: null, dash: null, arrow: null, nib: null, points: [P(110, 220, 0.5, 0), P(130, 240, 0.6, 16), P(170, 190, 0.7, 32)] },
    { tool: "marker", color: "#0a84ff", width: 6, shape: "rectangle", fill: "#ffd60a", dash: "dash", arrow: null, nib: null, points: shapePoints("rectangle", { x: 100, y: 180 }, { x: 200, y: 260 }) },
  ],
  elements: [{ type: "text", x: 210, y: 200, w: 120, h: 30, text: "Done", size: 20, color: "#34c759", image: null, rotate: 0.2, flip: false, font: "serif", bold: true, italic: false }],
};
const fields = stickerFields({ ...sample, compact: false });
const fields2 = stickerFields({ ...sample, compact: true });
const view = stickerView("s1", fields);
const placed = placeSticker(view, { x: 400, y: 300 }, 2);
const stickers = {
  sample: { ...sample, strokes: sample.strokes.map((s) => ({ ...s, points: flat(s.points) })) },
  fields, fields2,
  view: { ...view, strokes: view.strokes.map((s) => ({ ...s, points: flat(s.points) })) },
  placed: { at: [400, 300], scale: 2, strokes: placed.strokes.map((s) => ({ ...s, points: flat(s.points) })), elements: placed.elements },
  builtins: builtInStickers().map((b) => ({ ...b, strokes: b.strokes.map((s) => ({ ...s, points: flat(s.points) })) })),
  bad: { fields: { name: 3, strokes: [null, { tool: "pen", points: "" }, { tool: "pen", color: "#ff0000", width: 2, points: [[0, 0], [5, 5]] }], elements: [{ type: "video" }, { type: "tape", color: "#f2c94c" }] } },
};
stickers.bad.expect = (() => { const v = stickerView("bad", stickers.bad.fields); return { ...v, strokes: v.strokes.map((s) => ({ ...s, points: flat(s.points) })) }; })();

const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-editing.json", import.meta.url);
writeFileSync(out, `${JSON.stringify({ transforms, elements, boxes, shapes, curve, handles, connectors, tools, loops, straighten, groups, stickers }, null, 1)}\n`);
console.log(`${transforms.length} transforms, ${elements.length} elements, ${shapes.length} shapes, ${handles.length} handle sets, ${stickers.builtins.length} built-in stickers`);
