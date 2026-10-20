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
// Local relays are reached directly; a deployed one goes through HTTPS_PROXY when the machine has one.
const local = /^http:\/\/(127\.0\.0\.1|localhost)/.test(BASE);
const proxy = !local && process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
before(async () => { browser = await chromium.launch({ executablePath: findChromium(), args: proxy ? [] : ["--no-proxy-server"], proxy }); });
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
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill("not a code");
  await page.getByRole("button", { name: "Connect" }).click();
  await page.getByText("doesn't look like a Trove setup code").waitFor();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.locator("#device-name").fill("Chrome on Test");
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

  // Upload (through Import): encrypted in the page, readable on the phone.
  await page.locator("#upload").setInputFiles({ name: "receipt.pdf", mimeType: "application/pdf", buffer: Buffer.from("total £12.50") });
  await page.locator(".dz-done").waitFor();
  const uploaded = await until(async () => { await phone.sync(); return phone.items().find((i) => i.title === "receipt"); }, "uploaded file on the phone");
  assert.equal(new TextDecoder().decode(await phone.attachment(uploaded.attachments[0].id)), "total £12.50");

  // A zip export (the Swift test fixture) is opened in the page: notes, links and highlights land on the phone.
  await page.getByRole("button", { name: "Import more" }).click();
  if (shots) await page.screenshot({ path: join(shots, "web-import.png") });
  await page.locator("#import-files").setInputFiles(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/import-sample.zip", import.meta.url).pathname);
  await page.locator(".dz-summary", { hasText: "Added 7 things" }).waitFor({ timeout: 15000 });
  if (shots) {
    await page.waitForTimeout(1000);
    await page.screenshot({ path: join(shots, "web-import-done.png") });
  }
  await until(async () => {
    await phone.sync();
    const items = phone.items();
    return ["Big ideas", "Inside", "Example", "Dune"].every((t) => items.some((i) => i.title === t));
  }, "zip contents on the phone");
  await page.getByRole("button", { name: "Show them" }).click();

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
  const problemsBeforeRemoving = [...problems];
  await page.getByRole("button", { name: "Remove this browser" }).click();
  await page.getByRole("button", { name: "Create my vault" }).waitFor();
  const devices = await (await fetch(`${BASE}/v1/vaults/${v.mac.vaultId}/devices`, { headers: { authorization: `Bearer ${v.mac.deviceToken}` } })).json();
  assert.equal(devices.devices.find((d) => d.name === "Chrome on Test")?.revoked, true);

  // (A sync already in flight when the browser revokes itself may log a 401; that's expected.)
  assert.deepEqual(problemsBeforeRemoving, []);
  await context.close();
});

test("create a vault in the browser, save the recovery code, add a second browser and recover", async () => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 820 } });
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });

  await page.goto(BASE + "/");
  await page.locator("#create-name").fill("Work laptop");
  await page.getByRole("button", { name: "Create my vault" }).click();
  await page.getByRole("heading", { name: "Save your recovery code" }).waitFor();
  const recovery = await page.getByLabel("Recovery code").inputValue();
  assert.ok(recovery.length > 100);
  assert.equal(await page.getByRole("button", { name: "Open my vault" }).isDisabled(), true);
  await page.getByLabel("I've saved it somewhere safe").check();
  await page.getByRole("button", { name: "Open my vault" }).click();
  await page.getByLabel("Quick capture").fill("Made in a brand-new vault");
  await page.keyboard.press("Enter");
  await page.locator(".card", { hasText: "Made in a brand-new vault" }).waitFor();

  // Clipboard history: paste in, refuse passwords, click to copy back.
  await page.locator("nav a", { hasText: "Clipboard" }).click();
  await page.evaluate(() => navigator.clipboard.writeText("#ff8a3d"));
  await page.getByRole("button", { name: "Paste", exact: true }).click();
  await page.locator(".clip", { hasText: "#ff8a3d" }).waitFor();
  await page.evaluate(() => navigator.clipboard.writeText("Tr0ub4dor&3x!"));
  await page.getByRole("button", { name: "Paste", exact: true }).click();
  await page.getByText("looks like a password").waitFor();
  assert.equal(await page.locator(".clip", { hasText: "Tr0ub4dor" }).count(), 0);
  await page.evaluate(() => navigator.clipboard.writeText('{"b":1,"a":2}'));
  await page.getByRole("button", { name: "Paste", exact: true }).click();
  await page.locator(".clip", { hasText: '{"b":1' }).getByRole("button", { name: "More" }).click();
  await page.getByRole("button", { name: "Pretty JSON" }).click();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), '{\n  "b": 1,\n  "a": 2\n}');
  await page.locator(".clip", { hasText: "#ff8a3d" }).locator(".clip-main").click();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "#ff8a3d");
  // Rename, tag and edit a clip; it shows up in the main search.
  const blob = page.locator(".clip.open");
  await blob.getByLabel("Name").fill("Settings blob");
  await blob.getByLabel("Name").press("Enter");
  await page.locator(".clip-title", { hasText: "Settings blob" }).waitFor();
  await blob.getByLabel("Tags").fill("config, #Work");
  await blob.getByLabel("Tags").press("Enter");
  await page.locator(".clip-tags", { hasText: "#config #work" }).waitFor();
  await blob.getByLabel("Text").fill('{"b":1,"a":3}');
  await blob.getByRole("button", { name: "Save text" }).click();
  await page.locator(".clip-preview", { hasText: '{"b":1,"a":3}' }).waitFor();
  await blob.getByText("Size").waitFor();
  if (shots) await page.screenshot({ path: join(shots, "web-clipboard.png") });
  await page.locator("nav a", { hasText: "Everything" }).click();
  await page.locator("#search").fill("tag:config");
  await page.locator("#clip-results .clip", { hasText: "Settings blob" }).waitFor();
  await page.locator("#search").fill("");

  // Your tags: make one with a colour, put a clip in it, filter by it, find it with #tag.
  await page.locator("nav a", { hasText: "Clipboard" }).click();
  await page.locator(".clip-main", { hasText: "Settings blob" }).waitFor();
  await page.locator("#clip-tools .tag-add").click();
  await page.getByLabel("Tag name").fill("Receipts");
  await page.locator(".tag-edit").getByRole("radio", { name: "green" }).click();
  await page.locator(".tag-edit").getByRole("button", { name: "Add" }).click();
  await page.locator("#clip-tools .tag-filter", { hasText: "receipts" }).waitFor();
  if (!(await page.locator(".clip.open", { hasText: "Settings blob" }).count())) {
    await page.locator(".clip", { hasText: "Settings blob" }).getByRole("button", { name: "More" }).click();
  }
  await page.locator(".clip.open .tag-filter", { hasText: "receipts" }).click();
  await page.locator(".clip-tag.coloured", { hasText: "#receipts" }).waitFor();
  await page.locator("#clip-tools .tag-filter", { hasText: "receipts" }).click();
  await until(async () => (await page.locator("#grid .clip").count()) === 1, "only the tagged clip");
  await page.locator("#clip-tools .tag-filter", { hasText: "receipts" }).click();
  // Typing anywhere in the clipboard goes to the search box.
  await page.locator("#heading").click();
  await page.keyboard.type("#receipts");
  assert.equal(await page.locator("#search").inputValue(), "#receipts");
  await until(async () => (await page.locator("#grid .clip").count()) === 1, "#tag search");
  await page.locator("#search").fill("");

  // Sketches have their own section with a way in.
  await page.locator("nav a", { hasText: "Sketches" }).click();
  await page.getByRole("button", { name: "New sketch" }).waitFor();

  // Links save themselves into the library once you ask for that.
  await page.locator("nav a", { hasText: "Clipboard" }).click();
  await page.locator(".clip-settings summary").click();
  await page.locator(".clip-settings").getByRole("button", { name: "Links" }).click();
  await page.locator(".clip-settings").getByRole("button", { name: "Links", pressed: true }).waitFor();
  await page.evaluate(() => navigator.clipboard.writeText("https://github.com/mrlancus/trove"));
  await page.getByRole("button", { name: "Paste", exact: true }).click();
  await page.locator(".clip-tags", { hasText: "#link #github" }).waitFor();
  await page.locator("nav a", { hasText: "Everything" }).click();
  await page.locator(".card", { hasText: "github.com" }).waitFor();

  // Share link (what the iPhone Shortcut opens).
  await page.goto(BASE + "/#add=" + encodeURIComponent("https://example.net/shared"));
  await page.locator(".card", { hasText: "example.net" }).waitFor();

  // Make a setup code for a second browser.
  await page.getByRole("button", { name: "Devices & extension" }).click();
  await page.getByLabel("Recovery code").fill(recovery);
  await page.getByRole("button", { name: "Make a setup code" }).click();
  await page.locator("#setup-out").waitFor();
  const setup = await page.getByLabel("Setup code", { exact: true }).inputValue();
  assert.ok((await page.getByLabel("Extension setup code").inputValue()).length > 50);
  if (shots) await page.screenshot({ path: join(shots, "web-devices.png") });
  await page.getByRole("button", { name: "Close" }).click();
  await page.waitForTimeout(1500); // let the capture sync

  const other = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const phone = await other.newPage();
  await phone.goto(BASE + "/");
  await phone.getByRole("tab", { name: "Setup code" }).click();
  await phone.getByLabel("Setup code").fill(setup);
  await phone.getByRole("button", { name: "Connect" }).click();
  await phone.locator(".card", { hasText: "Made in a brand-new vault" }).waitFor();
  await phone.locator("#menu").click();
  await phone.locator("nav a", { hasText: "Clipboard" }).click();
  await phone.locator(".clip", { hasText: "#ff8a3d" }).waitFor();
  await other.close();

  // A third browser recovers with the recovery code alone.
  const third = await browser.newContext();
  const fresh = await third.newPage();
  await fresh.goto(BASE + "/");
  await fresh.getByRole("tab", { name: "Recover" }).click();
  await fresh.getByLabel("Recovery code").fill(recovery);
  await fresh.getByRole("button", { name: "Recover my vault" }).click();
  await fresh.locator(".card", { hasText: "Made in a brand-new vault" }).waitFor();
  await third.close();

  assert.deepEqual(problems, []);
  await context.close();
});
