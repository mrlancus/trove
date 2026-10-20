// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-papers.json from ink.js, so Swift's
// InkPaperShapes draws every paper exactly like the website. Run: node test/make-paper-fixture.mjs
import { writeFileSync } from "node:fs";
import { PAPERS, paperShapes } from "../public/core/ink.js";

const cases = [];
for (const paper of PAPERS) {
  cases.push({ paper, w: 300, h: 420, area: null, shapes: paperShapes(paper, 300, 420) });
  cases.push({ paper, w: 16000, h: 16000, area: { x: -130, y: 55, w: 260, h: 190 }, shapes: paperShapes(paper, 16000, 16000, { x: -130, y: 55, w: 260, h: 190 }) });
}
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-papers.json", import.meta.url), JSON.stringify({ cases }));
console.log(`${cases.length} cases, ${cases.reduce((n, c) => n + c.shapes.length, 0)} shapes`);
