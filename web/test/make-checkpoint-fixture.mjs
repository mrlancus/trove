// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/checkpoint-cases.json (checkpoints,
// PROTOCOL.md §3) and ink-points2.json (compact stroke points, §10) from the website's core, so
// Checkpoint.swift and InkPoints are checked against it. Run: node test/make-checkpoint-fixture.mjs
import { writeFileSync } from "node:fs";
import { b64uEncode } from "../public/core/bytes.js";
import { encodeCheckpoint, makeCheckpoint } from "../public/core/checkpoint.js";
import { decodePoints, encodePoints2 } from "../public/core/ink.js";
import { RecordStore } from "../public/core/records.js";
import { checkpointScenario, recordsView } from "./checkpoint-scenario.mjs";

const dir = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/", import.meta.url);

const { all, inCheckpoint, rest } = checkpointScenario();
const part = new RecordStore();
part.apply(inCheckpoint);
const checkpoint = makeCheckpoint(part, { cursor: 12, device: "AAAA", createdAt: 1_760_000_100_000 });
const full = new RecordStore();
full.apply(all);
writeFileSync(new URL("checkpoint-cases.json", dir), JSON.stringify({
  note: "Made by web/test/make-checkpoint-fixture.mjs. `checkpoint` is the materialised state of `inCheckpoint`; loading it and then applying `rest` (any order) must give `expected`, the same as replaying `ops`.",
  ops: all,
  inCheckpoint: inCheckpoint.map((op) => `${op.d}:${op.s}`),
  checkpoint,
  deflated: b64uEncode(await encodeCheckpoint(checkpoint, { compress: true })),
  plain: b64uEncode(await encodeCheckpoint(checkpoint, { compress: false })),
  expectedAtCheckpoint: recordsView(part),
  expected: recordsView(full),
  restCount: rest.length,
}, null, 1) + "\n");

const cases = [
  [[10, 20, 0.5, 0], [10.5, 21.25, 0.75, 16], [300.125, 900.5, 1, 33]],
  [[-12345.678, 98765.4321, 0.2, 0.4], [-12345.6, 98765.45, 0.21, 8.6], [-12000, 99000, 0, 1000], [0, 0, 1, 1000000]],
  [[0.024, 0.025, 1.5, -3], [0.026, -0.025, -0.5, 2]],
  [],
];
writeFileSync(new URL("ink-points2.json", dir), JSON.stringify({
  note: "Made by web/test/make-checkpoint-fixture.mjs: compact stroke points (points2). `decoded` is what both cores read back.",
  cases: cases.map((pts) => {
    const points = pts.map(([x, y, p, t]) => ({ x, y, p, t }));
    const encoded = encodePoints2(points);
    return { points: pts, encoded, decoded: decodePoints(encoded).map((q) => [q.x, q.y, q.p, q.t]) };
  }),
}, null, 1) + "\n");
console.log("wrote checkpoint-cases.json and ink-points2.json");
