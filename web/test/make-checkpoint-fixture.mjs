// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/checkpoint-cases.json (checkpoints,
// PROTOCOL.md §3 "Checkpoints") from the website's core, so Checkpoint.swift is checked against it.
// Run: node test/make-checkpoint-fixture.mjs
import { writeFileSync } from "node:fs";
import { b64uEncode } from "../public/core/bytes.js";
import { encodeCheckpoint, makeCheckpoint } from "../public/core/checkpoint.js";
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
  note: "Made by web/test/make-checkpoint-fixture.mjs. `checkpoint` is the materialised state of `inCheckpoint`; loading it and then applying the other ops (any order) must give `expected`, the same as replaying `ops`.",
  ops: all,
  inCheckpoint: inCheckpoint.map((op) => `${op.d}:${op.s}`),
  checkpoint,
  deflated: b64uEncode(await encodeCheckpoint(checkpoint, { compress: true })),
  plain: b64uEncode(await encodeCheckpoint(checkpoint, { compress: false })),
  expectedAtCheckpoint: recordsView(part),
  expected: recordsView(full),
  restCount: rest.length,
}, null, 1) + "\n");
console.log("wrote checkpoint-cases.json");
