// Search in real Chromium against a running relay (see relay.e2e.mjs for how to start it): the search
// Worker answers, typos and "phrases" work, matching words show bold in a snippet (handwriting too),
// and the index is saved encrypted in IndexedDB and used again after a reload.
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

test("search: Worker answers, typos, phrases, snippets, saved index", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  phone.addNote({ title: "Weeknight dinners", body: "Monday: pasta carbonara with lots of pepper. Tuesday: leftovers." });
  phone.addNote({ title: "Typing practice", body: "The quick brown fox jumps over the lazy dog." });
  phone.addNote({ title: "Fox facts", body: "A fox can be quick, and brown." });
  const sketch = phone.addSketch({ title: "Lecture" });
  phone.update(sketch, { inkText: "mitochondria is the powerhouse of the cell" });
  await phone.sync();

  const context = await browser.newContext({ viewport: { width: 1280, height: 820 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator(".card", { hasText: "Weeknight dinners" }).waitFor();

  const search = page.getByLabel("Search");
  // A typo still finds it, and the word shows bold in the passage.
  await search.fill("carbonra");
  await page.locator("#heading", { hasText: "1 result" }).waitFor();
  assert.equal(await page.locator(".card .snippet.found b").first().innerText(), "carbonara");
  // "Phrases" match word for word; without quotes both notes match.
  await search.fill('"quick brown fox"');
  await page.locator("#heading", { hasText: "1 result" }).waitFor();
  await page.locator(".card", { hasText: "Typing practice" }).waitFor();
  await search.fill("quick brown fox");
  await page.locator("#heading", { hasText: "2 results" }).waitFor();
  // Handwriting hits say so.
  await search.fill("powerhouse");
  await page.locator(".card .snippet-label", { hasText: "Handwriting" }).waitFor();
  await search.fill("has:ink");
  await page.locator("#heading", { hasText: "1 result" }).waitFor();
  await search.fill("fox -lazy");
  await page.locator("#heading", { hasText: "1 result" }).waitFor();
  await page.locator(".card", { hasText: "Fox facts" }).waitFor();
  await search.fill("");
  await page.locator(".card", { hasText: "Weeknight dinners" }).waitFor();

  // The index is saved (encrypted) a moment after changes, and a reload searches straight from it.
  await page.waitForTimeout(3500);
  const saved = await page.evaluate(() => new Promise((resolve) => {
    const req = indexedDB.open("trove-search");
    req.onsuccess = () => {
      const tx = req.result.transaction("kv", "readonly").objectStore("kv").getAllKeys();
      tx.onsuccess = () => resolve(tx.result);
    };
    req.onerror = () => resolve([]);
  }));
  assert.ok(saved.includes("key") && saved.some((k) => String(k).startsWith("index:")), String(saved));
  await page.reload();
  await page.locator(".card", { hasText: "Weeknight dinners" }).waitFor();
  await search.fill("carbonara");
  await page.locator("#heading", { hasText: "1 result" }).waitFor();
  assert.deepEqual(problems, []);
  await context.close();
});
