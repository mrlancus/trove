// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-outline.json from ink.js, so Swift's
// InkOutline (outlines, arrowheads, compact points, pen settings, the page grid, pencil grain) is
// checked against the website's. Run: node test/make-outline-fixture.mjs
import { writeFileSync } from "node:fs";
import { b64uEncode } from "../public/core/bytes.js";
import {
  arrowHeads, decodePoints, decodePoints2, encodePoints, encodePoints2, filterPoints, grainTile, InkGrid, inkSettingsOf, pressureAfter, strokeOutline,
} from "../public/core/ink.js";

let seed = 7;
const noise = (amount) => { seed = (seed * 1103515245 + 12345) % 2147483648; return (seed / 2147483648 - 0.5) * 2 * amount; };
const r3 = (v) => Math.round(v * 1000) / 1000;
const flat = (pts) => pts.map((p) => (typeof p.a === "number" ? [p.x, p.y, p.p, p.t, p.a] : [p.x, p.y, p.p, p.t]));
const pts = (a) => a.map(([x, y, p = 0.5, t = 0, a]) => (a === undefined ? { x, y, p, t } : { x, y, p, t, a }));
const r6 = (v) => Math.round(v * 1e6) / 1e6;

// Handwriting-like lines: a wave, a loop, a hairpin, a dot, a short tick.
const wave = Array.from({ length: 40 }, (_, i) => [r3(40 + i * 6 + noise(0.4)), r3(200 + 30 * Math.sin(i / 4) + noise(0.4)), r3(0.3 + 0.6 * Math.sin(i / 12)), i * 8]);
const loop = Array.from({ length: 50 }, (_, i) => { const a = (i / 49) * 2.2 * Math.PI; return [r3(300 + 40 * Math.cos(a)), r3(300 + 25 * Math.sin(a)), 0.6, i * 8]; });
const hairpin = [[100, 100, 0.5, 0], [140, 100, 0.6, 10], [180, 101, 0.7, 20], [140, 104, 0.8, 30], [100, 106, 0.6, 40]];
const tick = [[10, 10, 0.4, 0], [10.05, 10.02, 0.5, 8], [10.1, 10.05, 0.6, 16]];
const angled = wave.slice(0, 20).map((p, i) => [...p, r3(0.2 + i * 0.07)]);

const outlineCases = [
  { name: "pen wave", stroke: { tool: "pen", width: 3, points: wave } },
  { name: "pencil loop", stroke: { tool: "pencil", width: 2, points: loop } },
  { name: "fountain wave", stroke: { tool: "fountain", width: 5, points: wave } },
  { name: "fountain with a nib", stroke: { tool: "fountain", width: 5, nib: 1.1, points: wave } },
  { name: "fountain rolled per point", stroke: { tool: "fountain", width: 5, points: angled } },
  { name: "brush loop", stroke: { tool: "brush", width: 9, points: loop } },
  { name: "pen hairpin", stroke: { tool: "pen", width: 6, points: hairpin } },
  { name: "pen dot", stroke: { tool: "pen", width: 4, points: [[50, 60, 0.7, 0]] } },
  { name: "pen tick", stroke: { tool: "pen", width: 2, points: tick } },
  { name: "marker is a line", stroke: { tool: "marker", width: 7, points: wave } },
  { name: "shape is a line", stroke: { tool: "pen", width: 3, shape: "line", points: [[0, 0], [100, 50]] } },
  { name: "dashed pen is a line", stroke: { tool: "pen", width: 3, dash: "dash", points: wave } },
].map((c) => {
  const s = { ...c.stroke, points: pts(c.stroke.points) };
  const o = strokeOutline(s);
  return { ...c, expect: o && o.map((p) => [r6(p.x), r6(p.y)]) };
});

const arrowCases = [
  { name: "line, end", stroke: { tool: "pen", width: 3, shape: "line", arrow: "end", points: [[10, 10, 0.5], [110, 60, 0.5]] } },
  { name: "polyline, both", stroke: { tool: "marker", width: 5, shape: "polyline", arrow: "both", points: [[10, 10], [60, 10], [60, 90]] } },
  { name: "no arrows on a rectangle", stroke: { tool: "pen", width: 3, shape: "rectangle", arrow: "end", points: [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]] } },
].map((c) => ({ ...c, expect: arrowHeads({ ...c.stroke, points: pts(c.stroke.points) }).map((t) => t.map((p) => [r6(p.x), r6(p.y)])) }));

const points2Cases = [
  { name: "wave", points: wave },
  { name: "negative and far", points: [[-12.34, 5.67, 0, 0], [1e5, -2e4, 1, 3.4], [-1e5, 2e4, 0.25, 1000.6]] },
  { name: "nib angles", points: angled },
  { name: "one point", points: [[3.025, 4.975, 0.5, 0]] },
].map((c) => {
  const encoded = encodePoints2(pts(c.points));
  return { ...c, encoded, decoded: flat(decodePoints2(encoded)) };
});
const legacy = encodePoints(pts(wave.slice(0, 5)));

const settingsCases = [
  { fields: {} },
  { fields: { "pen.pen": { smoothing: 40.4, curve: "soft", minWidth: 20 }, "pen.brush": { smoothing: 300, curve: "odd", minWidth: -5 },
    favourites: [{ tool: "pen", color: "#FF0000", width: 2 }, { tool: "eraser", color: "#000000", width: 2 }, { tool: "marker", color: "red", width: 3 },
      ...Array.from({ length: 12 }, (_, i) => ({ tool: "fountain", color: "#123456", width: i + 1 }))],
    palette: ["#ABCDEF", "nope", "#000000"], compactPoints: true } },
].map((c) => ({ ...c, expect: inkSettingsOf(c.fields) }));

const curves = [];
for (const curve of ["soft", "normal", "firm"]) for (const minWidth of [0, 30]) for (const p of [0, 0.2, 0.5, 0.9, 1.2]) {
  curves.push({ p, curve, minWidth, expect: pressureAfter(p, { curve, minWidth }) });
}
const filterCases = [0, 50, 100].map((smoothing) => {
  const settings = { smoothing, curve: "firm", minWidth: 10 };
  return { settings, raw: wave.slice(0, 15), expect: flat(filterPoints(pts(wave.slice(0, 15)), settings)) };
});

const grid = new InkGrid(256);
const boxes = [
  ["a", { x: 10, y: 10, w: 50, h: 20 }], ["b", { x: 300, y: 10, w: 20, h: 300 }], ["c", { x: -400, y: -20, w: 30, h: 30 }],
  ["d", { x: 0, y: 0, w: 5000, h: 5000 }], ["e", { x: 255, y: 255, w: 2, h: 2 }], ["f", { x: 600, y: 600, w: 10, h: 10 }],
];
for (const [id, r] of boxes) grid.add(id, r);
grid.remove("f");
const queries = [
  { x: 0, y: 0, w: 100, h: 100 }, { x: 250, y: 250, w: 10, h: 10 }, { x: -500, y: -500, w: 120, h: 490 }, { x: 590, y: 590, w: 30, h: 30 },
  { x: 6000, y: 6000, w: 1, h: 1 }, { x: -1e6, y: -1e6, w: 2e6, h: 2e6 },
].map((rect) => ({ rect, expect: grid.query(rect) }));

const tile = grainTile();
const fixture = {
  outlines: outlineCases, arrows: arrowCases,
  points2: { cases: points2Cases, legacy: { encoded: legacy, decoded: flat(decodePoints(legacy)) } },
  settings: settingsCases, curves, filters: filterCases,
  grid: { cell: 256, boxes: boxes.map(([id, rect]) => ({ id, rect })), removed: ["f"], queries },
  grain: { size: 64, tile: b64uEncode(tile), sum: tile.reduce((n, v) => n + v, 0) },
};
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-outline.json", import.meta.url), `${JSON.stringify(fixture, null, 1)}\n`);
console.log("wrote ink-outline.json", outlineCases.length, "outlines");
