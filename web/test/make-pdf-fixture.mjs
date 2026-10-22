// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/pdf-cases.json: PDF text for search,
// highlight geometry, quotes, page boxes and form value ids (core/pdfmarks.js), checked by
// web/test/core.test.mjs and PDFMarksTests.swift. Run: node test/make-pdf-fixture.mjs
import { writeFileSync } from "node:fs";
import { cleanQuote, fieldElementId, highlightGeometry, highlightRects, joinPdfText, pdfPageBox } from "../public/core/pdfmarks.js";

const nbsp = String.fromCharCode(0xa0), ideo = String.fromCharCode(0x3000), bom = String.fromCharCode(0xfeff);
const textCases = [
  { name: "two pages", pages: ["Hello world from Trove\nSecond line here", "Page two has   some\twords in it"] },
  { name: "blank page skipped, CRLF, no-break spaces", pages: [`  A title  \r\n\r\nBody${nbsp}${nbsp}text with${ideo}wide space\r`, "   ", `${bom}Last page, last words. And a few more.`] },
  { name: "too short: a scan", pages: ["Scan 1", "", "p. 2"] },
  { name: "exactly 40 is too short", pages: ["x".repeat(40)] },
  { name: "41 is enough", pages: ["x".repeat(41)] },
  // Pages made of repeats ([text, times]); only the length and the end are kept.
  { name: "capped at 50,000 characters (emoji count once)", repeat: [[String.fromCodePoint(0x1f600), 30_000], ["y", 30_000]] },
];
const pagesOf = (c) => c.pages ?? c.repeat.map(([s, n]) => s.repeat(n));
const quoteCases = ["  The quick\nbrown   fox\r\n jumps ", `${nbsp}tab\there${nbsp}`, "a".repeat(5_010), ""];
const highlightCases = [
  { name: "one line of words", boxes: [{ x: 72, y: 100, w: 40.5, h: 12 }, { x: 113, y: 100.4, w: 30.25, h: 11.6 }, { x: 144, y: 100, w: 20, h: 12 }] },
  { name: "three lines, ragged", boxes: [
    { x: 200, y: 100, w: 300, h: 12 }, { x: 72, y: 114, w: 428, h: 12 }, { x: 72, y: 128, w: 150, h: 12 },
    { x: 72, y: 114.5, w: 0.2, h: 11 }, // a sliver: dropped
  ] },
  { name: "two columns on one line stay apart", boxes: [{ x: 72, y: 300, w: 200, h: 10 }, { x: 320, y: 301, w: 180, h: 10 }] },
  { name: "unsorted with a duplicate", boxes: [{ x: 90, y: 50, w: 50, h: 14 }, { x: 72, y: 20, w: 100, h: 14 }, { x: 90, y: 50, w: 50, h: 14 }, { x: 141, y: 50, w: 30, h: 14 }] },
  { name: "nothing left", boxes: [{ x: 1, y: 1, w: 0.1, h: 10 }, { x: 5, y: 5, w: Number.NaN, h: 3 }] },
];
const boxCases = [];
for (const rotate of [0, 90, 180, 270, -90, 450]) {
  for (const view of [[0, 0, 612, 792], [10, 20, 310, 420]]) boxCases.push({ view, rotate, points: [[0, 0], [100, 50], [view[2], view[3]], [view[0] + 12.5, view[1] + 33.25]] });
}

const fixture = {
  text: textCases.map((c) => {
    const out = Array.from(joinPdfText(pagesOf(c)));
    return c.repeat ? { ...c, expectedLength: out.length, expectedTail: out.slice(-5).join("") } : { ...c, expected: out.join("") };
  }),
  quotes: quoteCases.map((input) => ({ input, expected: cleanQuote(input) })),
  highlights: highlightCases.map((c) => {
    const g = highlightGeometry(c.boxes);
    // NaN can't go in JSON: written as null, read back as NaN.
    return { ...c, boxes: c.boxes.map((b) => Object.fromEntries(Object.entries(b).map(([k, v]) => [k, Number.isFinite(v) ? v : null]))),
      expected: g, absolute: g ? highlightRects(g) : null };
  }),
  boxes: boxCases.map((c) => {
    const b = pdfPageBox(c.view, c.rotate);
    return { ...c, size: [b.width, b.height], page: c.points.map((p) => b.toPage(p)), back: c.points.map((p) => b.toPdf(b.toPage(p))) };
  }),
  fieldIds: [{ item: "item-1", layer: "blob-abc", name: "Applicant.Name", id: fieldElementId("item-1", "blob-abc", "Applicant.Name") }],
  // Element records as old and new readers see them; sketchText from text boxes and highlights.
  elements: {
    records: [
      { id: "e1", fields: { on: "s", layer: "a", page: 0, type: "text", text: "Typed note", x: 0, y: 0, w: 100, h: 20, createdAt: 3 } },
      { id: "e2", fields: { on: "s", layer: "a", page: 0, type: "highlight", quote: "Highlighted words", color: "#ffd60a", x: 10, y: 10, w: 100, h: 24,
        rects: [[0.5, 0, 0.5, 0.5], [0, 0.5, 0.4, 0.5]], createdAt: 2 } },
      { id: "e3", fields: { on: "s", layer: "a", page: 1, type: "field", name: "agree", value: true, x: 5, y: 5, w: 10, h: 10, createdAt: 1 } },
      { id: "e4", fields: { on: "s", layer: "a", page: 1, type: "highlight", quote: "", color: "#34c759", x: 0, y: 0, w: 50, h: 10, createdAt: 4 } },
    ],
    sketchText: "Highlighted words\nTyped note",
    absolute: { e2: [{ x: 60, y: 10, w: 50, h: 12 }, { x: 10, y: 22, w: 40, h: 12 }], e4: [{ x: 0, y: 0, w: 50, h: 10 }] },
  },
};
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/pdf-cases.json", import.meta.url), JSON.stringify(fixture, null, 1) + "\n");
console.log("wrote pdf-cases.json");
