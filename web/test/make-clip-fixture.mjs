// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-cases.json from clips.js `insights`,
// so Swift's ClipInsights is checked against the website's. Run: node test/make-clip-fixture.mjs
import { writeFileSync } from "node:fs";
import { insights, ruleTags } from "../public/core/clips.js";

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
// The built-in rules' tags (ClipInsights.ruleTags).
const ruleTexts = [
  ...texts,
  "https://github.com/mrlancus/trove",
  "https://www.bbc.co.uk/news/x",
  "func greet() -> String {\n    let name = \"x\"\n    return name\n}",
  "def add(a, b):\n    return a + b\n\nprint(add(1, 2))",
  "const f = (x) => x * 2;\nconsole.log(f(2));",
  "SELECT id, name FROM users WHERE id = 1;\nSELECT * FROM t;",
  "<div class=\"a\">\n  <p>Hi</p>\n</div>",
  "anna@example.org",
  "+44 20 7946 0958",
  "Write to #team about the #launch",
];
const rules = ruleTexts.map((text) => ({ text, tags: ruleTags(text) }));
const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-cases.json", import.meta.url);
writeFileSync(out, JSON.stringify({ insights: cases, rules }, null, 1) + "\n");
console.log(`wrote ${cases.length} cases`);
