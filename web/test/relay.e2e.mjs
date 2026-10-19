// The web app's vault against a running relay:
//   cd server && npx wrangler dev --local --config wrangler.test.jsonc   then   npm run test:e2e
import assert from "node:assert/strict";
import { test } from "node:test";
import { Vault } from "../public/core/vault.js";
import { BASE, createVault, memoryStorage } from "./helpers.mjs";

const opts = { origin: BASE };

test("two browsers join, sync, merge concurrent edits and share an encrypted attachment", async () => {
  const v = await createVault();
  const a = await Vault.join(memoryStorage(), await v.setupCode(), { ...opts, deviceName: "Chrome" });
  const b = await Vault.join(memoryStorage(), await v.setupCode(), { ...opts, deviceName: "Firefox" });
  await assert.rejects(Vault.join(memoryStorage(), "bm9wZQ", opts), /setup code/);

  const id = a.addNote({ title: "Trip", body: "Pack\n- passport\n- charger\n#travel" });
  const link = a.addLink("https://example.com/story?utm_source=x");
  assert.equal(a.addLink("https://www.example.com/story/").isNew, false);
  assert.deepEqual(await a.sync().then((r) => r.errors), []);
  const pulled = await b.sync();
  assert.equal(pulled.pulled, 1);
  assert.equal(b.item(id).body, "Pack\n- passport\n- charger\n#travel");
  assert.deepEqual(b.item(id).tags, ["travel"]);
  assert.equal(b.item(link.id).url.toString(), "https://example.com/story");

  // Concurrent edits to different lines merge on both sides.
  a.setBody(id, "Pack\n- passport and visa\n- charger\n#travel");
  b.setBody(id, "Pack\n- passport\n- charger\n- snacks\n#travel");
  await a.sync(); await b.sync(); await a.sync();
  const merged = "Pack\n- passport and visa\n- charger\n- snacks\n#travel";
  assert.equal(a.item(id).body, merged);
  assert.equal(b.item(id).body, merged);

  // Edits to the same line can't merge: both sides keep the same text plus a conflict copy.
  a.setBody(id, merged.replace("charger", "USB-C charger"));
  b.setBody(id, merged.replace("charger", "laptop charger"));
  await a.sync(); await b.sync(); await a.sync();
  assert.equal(a.item(id).body, b.item(id).body);
  assert.equal(a.item(id).conflictingVersions.length, 1);
  assert.deepEqual(a.item(id).conflictingVersions, b.item(id).conflictingVersions);
  a.resolveConflicts(id, a.item(id).conflictingVersions[0]);
  await a.sync(); await b.sync();
  assert.equal(b.item(id).hasConflicts, false);
  assert.equal(b.item(id).body, a.item(id).body);

  // Attachments are encrypted with the blob key and dedupe by HMAC id.
  const bytes = new TextEncoder().encode("a small file");
  const fileItem = await a.addFile(bytes, "notes_v2.txt", "text/plain");
  await a.sync(); await b.sync();
  const att = b.item(fileItem).attachments[0];
  assert.equal(b.item(fileItem).title, "notes v2");
  assert.match(att.id, /^[0-9a-f]{64}$/);
  assert.deepEqual(await b.attachment(att.id), bytes);
  const raw = new Uint8Array(await (await fetch(`${BASE}/v1/vaults/${a.config.vaultId}/blobs/${att.id}`, { headers: { authorization: `Bearer ${a.config.token}` } })).arrayBuffer());
  assert.equal(new TextDecoder().decode(raw.subarray(0, 4)), "TRV1");

  // Deletes and pins sync; the relay only ever sees ciphertext.
  b.delete(link.id);
  b.setPinned(id, true);
  await b.sync(); await a.sync();
  assert.equal(a.item(link.id), null);
  assert.equal(a.item(id).isPinned, true);
});

test("a stale copy of this browser's journal moves its ops past what the relay already has", async () => {
  const v = await createVault();
  const storage = memoryStorage();
  const a = await Vault.join(storage, await v.setupCode(), opts);
  a.addNote({ body: "first" });
  await a.sync();
  const stale = memoryStorage();
  for (const [k, val] of storage.map) stale.map.set(k, structuredClone(val));
  a.addNote({ body: "from the live tab" });
  await a.sync();

  const old = await Vault.open(stale, opts);
  old.addNote({ body: "from the stale tab" });
  const report = await old.sync();
  assert.deepEqual(report.errors, []);
  const b = await Vault.join(memoryStorage(), await v.setupCode(), opts);
  await b.sync();
  assert.deepEqual(b.items().map((i) => i.body).sort(), ["first", "from the live tab", "from the stale tab"]);
});

test("a fresh browser opens from storage, and forgetting revokes it", async () => {
  const v = await createVault();
  const storage = memoryStorage();
  const a = await Vault.join(storage, await v.setupCode(), opts);
  a.addNote({ body: "hello" });
  await a.sync();
  const reopened = await Vault.open(storage, opts);
  assert.equal(reopened.items()[0].body, "hello");
  await reopened.forget();
  assert.equal(await Vault.open(storage, opts), null);
  await assert.rejects(a.sync(), (e) => e.status === 401);
});
