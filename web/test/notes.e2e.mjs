// Today's note, templates and checklists in real Chromium against a running relay (see relay.e2e.mjs
// for how to start it). PROTOCOL.md §12.
import assert from "node:assert/strict";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { chromium } from "playwright-core";
import { dailyNoteId, dateParts, longDate } from "../public/core/notes.js";
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

const until = async (check, ms = 15_000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await check()) return true; await new Promise((r) => setTimeout(r, 300)); }
  return false;
};

for (const viewport of [{ width: 1280, height: 820 }, { width: 375, height: 760 }]) {
  test(`today's note, templates and ticking checkboxes (${viewport.width} px)`, async () => {
    const v = await createVault();
    const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
    const standup = phone.addNote({ title: "Standup {date}", body: "Yesterday: \n- [ ] Blockers for {title}", tags: ["template", "work"] });
    await phone.sync();

    const context = await browser.newContext({ viewport, serviceWorkers: "block" });
    const page = await context.newPage();
    const problems = [];
    page.on("pageerror", (e) => problems.push(e.message));
    await page.goto(BASE + "/");
    await page.getByRole("tab", { name: "Setup code" }).click();
    await page.getByLabel("Setup code").fill(await v.setupCode());
    await page.locator("#device-name").fill("Chrome notes test");
    await page.getByRole("button", { name: "Connect" }).click();
    await page.locator(".card", { hasText: "Standup" }).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, "no sideways scrolling");

    // Today: made from the built-in daily template, then ticked.
    const today = dateParts();
    await page.locator("#today").click();
    await page.locator(".detail .title-input").waitFor();
    assert.equal(await page.locator(".detail .title-input").inputValue(), longDate(today));
    const box = page.locator(".detail .preview input[data-box='0']");
    await box.check();
    assert.ok(await until(async () => { await phone.sync(); return phone.item(dailyNoteId(today))?.body.includes("- [x] "); }), "the tick reaches the phone");
    assert.equal(phone.item(dailyNoteId(today)).record.fields.daily, dailyNoteId(today).slice(6));
    assert.deepEqual(phone.item(dailyNoteId(today)).tags, ["daily"]);

    // Opening Today again doesn't make another one.
    const close = () => page.locator(".detail-bar").getByRole("button", { name: "Close" }).click();
    await close();
    await page.locator("#today").click();
    await close();
    assert.equal(phone.items().filter((i) => i.id.startsWith("daily-")).length, 1);

    // From template: yours are listed first; placeholders filled in; the template tag left behind.
    const picker = page.locator("#new-from-template");
    await page.waitForTimeout(600);
    const labels = await picker.locator("option").allTextContents();
    assert.deepEqual(labels, ["From template…", "Standup", "Daily note", "Meeting", "Journal", "Recipe"]);
    await picker.selectOption({ label: "Standup" });
    await page.locator("#body-input").waitFor();
    const iso = `${today.year}-${String(today.month).padStart(2, "0")}-${String(today.day).padStart(2, "0")}`;
    assert.equal(await page.locator(".detail .title-input").inputValue(), `Standup ${iso}`);
    assert.equal(await page.locator("#body-input").inputValue(), `Yesterday: \n- [ ] Blockers for Standup ${iso}`);
    assert.ok(await until(async () => { await phone.sync(); return phone.items().some((i) => i.title === `Standup ${iso}` && i.tags.join() === "work"); }));

    // Use as template / not a template.
    await close();
    await page.locator(".card", { hasText: "Standup {date}" }).click();
    await page.getByRole("button", { name: "Not a template" }).click();
    assert.ok(await until(async () => { await phone.sync(); return !phone.item(standup).tags.includes("template"); }));
    assert.deepEqual(problems, []);
    await context.close();
  });
}
