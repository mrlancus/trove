// Checkpoints against a running relay (PROTOCOL.md §3 "Checkpoints", §4):
//   cd server && npx wrangler dev --local --config wrangler.test.jsonc   then   npm run test:e2e
import assert from "node:assert/strict";
import { test } from "node:test";
import { Vault } from "../public/core/vault.js";
import { BASE, createVault, memoryStorage } from "./helpers.mjs";

const opts = { origin: BASE };

test("a browser writes a checkpoint; a new one starts from it and gets the same vault", async () => {
  const v = await createVault();
  const a = await Vault.join(memoryStorage(), await v.setupCode(), { ...opts, deviceName: "Chrome" });
  for (let i = 0; i < 12; i++) { a.addNote({ title: `note ${i}`, body: `secret ${i}` }); await a.sync(); }
  const report = { errors: [] };
  assert.equal(await a.maybeWriteCheckpoint(report, { force: true }), true, report.errors.join());
  const list = await a.checkpoints();
  assert.equal(list.length, 1);
  assert.equal(list[0].id, report.wroteCheckpoint);
  a.addNote({ title: "after" });
  await a.sync();

  const b = await Vault.join(memoryStorage(), await v.setupCode(), { ...opts, deviceName: "Firefox" });
  const r = await b.sync();
  assert.deepEqual(r.errors, []);
  assert.equal(r.checkpoint, list[0].id);
  assert.equal(r.pulled, 1, "only the segment after the checkpoint is downloaded");
  const view = (x) => x.items().map((i) => [i.id, i.title, i.body]).sort();
  assert.deepEqual(view(b), view(a));
  // Edits keep flowing both ways.
  const id = b.addNote({ title: "from b" });
  await b.sync(); await a.sync();
  assert.equal(a.item(id).title, "from b");
  clearTimeout(a.saveTimer); clearTimeout(b.saveTimer);
});
