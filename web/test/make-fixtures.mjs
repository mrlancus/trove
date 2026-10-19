// Writes Packages/TroveCore/Tests/TroveCoreTests/Fixtures/web-journal.json: journals written by the
// web app's code, which WebInteropTests.materialisesJournalsWrittenByTheWebApp reads in Swift.
import { writeFileSync } from "node:fs";
import { b64uEncode } from "../public/core/bytes.js";
import { importVaultKeys } from "../public/core/keys.js";
import { encodeSegment } from "../public/core/records.js";
import { encrypt } from "../public/core/trv1.js";
import { expectedRecords, scenario } from "./scenario.mjs";

const exported = { v: 1, vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))), privateKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) };
const keys = await importVaultKeys(exported);
const { journals, store } = scenario();
const segments = [];
for (const j of journals) {
  for (const batch of j.segments()) {
    segments.push({ device: j.device, first: batch[0].s, last: batch.at(-1).s, data: b64uEncode(await encrypt(encodeSegment(batch), keys.segment)) });
  }
}
const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/web-journal.json", import.meta.url);
writeFileSync(out, JSON.stringify({ keys: exported, segments, expected: expectedRecords(store) }, null, 2) + "\n");
console.log("wrote", out.pathname);
