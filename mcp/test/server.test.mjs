// trove-mcp's MCP handling against an offline vault (a fake relay). The real relay run is mcp.e2e.mjs.
import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import { b64uEncode } from "../../web/public/core/bytes.js";
import { importVaultKeys } from "../../web/public/core/keys.js";
import { Vault } from "../../web/public/core/vault.js";
import { serveStdio, snippet, TroveMCP } from "../src/server.js";
import { FileStorage } from "../src/store.js";

async function offlineVault() {
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const pushed = [];
  const fetch = async (url, init = {}) => {
    if (/\/segments\?/.test(url)) return Response.json({ segments: [], more: false });
    if (/\/segments\//.test(url) && init.method === "PUT") { pushed.push(url); return Response.json({ cursor: pushed.length }, { status: 201 }); }
    if (/\/preview$/.test(url)) return Response.json({ url: JSON.parse(init.body).url, title: "Fetched title", description: "From the page", image: null, site: "Example" });
    return Response.json({});
  };
  let t = 1_760_000_000_000;
  const vault = new Vault(storage, { deviceName: "Claude", encrypted: true, base: "http://relay", vaultId: "V", token: "T" }, keys, { device: "AGENT" }, [], [], [], 0,
    { now: () => (t += 1000), fetch });
  return { vault, pushed };
}

const call = (server, name, args = {}, id = 1) => server.handle({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });

test("speaks MCP: initialize, tools, search, read, list, create, save, read-only", async () => {
  const { vault, pushed } = await offlineVault();
  const ramen = vault.addNote({ title: "Miso ramen", body: "White miso, soft eggs and noodles #food", folder: ["Recipes"] });
  vault.addNote({ title: "Trip", body: "Tokyo in spring #travel" });
  vault.addLink("https://example.com/long-read", { title: "A long read" });
  const server = new TroveMCP(vault);

  const init = await server.handle({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test" } } });
  assert.equal(init.result.protocolVersion, "2025-03-26");
  assert.deepEqual(init.result.capabilities, { tools: { listChanged: false } });
  assert.equal(await server.handle({ jsonrpc: "2.0", method: "notifications/initialized" }), null);
  const odd = await server.handle({ jsonrpc: "2.0", id: 9, method: "initialize", params: { protocolVersion: "1999-01-01" } });
  assert.equal(odd.result.protocolVersion, "2025-06-18");

  const list = await server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });
  assert.deepEqual(list.result.tools.map((t) => t.name), ["search", "read_item", "list_recent", "list_folders", "create_note", "save_link"]);
  assert.equal(list.result.tools.find((t) => t.name === "search").annotations.readOnlyHint, true);
  assert.equal(list.result.tools[0].write, undefined);

  const found = (await call(server, "search", { query: "miso" })).result;
  assert.equal(found.isError, undefined);
  assert.equal(found.structuredContent.results[0].id, ramen);
  assert.equal(found.structuredContent.results[0].folder, "Recipes");
  assert.match(found.structuredContent.results[0].snippet, /White miso/);
  assert.equal(JSON.parse(found.content[0].text).count, 1);
  assert.equal((await call(server, "search", { query: "tag:travel" })).result.structuredContent.results[0].title, "Trip");

  const read = (await call(server, "read_item", { id: ramen })).result.structuredContent;
  assert.equal(read.body, "White miso, soft eggs and noodles #food");
  assert.deepEqual(read.tags, ["food"]);
  assert.equal((await call(server, "read_item", { id: "nope" })).result.isError, true);

  const recent = (await call(server, "list_recent", { limit: 2 })).result.structuredContent;
  assert.deepEqual(recent.items.map((i) => i.title), ["A long read", "Trip"]);
  assert.deepEqual((await call(server, "list_recent", { kind: "link" })).result.structuredContent.items.map((i) => i.title), ["A long read"]);
  assert.deepEqual((await call(server, "list_recent", { folder: "recipes" })).result.structuredContent.items.map((i) => i.id), [ramen]);
  const folders = (await call(server, "list_folders")).result.structuredContent.folders;
  assert.deepEqual(folders.map((f) => [f.path, f.items]), [["Links", 1], ["Notes", 1], ["Recipes", 1]]);

  const made = (await call(server, "create_note", { title: "From Claude", body: "A summary of the trip", folder: "Notes/Claude", tags: ["#AI"] })).result.structuredContent;
  assert.equal(made.folder, "Notes/Claude");
  assert.equal(made.synced, true);
  assert.equal(vault.item(made.id).isAutoFiled, false);
  assert.deepEqual(vault.item(made.id).tags, ["ai"]);
  assert.ok(pushed.length >= 1);
  assert.equal((await call(server, "create_note", { body: "  " })).result.isError, true);

  const saved = (await call(server, "save_link", { url: "https://news.example/story?utm_source=x", note: "Worth reading", tags: ["later"] })).result.structuredContent;
  assert.equal(saved.isNew, true);
  assert.equal(saved.url, "https://news.example/story");
  assert.equal(vault.item(saved.id).title, "Fetched title");
  assert.deepEqual(vault.item(saved.id).tags, ["later"]);
  assert.equal((await call(server, "save_link", { url: "https://news.example/story" })).result.structuredContent.isNew, false);
  assert.equal((await call(server, "save_link", { url: "javascript:alert(1)" })).result.isError, true);

  const missing = await server.handle({ jsonrpc: "2.0", id: 5, method: "resources/list" });
  assert.equal(missing.error.code, -32601);
  assert.equal((await call(server, "delete_everything")).error.code, -32602);

  const ro = new TroveMCP(vault, { readOnly: true });
  assert.deepEqual((await ro.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" })).result.tools.map((t) => t.name), ["search", "read_item", "list_recent", "list_folders"]);
  const refused = (await call(ro, "create_note", { body: "x" })).result;
  assert.equal(refused.isError, true);
  assert.match(refused.content[0].text, /read-only/);
});

test("stdio framing: one JSON message per line, answers in kind, bad JSON gets a parse error", async () => {
  const { vault } = await offlineVault();
  const server = new TroveMCP(vault);
  const input = new PassThrough(), output = new PassThrough();
  let out = "";
  output.on("data", (d) => { out += d; });
  const done = serveStdio(server, input, output);
  input.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }) + "\n");
  input.write("{not json\n");
  input.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  input.end(JSON.stringify([{ jsonrpc: "2.0", id: 2, method: "tools/list" }, { jsonrpc: "2.0", id: 3, method: "ping" }]) + "\n");
  await done;
  const lines = out.trim().split("\n").map((l) => JSON.parse(l));
  assert.equal(lines.length, 3);
  assert.deepEqual(lines.find((l) => l.id === 1), { jsonrpc: "2.0", id: 1, result: {} });
  assert.equal(lines.find((l) => l.error)?.error.code, -32700);
  assert.deepEqual(lines.find(Array.isArray).map((l) => l.id), [2, 3]);
});

test("snippets centre on the query", () => {
  const item = { summary: null, body: "x ".repeat(100) + "the needle is here " + "y ".repeat(100), ocrText: null };
  assert.match(snippet(item, "needle"), /^….*the needle is here.*…$/);
  assert.equal(snippet({ body: "short" }, "nothing"), "short");
});

test("the key file is private to the user", async () => {
  const dir = join(mkdtempSync(join(tmpdir(), "trove-mcp-")), "home");
  const store = new FileStorage(dir);
  store.setRawKeys({ vaultKey: b64uEncode(new Uint8Array(32)), privateKey: "never kept" });
  await store.set("config", { v: 1, vaultId: "V" });
  await store.set("ops", [{ a: 1 }]);
  await store.set("something-else", 1);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
  assert.equal(statSync(store.devicePath).mode & 0o777, 0o600);
  assert.equal(statSync(store.statePath).mode & 0o777, 0o600);
  const again = new FileStorage(dir);
  assert.equal(again.exists, true);
  assert.equal(again.device.rawKeys.privateKey, undefined);
  assert.ok((await again.get("keys")).segment);
  assert.deepEqual(await again.get("ops"), [{ a: 1 }]);
  await again.clear();
  assert.equal(new FileStorage(dir).exists, false);
});
