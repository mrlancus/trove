// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-events.json from core/clipmap.js, so
// ClipEvents.swift reads copy and paste events (sites, apps, places) like the website.
// Run: node test/make-clip-events-fixture.mjs
import { writeFileSync } from "node:fs";
import { appKey, clipEventView, placeKey } from "../public/core/clipmap.js";

const events = [
  { clip: "a", type: "copy", at: 1760000000000, app: "Safari", url: "https://www.github.com/mrlancus/trove", place: { lat: 51.50735, lon: -0.12776, accuracy: 30, name: "Home" } },
  { clip: "a", type: "paste", at: 1760000060000, app: "Slack", place: { lat: 51.507349, lon: -0.127759 } },
  { clip: "b", type: "use", at: 1760000120000, place: { lat: 48.85661, lon: 2.35222, city: "Paris" } },
  { clip: "b", type: "paste", at: 1760000180000, app: "Terminal" },
  { clip: "c", type: "weird", at: 1760000240000, url: "not a url", app: "Notes" },
];
const cases = events.map((fields, i) => {
  const e = clipEventView({ id: `e${i}`, fields });
  return { fields, expect: { type: e.type, where: appKey(e), place: placeKey(e.place) } };
});
writeFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-events.json", import.meta.url), JSON.stringify({ cases }, null, 1));
console.log(JSON.stringify(cases.map((c) => c.expect)));
