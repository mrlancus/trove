#!/usr/bin/env node
// trove-mcp: Trove for Claude. Joins your vault as its own device ("agent") and answers MCP over stdio.
//   trove-mcp join <setup code> [--name "Claude"]   once, with a setup code from Trove (Devices)
//   trove-mcp [--read-only]                         what Claude Desktop / Claude Code run
//   trove-mcp status                                which vault and device this is
//   trove-mcp forget                                remove this device from the vault and delete its keys
import { b64uEncode, utf8 } from "../../web/public/core/bytes.js";
import { parseSetupCode, Vault } from "../../web/public/core/vault.js";
import { serveStdio, TroveMCP } from "../src/server.js";
import { FileStorage, homeDir } from "../src/store.js";

const log = (...a) => console.error("[trove-mcp]", ...a);
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const command = args.find((a, i) => !a.startsWith("--") && !(i > 0 && args[i - 1].startsWith("--") && ["--name", "--relay"].includes(args[i - 1])));

async function join(code) {
  if (!code) throw new Error("Usage: trove-mcp join <setup code> [--name \"Claude\"] [--relay https://…]");
  const storage = new FileStorage();
  if (storage.exists) throw new Error(`This computer already joined a vault (${homeDir()}). Run "trove-mcp forget" first.`);
  const payload = parseSetupCode(code);
  // This device never needs the inbox private key: keep only the vault key, like a least-privilege web app.
  const { privateKey: _dropped, ...keys } = payload.keys;
  const trimmed = b64uEncode(utf8.encode(JSON.stringify({ ...payload, keys })));
  storage.setRawKeys(keys);
  const vault = await Vault.join(storage, trimmed, { origin: option("--relay") ?? payload.relayURL, deviceName: option("--name") ?? "Claude (trove-mcp)", deviceKind: "agent" });
  const report = await vault.sync();
  log(`Joined vault ${vault.config.vaultId} as ${vault.config.deviceName} (${vault.items().length} items). Keys are in ${homeDir()}.`);
  if (report.errors.length) log(`sync: ${report.errors.join("; ")}`);
}

async function open() {
  const storage = new FileStorage();
  if (!storage.exists) throw new Error(`Not set up yet. In Trove open Devices, make a setup code, then run: trove-mcp join <setup code>`);
  return Vault.open(storage);
}

async function main() {
  if (command === "join") return join(args[args.indexOf("join") + 1]);
  if (command === "status") {
    const vault = await open();
    console.log(JSON.stringify({ relay: vault.config.base, vaultId: vault.config.vaultId, deviceId: vault.config.deviceId, deviceName: vault.config.deviceName,
      items: vault.items().length, home: homeDir() }, null, 2));
    return;
  }
  if (command === "forget") {
    const vault = await open();
    await vault.forget();
    log("This device was removed from the vault and its keys deleted.");
    return;
  }
  if (command && command !== "serve") throw new Error(`Unknown command "${command}". Use join, status, forget, or no command to serve.`);
  const vault = await open();
  const server = new TroveMCP(vault, { readOnly: flag("--read-only"), log });
  server.freshen(true).catch(() => {}); // first sync in the background; tools wait for it
  await serveStdio(server);
  await vault.save();
}

main().then(() => process.exit(0), (e) => { log(e.message); process.exit(1); });
