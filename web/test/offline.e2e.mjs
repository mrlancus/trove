// The website offline and at rest, in real Chromium against a running relay (see relay.e2e.mjs):
// the service worker caches the app so it opens without a connection, IndexedDB holds only sealed
// data, and storage from before encryption at rest still opens and is rewritten sealed.
import assert from "node:assert/strict";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { chromium } from "playwright-core";
import { Vault } from "../public/core/vault.js";
import { BASE, createVault, memoryStorage } from "./helpers.mjs";

function findChromium() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH ?? "/opt/pw-browsers";
  const dir = readdirSync(root).find((d) => /^chromium-\d+$/.test(d));
  const exe = dir && join(root, dir, "chrome-linux", "chrome");
  if (!exe || !existsSync(exe)) throw new Error("Chromium not found; set CHROMIUM_PATH");
  return exe;
}

let browser;
const local = /^http:\/\/(127\.0\.0\.1|localhost)/.test(BASE);
const proxy = !local && process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
before(async () => { browser = await chromium.launch({ executablePath: findChromium(), args: proxy ? [] : ["--no-proxy-server"], proxy }); });
after(async () => { await browser?.close(); });

async function until(check, what, timeout = 15000) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 150));
  }
}

/** Every key and value in the website's IndexedDB store, values as JSON (bytes shown as "bytes"). */
const dumpStorage = (page) => page.evaluate(async () => {
  const { storage } = await import("/db.js");
  const db = await new Promise((resolve, reject) => { const r = indexedDB.open("trove", 1); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
  const keys = await new Promise((resolve) => { const r = db.transaction("kv").objectStore("kv").getAllKeys(); r.onsuccess = () => resolve(r.result); });
  db.close();
  const out = {};
  for (const k of keys) {
    const v = await storage.get(k);
    out[k] = v instanceof CryptoKey ? "CryptoKey" : JSON.stringify(v, (_, x) => (x instanceof Uint8Array || x instanceof ArrayBuffer ? "bytes" : x instanceof CryptoKey ? "CryptoKey" : x));
  }
  return out;
});

test("offline app, sealed IndexedDB, and old plain storage migrates", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  phone.addNote({ title: "Plum jam", body: "secret recipe with cardamom" });
  await phone.sync();

  const context = await browser.newContext({ viewport: { width: 1200, height: 860 } });
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(e.message));

  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#grid .card", { hasText: "Plum jam" }).waitFor();

  // Installable: the manifest and its icons are there.
  const manifest = await (await fetch(`${BASE}/manifest.webmanifest`)).json();
  assert.ok(manifest.icons.some((i) => i.sizes === "512x512" && i.purpose === "maskable"));
  for (const icon of manifest.icons) assert.equal((await fetch(BASE + icon.src)).status, 200, icon.src);

  // The service worker takes over and caches the app, including the lazily loaded drawing code.
  await until(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)), "service worker in control");
  await until(() => page.evaluate(async () => {
    const keys = (await (await caches.open("trove-shell-1")).keys()).map((r) => new URL(r.url).pathname);
    return ["/", "/app.js", "/core/vault.js", "/core/localstore.js", "/draw.js"].every((p) => keys.includes(p));
  }), "the app shell in the cache");
  const cached = await page.evaluate(async () => (await (await caches.open("trove-shell-1")).keys()).map((r) => new URL(r.url).pathname));
  assert.ok(!cached.some((p) => p.startsWith("/v1/")), "relay data is never cached");

  // At rest: chunks and journal are sealed; no note text anywhere.
  await page.waitForTimeout(1500); // the debounced save
  let stored = await dumpStorage(page);
  assert.ok(stored.opChunks && !("ops" in stored));
  for (const k of ["journal", "applied", "cursor", ...Object.keys(stored).filter((k) => k.startsWith("ops."))]) {
    if (k in stored) assert.match(stored[k], /"sealed":1/, `${k} is sealed`);
  }
  assert.ok(!Object.values(stored).some((x) => /cardamom|Plum jam/.test(x)), "no note text in IndexedDB");

  // Offline: a reload still opens the app and the vault from this browser.
  await context.setOffline(true);
  await page.reload();
  await page.locator("#grid .card", { hasText: "Plum jam" }).waitFor();
  assert.equal(await page.evaluate(() => fetch("/health").then(() => "online", () => "offline")), "offline", "really offline");
  await context.setOffline(false);

  // Storage from before encryption at rest (plain values, every op under "ops") still opens.
  await page.evaluate(async () => {
    const { storage } = await import("/db.js");
    const { LocalStore } = await import("/core/localstore.js");
    await storage.set("localOwner", "someone-else"); // the open page stops writing
    const saved = await new LocalStore(storage).load();
    const index = await storage.get("opChunks");
    for (const c of index.chunks) await storage.delete(`ops.${c.n}`);
    await storage.delete("opChunks");
    await storage.delete("localKey");
    await storage.set("ops", saved.ops);
    await storage.set("journal", saved.journal);
    await storage.set("applied", saved.applied);
    await storage.set("cursor", saved.cursor);
  });
  stored = await dumpStorage(page);
  assert.ok(/cardamom/.test(stored.ops), "the old layout is plain");
  await page.reload();
  await page.locator("#grid .card", { hasText: "Plum jam" }).waitFor();
  stored = await until(async () => { const s = await dumpStorage(page); return s.opChunks && !("ops" in s) ? s : null; }, "the migration");
  assert.ok(!Object.values(stored).some((x) => /cardamom|Plum jam/.test(x)), "rewritten sealed");
  assert.deepEqual(problems, []);
  await context.close();
});
