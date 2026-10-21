// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-geometry.json from ink.js, so Swift's
// InkGeometry and InkShapes are checked against the website's. Run: node test/make-ink-fixture.mjs
import { writeFileSync } from "node:fs";
import { brushTaper, erase, fountainWidth, inside, lassoSelects, recognizeShape, resample, widthAt } from "../public/core/ink.js";

// Deterministic wobble, so the rough drawings are the same every time.
let seed = 42;
const noise = (amount) => { seed = (seed * 1103515245 + 12345) % 2147483648; return (seed / 2147483648 - 0.5) * 2 * amount; };
const r2 = (v) => Math.round(v * 100) / 100;
const pt = (x, y, i = 0) => ({ x: r2(x), y: r2(y), p: 0.5 + (i % 5) / 20, t: i * 16 });
function along(corners, perSide, wobble, closed) {
  const out = [];
  const list = closed ? [...corners, corners[0]] : corners;
  for (let k = 0; k < list.length - 1; k++) {
    const a = list[k], b = list[k + 1];
    for (let i = 0; i < perSide; i++) {
      const f = i / perSide;
      out.push(pt(a[0] + (b[0] - a[0]) * f + noise(wobble), a[1] + (b[1] - a[1]) * f + noise(wobble), out.length));
    }
  }
  const last = list.at(-1);
  out.push(pt(last[0] + noise(wobble), last[1] + noise(wobble), out.length));
  return out;
}
const loop = (cx, cy, rx, ry, n, wobble, overshoot = 0.05) =>
  Array.from({ length: n + 1 }, (_, i) => { const a = (i / n) * 2 * Math.PI * (1 + overshoot); return pt(cx + rx * Math.cos(a) + noise(wobble), cy + ry * Math.sin(a) + noise(wobble), i); });

const drawings = {
  line: along([[100, 100], [400, 180]], 30, 2, false),
  polyline: along([[100, 100], [300, 100], [300, 300]], 20, 2, false),
  zigzag: along([[50, 300], [100, 200], [150, 300], [200, 200], [250, 300], [300, 200]], 10, 1, false),
  triangle: along([[200, 100], [320, 300], [80, 300]], 20, 2, true),
  rectangle: along([[100, 100], [400, 104], [398, 300], [102, 296]], 20, 3, true),
  diamond: along([[200, 100], [300, 200], [200, 300], [100, 200]], 20, 2, true),
  pentagon: along([[200, 100], [295, 169], [259, 281], [141, 281], [105, 169]], 15, 1.5, true),
  circle: loop(300, 300, 120, 120, 60, 3),
  ellipse: loop(300, 300, 160, 80, 60, 2),
  scribble: Array.from({ length: 40 }, (_, i) => pt(200 + 80 * Math.sin(i * 1.7) + noise(10), 200 + 60 * Math.cos(i * 2.3) + noise(10), i)),
  tiny: along([[10, 10], [14, 12]], 4, 0.2, false),
};
const shapes = Object.entries(drawings).map(([name, points]) => ({ name, points: points.map((p) => [p.x, p.y, p.p, p.t]), expect: recognizeShape(points) }))
  .map((c) => ({ ...c, expect: c.expect && { shape: c.expect.shape, points: c.expect.points.map((p) => [p.x, p.y, p.p, p.t]) } }));

const stroke = along([[0, 0], [200, 0]], 4, 0, false);
const erasing = [
  { name: "through the middle", points: stroke, path: [pt(100, -30), pt(100, 30)], radius: 10 },
  { name: "the start", points: stroke, path: [pt(0, 0)], radius: 15 },
  { name: "missed", points: stroke, path: [pt(100, 50), pt(150, 60)], radius: 10 },
  { name: "all of it", points: stroke, path: [pt(-10, 0), pt(210, 0)], radius: 5 },
  { name: "twice", points: stroke, path: [pt(50, -20), pt(50, 20), pt(150, 20), pt(150, -20)], radius: 6 },
].map((c) => ({ ...c, points: c.points.map((p) => [p.x, p.y, p.p, p.t]), path: c.path.map((p) => [p.x, p.y, p.p, p.t]),
  expect: erase(c.points, c.path, c.radius)?.map((piece) => piece.map((p) => [p.x, p.y, p.p, p.t])) ?? null }));

const lasso = [pt(0, 0), pt(100, 0), pt(100, 100), pt(0, 100)];
const lassoCases = {
  polygon: lasso.map((p) => [p.x, p.y]),
  points: [[50, 50], [150, 50], [0.5, 99], [-1, 50], [100, 50.5]].map(([x, y]) => ({ x, y, inside: inside(x, y, lasso) })),
  strokes: [
    along([[10, 10], [90, 90]], 5, 0, false),
    along([[50, 50], [250, 50]], 5, 0, false),
    along([[80, 50], [180, 50]], 6, 0, false),
  ].map((s) => ({ points: s.map((p) => [p.x, p.y, p.p, p.t]), selected: lassoSelects(s, lasso) })),
};

const widths = [];
for (const tool of ["pen", "ballpoint", "pencil", "marker", "highlighter", "fountain", "brush"]) for (const p of [0, 0.5, 1]) widths.push({ tool, width: 6, pressure: p, expect: widthAt(6, tool, p) });
const fountain = [[1, 1], [1, -1], [0, 1], [-3, 0], [0, 0]].map(([dx, dy]) => ({ dx, dy, pressure: 0.7, expect: fountainWidth(10, 0.7, dx, dy) }));
const taper = [[0, 20], [1, 20], [10, 20], [19, 20], [0, 2], [3, 10]].map(([i, n]) => ({ index: i, count: n, expect: brushTaper(i, n) }));
const resampled = { points: [[0, 0, 0, 0], [10, 0, 1, 100]], spacing: 3, expect: resample([{ x: 0, y: 0, p: 0, t: 0 }, { x: 10, y: 0, p: 1, t: 100 }], 3).map((p) => [p.x, p.y, p.p, p.t]) };

const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-geometry.json", import.meta.url);
writeFileSync(out, JSON.stringify({ shapes, erasing, lasso: lassoCases, widths, fountain, taper, resampled }) + "\n");
console.log(shapes.map((s) => `${s.name} → ${s.expect?.shape ?? "nothing"}`).join("\n"));
console.log(erasing.map((e) => `${e.name}: ${e.expect === null ? "untouched" : e.expect.length + " pieces"}`).join("\n"));
console.log(lassoCases.strokes.map((s) => s.selected).join(" "));
