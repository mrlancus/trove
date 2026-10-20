// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-cases.json from clips.js `insights`,
// so Swift's ClipInsights is checked against the website's. Run: node test/make-clip-fixture.mjs
import { writeFileSync } from "node:fs";
import { insights } from "../public/core/clips.js";

const texts = [
  "https://www.example.com/blog/post-1/?utm_source=x",
  "Meeting notes\nCall Anna on +44 20 7946 0958 or anna@example.org about #budget and #Q3 plans.\nSee https://docs.example.com/plan. Colour #FF8800.",
  "#3366ff",
  "/Users/me/Documents/report.pdf",
  '{"a":1}',
  "A really long sentence that keeps going and going past the sixty character limit for titles here",
  "  \n  indented first line  \nsecond",
  "Ünïcödé 😀 text",
  "Links (https://a.example.com/x), and https://b.example.com/y.",
  "",
];
const cases = texts.map((text) => ({ text, ...insights(text) }));
const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-cases.json", import.meta.url);
writeFileSync(out, JSON.stringify({ insights: cases }, null, 1) + "\n");
console.log(`wrote ${cases.length} cases`);
