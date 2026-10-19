// The web app in real Chromium against a running relay (see relay.e2e.mjs for how to start it).
// Set SCREENSHOTS=<dir> to save desktop and phone screenshots.
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

const shots = process.env.SCREENSHOTS;
let browser;
before(async () => { browser = await chromium.launch({ executablePath: findChromium(), args: ["--no-proxy-server"] }); });
after(async () => { await browser?.close(); });

async function until(check, what, timeout = 8000) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 150));
  }
}

test("set up with a code, browse, capture, edit, upload and get live updates", async () => {
  const v = await createVault();
  // The "iPhone" (here: the same core in Node) already has a few things.
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const recipe = phone.addNote({ title: "Miso ramen", body: "## Broth\n- 2 tbsp **white miso**\n- [x] buy noodles\n- [ ] soft eggs\n\nSee [[Trip]] #food\n\n<script>alert(1)</script>" });
  phone.update(recipe, { category: "recipe" });
  phone.addNote({ title: "Trip", body: "Tokyo in spring #travel" });
  phone.addLink("https://example.com/long-read", { title: "A long read" });
  await phone.sync();

  const context = await browser.newContext({ viewport: { width: 1280, height: 820 }, colorScheme: "dark" });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept());

  await page.goto(BASE + "/");
  await page.getByLabel("Setup code").fill("not a code");
  await page.getByRole("button", { name: "Connect" }).click();
  await page.getByText("doesn't look like a Trove setup code").waitFor();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByLabel("Name this browser").fill("Chrome on Test");
  await page.getByRole("button", { name: "Connect" }).click();

  await page.locator(".card", { hasText: "Miso ramen" }).waitFor();
  assert.equal(await page.locator(".card").count(), 3);
  await page.locator("#sync-status.live").waitFor();

  // Smart collections and search.
  await page.locator("nav a", { hasText: "Recipes" }).click();
  assert.equal(await page.locator(".card").count(), 1);
  await page.locator("nav a", { hasText: "Everything" }).click();
  await page.getByLabel("Search").fill("tokyo");
  await page.locator(".heading", { hasText: "1 result" }).waitFor();
  await page.getByLabel("Search").fill("");

  // Detail: Markdown preview is rendered, and the script tag is only text.
  await page.locator(".card", { hasText: "Miso ramen" }).click();
  await page.locator(".preview h3", { hasText: "Broth" }).waitFor();
  assert.equal(await page.locator(".preview strong").innerText(), "white miso");
  assert.equal(await page.locator(".preview script").count(), 0);
  assert.match(await page.locator(".preview").innerText(), /<script>alert\(1\)<\/script>/);
  if (shots) await page.screenshot({ path: join(shots, "web-desktop.png") });
  await page.locator(".preview a.wikilink").click();
  await page.locator(".title-input").and(page.locator('[value="Trip"]')).waitFor();
  await page.getByRole("button", { name: "Close" }).click();

  // Quick capture: a link and a note, both reach the phone.
  await page.getByLabel("Quick capture").fill("https://example.org/article?utm_source=news");
  await page.keyboard.press("Enter");
  await page.getByLabel("Quick capture").fill("Remember to buy #milk");
  await page.keyboard.press("Enter");
  await until(async () => { await phone.sync(); return phone.items().some((i) => i.body === "Remember to buy #milk"); }, "captured note on the phone");
  assert.ok(phone.items().some((i) => i.url?.toString() === "https://example.org/article"));
  assert.deepEqual(phone.items().find((i) => i.body === "Remember to buy #milk").tags, ["milk"]);

  // New note, typed in the editor.
  await page.getByRole("button", { name: "New note" }).click();
  await page.getByLabel("Title").fill("Typed in Chrome");
  await page.getByLabel("Title").press("Enter");
  await page.getByLabel("Note").fill("Hello from the browser\n- one\n- two");
  await page.locator("#saved", { hasText: "Saved" }).waitFor();
  await until(async () => { await phone.sync(); return phone.items().find((i) => i.title === "Typed in Chrome")?.body === "Hello from the browser\n- one\n- two"; }, "typed note on the phone");
  await page.getByRole("button", { name: "Close" }).click();

  // Upload: encrypted in the page, readable on the phone.
  await page.locator("#upload").setInputFiles({ name: "receipt.txt", mimeType: "text/plain", buffer: Buffer.from("total £12.50") });
  const uploaded = await until(async () => { await phone.sync(); return phone.items().find((i) => i.title === "receipt"); }, "uploaded file on the phone");
  assert.equal(new TextDecoder().decode(await phone.attachment(uploaded.attachments[0].id)), "total £12.50");

  // Live: something saved on the phone appears without a reload.
  phone.addNote({ title: "Live from the phone", body: "hi" });
  await phone.sync();
  await page.locator(".card", { hasText: "Live from the phone" }).waitFor({ timeout: 8000 });

  // Phone layout.
  if (shots) {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(400); // let the sidebar slide away
    await page.screenshot({ path: join(shots, "web-phone.png") });
    await page.locator(".card", { hasText: "Miso ramen" }).click();
    await page.screenshot({ path: join(shots, "web-phone-detail.png") });
    await page.getByRole("button", { name: "Close" }).click();
    await page.setViewportSize({ width: 1280, height: 820 });
  }

  // A second tab takes over; the first steps aside.
  const second = await context.newPage();
  await second.goto(BASE + "/");
  await second.locator(".card", { hasText: "Typed in Chrome" }).waitFor();
  await page.locator("#other-tab").waitFor({ state: "visible" });
  await second.close();

  // Removing the browser revokes it and returns to setup.
  await page.getByRole("button", { name: "Use it here" }).click();
  await page.getByRole("button", { name: "Remove this browser" }).click();
  await page.getByLabel("Setup code").waitFor();
  const devices = await (await fetch(`${BASE}/v1/vaults/${v.mac.vaultId}/devices`, { headers: { authorization: `Bearer ${v.mac.deviceToken}` } })).json();
  assert.equal(devices.devices.find((d) => d.name === "Chrome on Test")?.revoked, true);

  assert.deepEqual(problems, []);
  await context.close();
});
