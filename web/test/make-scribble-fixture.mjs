// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-scribble.json from ink.js, so Swift's
// InkScribble crosses out exactly what the website does. Run: node test/make-scribble-fixture.mjs
import { writeFileSync } from "node:fs";
import { scribbleTargets } from "../public/core/ink.js";

const pt = (x, y, i = 0) => ({ x: Math.round(x * 100) / 100, y: Math.round(y * 100) / 100, p: 0.5, t: i * 16 });
const line = (pts) => pts.map(([x, y], i) => pt(x, y, i));
/** Handwriting-ish strokes for "hi" between x 100–200 and y 100–130. */
const word = [
  { id: "h1", points: line([[105, 100], [105, 115], [105, 130]]) },
  { id: "h2", points: line([[105, 118], [112, 112], [120, 115], [122, 122], [122, 130]]) },
  { id: "i1", points: line([[140, 112], [140, 121], [140, 130]]) },
  { id: "dot", points: line([[140, 104], [141, 104.5]]) },
  { id: "far", points: line([[400, 400], [450, 420], [500, 400]]) },
];
const long = { id: "long", points: line([[100, 115], [300, 115], [500, 115], [700, 115]]) };
/** A scratch-out: up and down `n` times while moving right from x0 to x1. */
const zigzag = (x0, x1, top, bottom, n) => line(Array.from({ length: n * 2 + 1 }, (_, i) => [x0 + (x1 - x0) * i / (n * 2), i % 2 ? top : bottom]));
const cases = [
  { name: "scratch-out over a word", points: zigzag(98, 148, 98, 134, 6), strokes: word },
  { name: "one line through a word", points: line([[95, 115], [150, 116], [205, 117]]), strokes: word },
  { name: "two lines over a word", points: line([[95, 110], [150, 110], [95, 122], [150, 122]]), strokes: word },
  { name: "scratch-out in empty space", points: zigzag(300, 360, 300, 330, 7), strokes: word },
  { name: "scratch-out over part of a long line", points: zigzag(120, 180, 100, 130, 7), strokes: [long] },
  { name: "handwriting mmm beside a word", points: zigzag(220, 300, 110, 130, 6), strokes: word },
];
for (const c of cases) c.expect = scribbleTargets(c.points, c.strokes);
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-scribble.json", import.meta.url), JSON.stringify({ cases }, null, 0));
for (const c of cases) console.log(c.name, "→", c.expect);
