// Drawing in real Chromium against a running relay (see relay.e2e.mjs for how to start it):
// a sketch drawn with the mouse and with pen events, undo/redo, the eraser, paper and pages, and
// ink on a PDF, all reaching a second device. SCREENSHOTS=<dir> saves screenshots.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
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
const local = /^http:\/\/(127\.0\.0\.1|localhost)/.test(BASE);
const proxy = !local && process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
before(async () => { browser = await chromium.launch({ executablePath: findChromium(), args: proxy ? [] : ["--no-proxy-server"], proxy }); });
after(async () => { await browser?.close(); });

async function until(check, what, timeout = 10000) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 150));
  }
}

/** A stroke with the mouse across a canvas, in fractions of its size. */
async function mouseStroke(page, canvas, from, to, steps = 12) {
  const box = await canvas.boundingBox();
  await page.mouse.move(box.x + box.width * from[0], box.y + box.height * from[1]);
  await page.mouse.down();
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    await page.mouse.move(box.x + box.width * (from[0] + (to[0] - from[0]) * t), box.y + box.height * (from[1] + (to[1] - from[1]) * t + Math.sin(t * 6) * 0.01));
  }
  await page.mouse.up();
}

/** A stroke with pen pointer events (pressure rising), like an Apple Pencil in Safari. */
async function penStroke(page, selector, from, to) {
  await page.evaluate(({ selector, from, to }) => {
    const c = document.querySelector(selector);
    const r = c.getBoundingClientRect();
    const at = (t) => ({ clientX: r.left + r.width * (from[0] + (to[0] - from[0]) * t), clientY: r.top + r.height * (from[1] + (to[1] - from[1]) * t) });
    const fire = (type, t, pressure) => c.dispatchEvent(new PointerEvent(type, { ...at(t), pointerId: 7, pointerType: "pen", pressure, bubbles: true, cancelable: true, isPrimary: true }));
    fire("pointerdown", 0, 0.2);
    for (let i = 1; i <= 20; i++) fire("pointermove", i / 20, 0.2 + 0.7 * (i / 20));
    fire("pointerup", 1, 0);
  }, { selector, from, to });
}

test("sketches and ink on files: draw, undo, erase, pages, and it all reaches another device", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource.*404/.test(m.text())) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept());

  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#search").waitFor();

  // A new sketch opens straight in the editor.
  await page.getByRole("button", { name: "✎ Sketch" }).click();
  const live = page.locator(".ink-page .ink-live").first();
  await live.waitFor();
  await until(async () => (await live.boundingBox())?.width > 300, "the page laid out");
  await mouseStroke(page, live, [0.1, 0.1], [0.8, 0.15]);
  await page.getByRole("button", { name: "Marker" }).click();
  await page.getByRole("button", { name: "Colour #ff3b30" }).click();
  await mouseStroke(page, live, [0.1, 0.3], [0.8, 0.35]);
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await penStroke(page, ".ink-page .ink-live", [0.1, 0.5], [0.7, 0.6]);
  const count = () => page.evaluate(() => document.querySelectorAll(".ink-editor").length);
  assert.equal(await count(), 1);

  // Undo, redo, then erase the red marker line.
  await page.getByRole("button", { name: "↶ Undo" }).click();
  await page.getByRole("button", { name: "↷ Redo" }).click();
  await page.getByRole("button", { name: "Eraser" }).click();
  await mouseStroke(page, live, [0.45, 0.25], [0.45, 0.42], 8);

  // Squared paper and a second page.
  await page.getByLabel("Paper").selectOption("grid");
  await page.getByRole("button", { name: "+ Page" }).click();
  await until(async () => (await page.locator(".ink-page").count()) === 2, "a second page");
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  const second = page.locator(".ink-page .ink-live").nth(1);
  await second.scrollIntoViewIfNeeded();
  await mouseStroke(page, second, [0.2, 0.2], [0.6, 0.5]);
  if (shots) await page.screenshot({ path: join(shots, "web-sketch-editor.png") });
  await page.getByRole("button", { name: "Done" }).click();
  await until(async () => (await count()) === 0, "the editor to close");

  // The sketch opens with its pages; its card gets a picture.
  await until(async () => (await page.locator(".sketch-page").count()) === 2, "the sketch's pages in the panel");
  await until(async () => (await page.locator("#grid .card.sketch img.thumb").count()) === 1, "a thumbnail on the card", 15000);
  if (shots) await page.screenshot({ path: join(shots, "web-sketch-panel.png") });

  // The phone has the same drawing: 2 strokes on page 1 (pen + pen-pressure), 1 on page 2.
  await page.getByRole("button", { name: "Sync now" }).click();
  const sketch = await until(async () => {
    await phone.sync();
    const s = phone.items().find((i) => i.kind === "sketch");
    if (s) globalThis.lastSeen = JSON.stringify({ paper: s.paper, pages: s.sketchPages, strokes: phone.strokes(s.id).map((x) => [x.page, x.tool, x.points.length]) });
    return s && s.paper === "grid" && s.sketchPages === 2 && phone.strokes(s.id).length === 3 ? s : null;
  }, "the sketch on the phone", 20000).catch((e) => { throw new Error(e.message + " " + globalThis.lastSeen); });
  const strokes = phone.strokes(sketch.id);
  assert.deepEqual(strokes.map((s) => [s.page, s.tool]), [[0, "pen"], [0, "pen"], [1, "pen"]]);
  const pressures = strokes[1].points.map((p) => p.p);
  assert.ok(pressures.at(-1) > pressures[0] + 0.3, "pen pressure is kept");
  assert.ok(strokes.every((s) => s.points.every((p) => p.x >= 0 && p.x <= 768 && p.y >= 0 && p.y <= 1024)), "points are in page points");

  // Ink on a PDF from the phone: the file stays, the ink is its own layer.
  const pdfBytes = new Uint8Array(readFileSync(new URL("./fixtures/files/sample.pdf", import.meta.url)));
  const pdfId = await phone.addFile(pdfBytes, "Worksheet.pdf", "application/pdf");
  await phone.sync();
  await page.getByRole("button", { name: "Sync now" }).click();
  await until(async () => (await page.locator("#grid .card", { hasText: "Worksheet" }).count()) === 1, "the PDF on the website", 15000);
  await page.locator("#grid .card", { hasText: "Worksheet" }).click();
  await page.getByRole("button", { name: "✎ Draw on it" }).click();
  await page.locator(".ink-page .ink-live").first().waitFor();
  await until(async () => (await page.locator(".ink-page .ink-live").first().boundingBox())?.width > 300, "the PDF page laid out");
  await page.getByRole("button", { name: "Highlighter" }).click();
  await mouseStroke(page, page.locator(".ink-page .ink-live").first(), [0.1, 0.2], [0.6, 0.2]);
  if (shots) await page.screenshot({ path: join(shots, "web-pdf-markup.png") });
  await page.getByRole("button", { name: "Done" }).click();
  await page.getByRole("button", { name: "Sync now" }).click();
  const pdfItem = await until(async () => { await phone.sync(); const i = phone.item(pdfId); return i && phone.strokes(pdfId, i.attachments[0].id).length === 1 ? i : null; }, "PDF ink on the phone", 20000);
  assert.equal(phone.strokes(pdfId, pdfItem.attachments[0].id)[0].tool, "highlighter");
  assert.equal(pdfItem.fileVersions.length, 0, "the PDF itself didn't change");

  assert.deepEqual(problems, []);
  await context.close();
});
