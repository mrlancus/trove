// Bridges against a running relay (see relay.e2e.mjs for how to start it): a webhook "add" address
// seals into the inbox and the website imports it into the folder it asked for; then the Bridges
// screen in real Chromium.
import assert from "node:assert/strict";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { chromium } from "playwright-core";
import { folderPathOf } from "../public/core/organize.js";
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

const path = (v, item) => folderPathOf(item.folder, v.folders()).map((f) => f.name);

test("a webhook add address lands in the inbox and is imported into its folder", async () => {
  const v = await createVault();
  const web = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "Chrome" });
  const hook = await web.api("POST", "bridges", { body: { kind: "webhook", settings: { name: "Shortcuts", folder: "Inbox/Phone", tags: ["phone"] } }, expect: [201] });
  assert.match(hook.hookURL, /\/hook\/[A-Za-z0-9_-]+\/thk_/);

  const post = (body, type = "application/json") => fetch(hook.hookURL, { method: "POST", headers: { "content-type": type }, body });
  assert.equal((await post(JSON.stringify({ url: "https://example.org/read?utm_source=x", title: "To read", tags: ["later"] }))).status, 201);
  assert.equal((await post("Call the dentist #health", "text/plain")).status, 201);
  assert.equal((await post(JSON.stringify({ text: "Filed elsewhere", folder: "Errands" }))).status, 201);

  const report = await web.sync();
  assert.deepEqual(report.errors, []);
  assert.equal(report.imported, 3);
  const items = web.items();
  const link = items.find((i) => i.kind === "link");
  assert.equal(link.url.toString(), "https://example.org/read");
  assert.equal(link.title, "To read");
  assert.deepEqual(path(web, link), ["Inbox", "Phone"]);
  assert.deepEqual(link.tags, ["later", "phone"]);
  assert.equal(link.record.fields.origin.bridge, "webhook");
  const note = items.find((i) => i.body === "Call the dentist #health");
  assert.deepEqual(note.tags, ["health", "phone"]);
  assert.deepEqual(path(web, items.find((i) => i.body === "Filed elsewhere")), ["Errands"]);

  // The inbox is empty again, and the bridge counted what it added.
  assert.equal((await web.api("GET", "inbox")).entries.length, 0);
  const status = await web.api("GET", `bridges/${hook.id}`);
  assert.equal(status.status.itemsAdded, 3);

  // A second device sees the same items after syncing.
  const other = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "Firefox" });
  await other.sync();
  assert.deepEqual(path(other, other.item(link.id)), ["Inbox", "Phone"]);
});

test("the Bridges screen makes an add address, turns it off and follows a feed", async () => {
  const v = await createVault();
  const context = await browser.newContext({ viewport: { width: 1200, height: 860 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept());
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.getByRole("button", { name: "Bridges" }).click();
  const dialog = page.getByRole("dialog", { name: "Bridges" });
  await dialog.getByRole("button", { name: "Make an add address" }).click();
  const address = dialog.getByLabel("Add address");
  await address.waitFor();
  const url = await address.inputValue();
  assert.match(url, new RegExp(`^${BASE}/hook/`));

  // Something sent to the address shows up in the website.
  assert.equal((await fetch(url, { method: "POST", body: JSON.stringify({ text: "Sent from a Shortcut", title: "From my phone" }) })).status, 201);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Sync now" }).click();
  await page.locator(".card", { hasText: "From my phone" }).first().waitFor();

  // Off: the address refuses posts, and the screen says so.
  await page.getByRole("button", { name: "Bridges" }).click();
  await dialog.getByLabel("On").first().uncheck();
  await dialog.getByText(/^Off ·/).waitFor();
  assert.equal((await fetch(url, { method: "POST", body: "nope" })).status, 403);

  // A feed that can't be reached is listed with its problem after a check.
  await dialog.getByLabel("Feed address").fill("https://feed.invalid/rss.xml");
  await dialog.getByRole("button", { name: "Follow" }).click();
  await dialog.getByText("https://feed.invalid/rss.xml").waitFor();
  await dialog.getByRole("button", { name: "Check now" }).click();
  await dialog.getByText(/^Last problem:/).waitFor({ timeout: 15000 });
  assert.deepEqual(problems, []);
  await context.close();
});
