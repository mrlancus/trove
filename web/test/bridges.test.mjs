// Bridges' inbox entries (PROTOCOL.md §4 "Bridges"): the website files them the way the apps do,
// checked against the fixture shared with Swift (Fixtures/inbox-bridges.json, BridgeInboxTests.swift).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { b64uEncode, utf8 } from "../public/core/bytes.js";
import { importVaultKeys } from "../public/core/keys.js";
import { folderPathOf } from "../public/core/organize.js";
import { inboxFolder, inboxTags, Vault } from "../public/core/vault.js";

const fixture = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/inbox-bridges.json", import.meta.url)));

async function offlineVault(handler = () => new Response("{}")) {
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  let t = 1_760_000_000_000;
  const calls = [];
  const fetch = async (url, init = {}) => {
    calls.push({ url, init });
    if (/\/blobs\//.test(url)) return new Response(null, { status: 204 });
    return handler(url, init);
  };
  const v = new Vault(storage, { deviceName: "Chrome", encrypted: true, base: "http://relay", vaultId: "V", token: "T" }, keys, { device: "WEB" }, [], [], [], 0,
    { now: () => (t += 1000), fetch });
  return { v, calls };
}

test("bridge inbox entries become the same items as in Swift", async () => {
  const { v } = await offlineVault();
  for (const c of fixture.cases) {
    const id = await v.importEnvelope(c.header, utf8.encode(c.body), { id: c.entry });
    const item = v.item(id);
    const e = c.expect;
    assert.equal(id, e.id, c.name);
    assert.equal(item.kind, e.kind, c.name);
    assert.equal(item.title, e.title, c.name);
    assert.equal(item.url?.toString() ?? null, e.url, c.name);
    assert.equal(item.source, e.source, c.name);
    assert.deepEqual(folderPathOf(item.folder, v.folders()).map((f) => f.name), e.folder, c.name);
    assert.equal(item.isAutoFiled, e.folderAuto, c.name);
    assert.deepEqual(item.tags, e.tags, c.name);
    assert.equal(item.body, e.body, c.name);
    assert.equal(item.record.fields.origin?.bridge ?? null, e.bridge, c.name);
    assert.equal(item.attachments.length, e.attachments, c.name);
  }
});

test("folder and tag hints are cleaned", () => {
  assert.deepEqual(inboxFolder({ folder: " A / B //C/D/E/F/G" }), ["A", "B", "C", "D", "E"]);
  assert.deepEqual(inboxFolder({ folder: ["Feeds", 3, " "] }), ["Feeds"]);
  assert.deepEqual(inboxFolder({}), []);
  assert.deepEqual(inboxTags({ tags: ["A", "#a", " b ", 7] }), ["a", "b"]);
  assert.deepEqual(inboxTags({ tags: "nope" }), []);
});

test("link previews fill in only what an item lacks", async () => {
  const { v, calls } = await offlineVault((url, init) => {
    assert.match(url, /\/v1\/vaults\/V\/preview$/);
    return Response.json({ url: "https://news.example/story", title: "A story", description: "What happened", image: "https://cdn.example/s.jpg", site: "News" });
  });
  const { id } = v.addLink("https://news.example/story");
  await v.fillLinkPreview(id);
  assert.deepEqual([v.item(id).title, v.item(id).summary, v.item(id).siteName, v.item(id).imageURL], ["A story", "What happened", "News", "https://cdn.example/s.jpg"]);
  const named = v.addLink("https://news.example/other", { title: "Mine" }).id;
  await v.fillLinkPreview(named);
  assert.equal(v.item(named).title, "Mine");
  assert.deepEqual(calls.map((c) => JSON.parse(c.init.body).url), ["https://news.example/story", "https://news.example/other"]);
});
