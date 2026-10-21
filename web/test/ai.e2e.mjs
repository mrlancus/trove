// AI and looking back in real Chromium against a running relay (see relay.e2e.mjs for how to start
// it). The test relay has no Anthropic key, so cloud AI is off; the second test stands in for a relay
// with AI on by answering its AI routes in the browser (no network, no cost).
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

async function open(setup) {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const ids = setup(phone);
  await phone.sync();
  const context = await browser.newContext({ viewport: { width: 1280, height: 820 }, serviceWorkers: "block" }); // so page.route sees the API calls
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept("French"));
  return { v, phone, ids, page, problems, context };
}

async function connect(page, v) {
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.locator("#device-name").fill("Chrome AI test");
  await page.getByRole("button", { name: "Connect" }).click();
}

const sample = (phone) => ({
  bread: phone.addNote({ title: "Sourdough notes", body: "Feed the sourdough starter twice a day with rye flour.\n\nBake at 250C." }),
  starter: phone.addNote({ title: "Starter schedule", body: "My sourdough starter lives in the fridge." }),
  trip: phone.addNote({ title: "Lisbon trip", body: "Bring a sourdough loaf for the hosts." }),
  link: phone.addLink("https://example.com/sourdough?utm_source=news", { title: "The complete sourdough guide for beginners" }).id,
  dupe: phone.addLink("https://bakery.example/sourdough-guide-from-bakery", { title: "The complete sourdough guide for beginners" }).id,
});

test("with cloud AI off: no Ask Trove or AI menu, but look back and link suggestions work", async () => {
  const { v, page, problems, context } = await open(sample);
  await connect(page, v);
  await page.locator(".card", { hasText: "Sourdough notes" }).waitFor();
  assert.equal(await page.locator("#ask").isVisible(), false);

  await page.getByRole("button", { name: "AI", exact: true }).click();
  await page.getByText("Cloud AI is off.").waitFor();
  await page.getByRole("button", { name: "Close" }).click();

  await page.locator(".card", { hasText: "Lisbon trip" }).click();
  await page.locator("#detail .preview").waitFor();
  assert.equal(await page.locator("#detail .ai-menu").isVisible(), false);
  await page.getByRole("button", { name: "Suggest links" }).click();
  const chip = page.locator(".suggest-links .link-chip").first();
  await chip.waitFor();
  await chip.getByRole("button", { name: "Connect" }).click();
  await page.locator(".link-group", { hasText: "Links to" }).waitFor();

  await page.getByRole("button", { name: "Look back" }).click();
  await page.locator(".dupe", { hasText: "Same title" }).waitFor();
  await page.getByRole("button", { name: "Make this week's digest" }).click();
  await page.locator("#detail .preview", { hasText: "You saved 2 things and wrote 3 notes this week." }).waitFor();
  assert.match(await page.locator("#detail .title-input").inputValue(), /^Week of /);
  assert.deepEqual(problems, []);
  await context.close();
});

test("with cloud AI on (relay answered in the browser): ask, cite, save, and AI on a note", async () => {
  const { v, ids, page, problems, context } = await open(sample);
  let used = 1200;
  const status = () => ({ enabled: true, vaultEnabled: true, configured: true, model: "claude-haiku-5-5", month: "2026-10", used, limit: 1_000_000, unit: "tokens", resetsAt: "2026-11-01T00:00:00.000Z" });
  let asked = null;
  await page.route("**/ai/status", (r) => r.fulfill({ json: status() }));
  await page.route("**/ai/ask", (r) => {
    asked = r.request().postDataJSON();
    used += 900;
    r.fulfill({ json: { answer: "Twice a day, with rye flour.", citations: [ids.bread, "not-sent"], tokens: 900, model: "claude-haiku-5-5", usage: status() } });
  });
  await page.route("**/ai/action", (r) => {
    const body = r.request().postDataJSON();
    r.fulfill({ json: { action: body.action, text: `Short: ${body.text.slice(0, 10)}`, cards: [], model: "claude-haiku-5-5", tokens: 50, usage: status() } });
  });
  await connect(page, v);
  await page.locator(".card", { hasText: "Sourdough notes" }).waitFor();
  await page.locator("html.ai-on").waitFor({ state: "attached" });
  await page.locator("#ask").click();
  await page.getByLabel("Your question").fill("How often do I feed my sourdough starter?");
  await page.getByRole("button", { name: "Ask", exact: true }).click();
  await page.getByText("Twice a day, with rye flour.").waitFor();
  await page.getByText("Processed in the cloud by claude-haiku-5-5").waitFor();
  // Only local snippets went out, at most 20, the best one first.
  assert.ok(asked.sources.length >= 2 && asked.sources.length <= 20);
  assert.equal(asked.sources[0].id, ids.bread);
  assert.ok(asked.sources.every((s) => s.text.length <= 1200));
  await page.getByRole("button", { name: "Save as note" }).click();
  await page.locator("#detail .preview a.wikilink", { hasText: "Sourdough notes" }).waitFor();
  assert.equal(await page.locator("#detail .title-input").inputValue(), "How often do I feed my sourdough starter?");

  // The citation opens its item (the open item covers the toolbar, so close it first).
  await page.locator("#detail").getByRole("button", { name: "Close" }).click();
  await page.locator("#ask").click();
  await page.getByLabel("Your question").fill("sourdough starter?");
  await page.getByRole("button", { name: "Ask", exact: true }).click();
  await page.locator(".ask-out .link-chip a", { hasText: "Sourdough notes" }).click();
  assert.equal(await page.locator("#detail .title-input").inputValue(), "Sourdough notes");

  // AI on a note: make shorter, then replace.
  await page.locator("#detail .ai-menu summary").click();
  await page.getByRole("button", { name: "Make shorter" }).click();
  await page.getByText("Short: Feed the s").waitFor();
  await page.getByRole("button", { name: "Replace" }).click();
  await page.locator("#detail .preview", { hasText: "Short: Feed the s" }).waitFor();

  // Settings show this month's use.
  await page.getByRole("button", { name: "AI", exact: true }).click();
  await page.locator("#ai-usage", { hasText: "tokens used" }).waitFor();
  assert.deepEqual(problems, []);
  await context.close();
});
