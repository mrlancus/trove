// trove-mcp against a running relay:
//   cd server && npx wrangler dev --local --config wrangler.test.jsonc --port 8803
//   cd mcp && TROVE_RELAY_URL=http://127.0.0.1:8803 npm run test:e2e
// Makes a vault, a setup code, joins as an "agent" device with the real CLI, speaks MCP to it over
// stdio, and checks a note it creates reaches a second (web-core) device.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { Vault } from "../../web/public/core/vault.js";
import { BASE, createVault, memoryStorage } from "../../web/test/helpers.mjs";

const BIN = new URL("../bin/trove-mcp.js", import.meta.url).pathname;

function run(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BIN, ...args], { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, out, err }));
  });
}

/** Starts the server and returns a function that sends a request and waits for its answer. */
function serve(args, env) {
  const child = spawn(process.execPath, [BIN, ...args], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  const waiting = new Map();
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d; });
  createInterface({ input: child.stdout }).on("line", (line) => {
    const msg = JSON.parse(line);
    waiting.get(msg.id)?.(msg);
    waiting.delete(msg.id);
  });
  let next = 1;
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = next++;
    const timer = setTimeout(() => reject(new Error(`no answer to ${method}; stderr: ${stderr}`)), 15000);
    waiting.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const notify = (method) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
  const tool = async (name, args = {}) => (await request("tools/call", { name, arguments: args })).result;
  const stop = () => new Promise((resolve) => { child.on("close", resolve); child.stdin.end(); });
  return { request, notify, tool, stop };
}

test("joins as an agent device, searches, creates a note that syncs to another device, and can be read-only", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const ramen = phone.addNote({ title: "Miso ramen", body: "White miso, soft eggs #food", folder: ["Recipes"] });
  phone.addLink("https://example.org/long-read", { title: "A long read" });
  await phone.sync();

  const home = join(mkdtempSync(join(tmpdir(), "trove-mcp-e2e-")), "trove-mcp");
  const env = { TROVE_MCP_HOME: home };
  assert.equal((await run(["status"], env)).code, 1);
  const joined = await run(["join", await v.setupCode(), "--name", "Claude"], env);
  assert.equal(joined.code, 0, joined.err);
  assert.match(joined.err, /Joined vault .* as Claude \(2 items\)/);
  assert.equal(statSync(join(home, "device.json")).mode & 0o777, 0o600);
  assert.equal(statSync(home).mode & 0o777, 0o700);
  const devices = (await phone.api("GET", "devices")).devices;
  assert.deepEqual(devices.filter((d) => d.kind === "agent").map((d) => d.name), ["Claude"]);
  assert.equal(JSON.parse((await run(["status"], env)).out).items, 2);

  const mcp = serve([], env);
  const init = await mcp.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
  assert.equal(init.result.serverInfo.name, "trove-mcp");
  mcp.notify("notifications/initialized");
  assert.equal((await mcp.request("tools/list")).result.tools.length, 6);

  const found = await mcp.tool("search", { query: "miso" });
  assert.equal(found.structuredContent.results[0].id, ramen);
  assert.equal((await mcp.tool("read_item", { id: ramen })).structuredContent.body, "White miso, soft eggs #food");
  assert.deepEqual((await mcp.tool("list_folders")).structuredContent.folders.map((f) => f.path), ["Links", "Recipes"]);

  // Something added on the phone while the server runs shows up after the next sync.
  phone.addNote({ title: "Later", body: "Added while Claude was connected" });
  await phone.sync();
  const made = (await mcp.tool("create_note", { title: "Trip summary", body: "Ramen in Tokyo, by Claude", folder: "Notes/Claude", tags: ["ai"] })).structuredContent;
  assert.equal(made.synced, true);
  assert.equal((await mcp.tool("search", { query: "connected" })).structuredContent.count, 1);
  await mcp.stop();

  await phone.sync();
  const note = phone.item(made.id);
  assert.equal(note.title, "Trip summary");
  assert.equal(note.body, "Ramen in Tokyo, by Claude");
  assert.deepEqual(note.tags, ["ai"]);
  assert.equal(note.isAutoFiled, false);

  const ro = serve(["--read-only"], env);
  await ro.request("initialize", { protocolVersion: "2025-06-18", capabilities: {} });
  assert.deepEqual((await ro.request("tools/list")).result.tools.map((t) => t.name), ["search", "read_item", "list_recent", "list_folders"]);
  assert.equal((await ro.tool("create_note", { body: "nope" })).isError, true);
  assert.equal((await ro.tool("list_recent", { limit: 1 })).structuredContent.items[0].title, "Trip summary");
  await ro.stop();

  // Forgetting revokes the device on the relay and deletes the keys.
  assert.equal((await run(["forget"], env)).code, 0);
  assert.equal((await phone.api("GET", "devices")).devices.find((d) => d.kind === "agent").revoked, true);
  assert.equal((await run(["status"], env)).code, 1);
});
