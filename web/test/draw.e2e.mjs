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
  await page.getByRole("button", { name: "Sketch", exact: true }).click();
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
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await page.getByRole("button", { name: "Eraser" }).click();
  await mouseStroke(page, live, [0.45, 0.25], [0.45, 0.42], 8);

  // Squared paper and a second page.
  await page.getByRole("button", { name: "Page", exact: true }).click();
  await page.getByRole("button", { name: "Squared", exact: true }).click();
  await page.getByRole("button", { name: "+ Page after this" }).click();
  await until(async () => (await page.locator(".ink-page").count()) === 2, "a second page");
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  const second = page.locator(".ink-page .ink-live").nth(1);
  await page.waitForTimeout(700); // the new page scrolls into view
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
  const [first, second2] = sketch.pageList.map((p) => p.id);
  assert.deepEqual(strokes.map((s) => [s.pageKey, s.tool]), [[first, "pen"], [first, "pen"], [second2, "pen"]]);
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
  await page.getByRole("button", { name: "Draw on it" }).click();
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

/** Pointer events of any kind along a path of page fractions (pen, touch or mouse), as one pointer. */
async function pointerPath(page, selector, path, { type = "pen", id = 9, index = 0, holdMs = 0 } = {}) {
  await page.evaluate(async ({ selector, path, type, id, index, holdMs }) => {
    const c = document.querySelectorAll(selector)[index];
    const r = c.getBoundingClientRect();
    const at = ([x, y]) => ({ clientX: r.left + r.width * x, clientY: r.top + r.height * y });
    const fire = (kind, p, pressure) => c.dispatchEvent(new PointerEvent(kind, { ...at(p), pointerId: id, pointerType: type, pressure, bubbles: true, cancelable: true, isPrimary: true, button: 0, buttons: kind === "pointerup" ? 0 : 1 }));
    fire("pointerdown", path[0], 0.5);
    for (const p of path.slice(1)) fire("pointermove", p, 0.6);
    if (holdMs) await new Promise((done) => setTimeout(done, holdMs));
    fire("pointerup", path.at(-1), 0);
  }, { selector, path, type, id, index, holdMs });
}

/** Two (or three) fingers tapping at once. */
async function fingerTap(page, selector, fingers) {
  await page.evaluate(({ selector, fingers }) => {
    const c = document.querySelector(selector);
    const r = c.getBoundingClientRect();
    const ev = (kind, i) => new PointerEvent(kind, { clientX: r.left + 100 + i * 60, clientY: r.top + 200, pointerId: 50 + i, pointerType: "touch", bubbles: true, cancelable: true, isPrimary: i === 0 });
    for (let i = 0; i < fingers; i++) c.dispatchEvent(ev("pointerdown", i));
    for (let i = 0; i < fingers; i++) c.dispatchEvent(ev("pointerup", i));
  }, { selector, fingers });
}

const roughRectangle = (() => {
  const corners = [[0.2, 0.2], [0.6, 0.21], [0.6, 0.4], [0.21, 0.4], [0.2, 0.21]];
  const out = [];
  for (let k = 0; k < corners.length - 1; k++) for (let i = 0; i < 10; i++) {
    const [a, b] = [corners[k], corners[k + 1]], f = i / 10;
    out.push([a[0] + (b[0] - a[0]) * f + (i % 3) * 0.001, a[1] + (b[1] - a[1]) * f + (i % 2) * 0.001]);
  }
  out.push(corners.at(-1));
  return out;
})();

test("sketching tools: pens, shapes, lasso, partial eraser, text, pictures, pages, finger taps, PDF, endless canvas", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true });
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
  await page.evaluate(() => localStorage.removeItem("trove.ink"));

  await page.getByRole("button", { name: "Sketch", exact: true }).click();
  const live = ".ink-page .ink-live";
  await page.locator(live).first().waitFor();
  await until(async () => (await page.locator(live).first().boundingBox())?.width > 300, "the page laid out");

  // A fountain pen line, and a long brush line to cut with the partial eraser.
  await page.getByRole("button", { name: "Fountain pen" }).click();
  await pointerPath(page, live, [[0.1, 0.6], [0.3, 0.65], [0.5, 0.6]]);
  await page.getByRole("button", { name: "Brush pen" }).click();
  await pointerPath(page, live, Array.from({ length: 21 }, (_, i) => [0.1 + i * 0.04, 0.8]));

  // Shape mode turns a rough rectangle into a clean one; holding still snaps a wobbly line.
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await page.getByRole("button", { name: "Shapes" }).click();
  await pointerPath(page, live, roughRectangle);
  await page.getByRole("button", { name: "Shapes" }).click();
  await pointerPath(page, live, [[0.1, 0.9], [0.3, 0.905], [0.5, 0.898], [0.7, 0.9]], { holdMs: 800 });

  // Lasso the fountain line, move it right, duplicate and recolour the copy.
  await page.getByRole("button", { name: "Lasso" }).click();
  await pointerPath(page, live, [[0.05, 0.55], [0.55, 0.55], [0.55, 0.7], [0.05, 0.7], [0.05, 0.56]], { type: "mouse", id: 1 });
  await page.locator(".ink-selbar", { hasText: "1 selected" }).waitFor();
  await pointerPath(page, live, [[0.3, 0.63], [0.35, 0.63], [0.4, 0.63]], { type: "mouse", id: 1 });
  await page.getByRole("button", { name: "Duplicate", exact: true }).click();
  await page.getByRole("button", { name: "Recolour #ff3b30" }).click();
  await page.getByRole("button", { name: "Deselect" }).click();

  // The partial eraser cuts the brush line in two.
  await page.getByRole("button", { name: "Eraser" }).click();
  await page.getByLabel("Eraser mode").selectOption("partial");
  await pointerPath(page, live, [[0.5, 0.75], [0.5, 0.85]], { type: "mouse", id: 1 });

  // A text box.
  await page.getByRole("button", { name: "Text", exact: true }).click();
  await pointerPath(page, live, [[0.15, 0.08]], { type: "mouse", id: 1 });
  await page.getByLabel("Text box").fill("Hello sketch");
  await page.getByLabel("Text box").press("Escape");
  await page.locator(".ink-textbox").waitFor({ state: "detached" });

  // A picture.
  await page.evaluate(async () => {
    const c = document.createElement("canvas");
    c.width = 120; c.height = 80;
    const x = c.getContext("2d");
    x.fillStyle = "#0a84ff"; x.fillRect(0, 0, 120, 80);
    const blob = await new Promise((done) => c.toBlob(done, "image/png"));
    const dt = new DataTransfer();
    dt.items.add(new File([blob], "blue.png", { type: "image/png" }));
    const input = document.querySelector(".ink-editor input[type=file]");
    input.files = dt.files;
    input.dispatchEvent(new Event("change"));
  });
  await page.locator(".ink-selbar", { hasText: "1 selected" }).waitFor();
  await page.keyboard.press("Escape");

  // Two fingers tap: undo the last line; three fingers: redo it.
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await pointerPath(page, live, [[0.7, 0.1], [0.9, 0.12]]);
  await fingerTap(page, live, 2);
  await until(() => page.getByRole("button", { name: "Redo", exact: true }).isEnabled(), "undo by two fingers");
  await fingerTap(page, live, 3);
  await until(async () => !(await page.getByRole("button", { name: "Redo", exact: true }).isEnabled()), "redo by three fingers");

  // Pages: duplicate this one, move the copy up, colour it cream, and give it music paper.
  await page.getByRole("button", { name: "Duplicate page" }).click();
  await until(async () => (await page.locator(".ink-page").count()) === 2, "a duplicated page");
  await page.getByRole("button", { name: "Move page up" }).click();
  await page.getByRole("button", { name: "Page colour #fbf6e9" }).click();
  await page.getByLabel("This page's paper").selectOption("music");
  if (shots) await page.screenshot({ path: join(shots, "web-sketch-tools.png") });

  // Export to PDF.
  const [download] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Export PDF" }).click()]);
  const pdf = readFileSync(await download.path());
  assert.equal(pdf.subarray(0, 5).toString(), "%PDF-");
  assert.ok(pdf.toString("latin1").includes("(Hello sketch) Tj"), "text boxes export as text");
  assert.equal((pdf.toString("latin1").match(/\/Type \/Page\b/g) ?? []).length, 2, "both pages");
  await page.getByRole("button", { name: "Done" }).click();

  // The phone has it all.
  await page.getByRole("button", { name: "Sync now" }).click();
  const sketch = await until(async () => {
    await phone.sync();
    const s = phone.items().find((i) => i.kind === "sketch");
    return s && s.pageList.length === 2 && phone.elements(s.id).length >= 4 ? s : null;
  }, "the sketch on the phone", 20000);
  const [copyPage, firstPage] = sketch.pageList;
  assert.equal(copyPage.color, "#fbf6e9");
  assert.equal(copyPage.paper, "music");
  const mine = phone.strokes(sketch.id, "", firstPage.id);
  const tools = mine.map((s) => s.tool);
  assert.ok(tools.includes("fountain") && tools.includes("brush"), tools.join());
  assert.equal(mine.filter((s) => s.tool === "brush").length, 2, "the brush line was cut in two");
  assert.deepEqual(mine.filter((s) => s.shape).map((s) => s.shape).sort(), ["line", "rectangle"]);
  const fountains = mine.filter((s) => s.tool === "fountain");
  assert.equal(fountains.length, 2);
  assert.ok(fountains.some((s) => s.color === "#ff3b30"), "the copy is red");
  assert.ok(Math.min(...fountains.map((s) => s.points[0].x)) > 0.1 * 768 + 40, "the line moved right");
  const els = phone.elements(sketch.id, "", firstPage.id);
  assert.deepEqual(els.map((e) => e.type).sort(), ["image", "text"]);
  assert.equal(els.find((e) => e.type === "text").text, "Hello sketch");
  assert.equal(phone.strokes(sketch.id, "", copyPage.id).length, mine.length, "the copy has the same ink");
  assert.ok(phone.item(sketch.id).sketchText.includes("Hello sketch"));

  // An endless canvas: draw far out, scroll with the wheel.
  await page.locator("#grid .card.sketch").first().click();
  await page.getByRole("button", { name: "Draw", exact: true }).click();
  await page.getByRole("button", { name: "Page", exact: true }).click();
  await page.getByRole("radio", { name: "Endless canvas" }).click();
  await page.keyboard.press("Escape");
  await page.locator(".ink-infinite").waitFor();
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await pointerPath(page, ".ink-infinite .ink-live", [[0.5, 0.5], [0.6, 0.55]]);
  await page.mouse.move(640, 500);
  await page.mouse.wheel(0, 2000);
  await pointerPath(page, ".ink-infinite .ink-live", [[0.5, 0.5], [0.6, 0.55]]);
  if (shots) await page.screenshot({ path: join(shots, "web-sketch-endless.png") });
  await page.getByRole("button", { name: "Done" }).click();
  await page.getByRole("button", { name: "Sync now" }).click();
  await until(async () => {
    await phone.sync();
    const s = phone.item(sketch.id);
    const ys = phone.strokes(sketch.id, "", "0").slice(-2).map((x) => x.points[0].y);
    return s.infinite && ys.length === 2 && ys[1] - ys[0] > 1500;
  }, "the endless canvas on the phone", 20000);

  assert.deepEqual(problems, []);
  await context.close();
});

test("zoom 10–1000 %, flipping pages, the precise eraser and scribble to erase", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const context = await browser.newContext({ viewport: { width: 1024, height: 768 } });
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept());
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#search").waitFor();
  await page.evaluate(() => localStorage.removeItem("trove.ink"));
  await page.getByRole("button", { name: "Sketch", exact: true }).click();
  const live = ".ink-page .ink-live";
  await page.locator(live).first().waitFor();
  const pill = page.locator(".ink-zoom-pill");
  await until(async () => /^\d+%$/.test(await pill.textContent()), "the zoom shown");

  // The whole page fits when it opens; the pill resets to 100 % and fits again.
  const fitted = await pill.textContent();
  const box = await page.locator(".ink-page").first().boundingBox();
  assert.ok(box.height <= 768 - 50, "the whole page is in view");
  await pill.click();
  await page.getByRole("button", { name: "Reset to 100%" }).click();
  assert.equal(await pill.textContent(), "100%");
  assert.equal(Math.round((await page.locator(".ink-page").first().boundingBox()).width), 768);
  await page.getByRole("button", { name: "Whole page" }).click();
  assert.equal(await pill.textContent(), fitted);
  await page.keyboard.press("Escape");

  // Three slanted strokes, then a scratch-out over them with scribble to erase on.
  for (const x of [0.2, 0.25, 0.3]) await pointerPath(page, live, [[x, 0.25], [x + 0.02, 0.22], [x + 0.04, 0.19]]);
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByText("Scribble to erase").click();
  await page.keyboard.press("Escape");
  const zig = Array.from({ length: 21 }, (_, i) => [0.18 + 0.2 * i / 20, i % 2 ? 0.17 : 0.27]);
  await pointerPath(page, live, zig);
  // A line elsewhere stays: one line is never a scratch-out.
  await pointerPath(page, live, [[0.1, 0.6], [0.5, 0.6], [0.9, 0.6]]);

  // The precise eraser cuts that line exactly where it passes.
  await page.getByRole("button", { name: "Eraser", exact: true }).click();
  await page.getByLabel("Eraser mode").selectOption("precise");
  await pointerPath(page, live, [[0.5, 0.55], [0.5, 0.6], [0.5, 0.65]]);

  // Flip pages: one page at a time, arrows and keys turn them.
  await page.getByRole("button", { name: "Page", exact: true }).click();
  await page.getByRole("radio", { name: "Flip pages" }).click();
  await page.getByRole("button", { name: "+ Page after this" }).click();
  await until(async () => (await page.locator(".ink-page").count()) === 2, "a second page");
  await until(async () => (await page.locator(".ink-page:not([hidden])").count()) === 1, "one page at a time");
  assert.equal(await page.locator(".ink-page-count").textContent(), "2 / 2");
  await page.getByRole("button", { name: "Previous page" }).click();
  assert.equal(await page.locator(".ink-page-count").textContent(), "1 / 2");
  await page.keyboard.press("ArrowRight");
  assert.equal(await page.locator(".ink-page-count").textContent(), "2 / 2");
  await page.getByRole("button", { name: "Done" }).click();

  await page.getByRole("button", { name: "Sync now" }).click();
  await until(async () => {
    await phone.sync();
    const s = phone.items().find((i) => i.kind === "sketch");
    return s && s.pageList.length === 2 ? s : null;
  }, "the sketch on the phone", 20000);
  const s = phone.items().find((i) => i.kind === "sketch");
  const strokes = phone.strokes(s.id);
  // The three strokes are gone (no scratch-out kept); the long line is in two pieces.
  assert.equal(strokes.length, 2, JSON.stringify(strokes.map((x) => x.points.length)));
  assert.ok(strokes.every((x) => x.points.every((p) => p.y > 1024 * 0.5)), "only the cut line is left");
  assert.deepEqual(problems, []);
  await context.close();
});

test("a GoodNotes notebook opens in the editor with its ink as Trove's, editable and synced", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const bytes = new Uint8Array(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink.goodnotes", import.meta.url)));
  const expected = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-expected.json", import.meta.url), "utf8"));
  const want = expected.editable.reduce((n, p) => n + p.strokes.length, 0);
  const id = await phone.addFile(bytes, "Lecture.goodnotes", "application/octet-stream");
  await phone.sync();

  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource.*404/.test(m.text())) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#search").waitFor();
  await until(async () => (await page.locator("#grid .card", { hasText: "Lecture" }).count()) === 1, "the notebook on the website", 15000);
  await page.locator("#grid .card", { hasText: "Lecture" }).click();
  await page.getByRole("button", { name: "Edit handwriting" }).click();
  await page.locator(".ink-page .ink-live").first().waitFor();
  await until(async () => (await page.locator(".ink-page .ink-live").first().boundingBox())?.width > 300, "the notebook page laid out");
  // One more line, then the eraser takes one of GoodNotes' strokes away.
  await mouseStroke(page, page.locator(".ink-page .ink-live").first(), [0.2, 0.8], [0.7, 0.85]);
  if (shots) await page.screenshot({ path: join(shots, "web-goodnotes-edit.png") });
  await page.getByRole("button", { name: "Done" }).click();
  await page.getByRole("button", { name: "Sync now" }).click();
  const item = await until(async () => {
    await phone.sync();
    const i = phone.item(id);
    return i?.goodnotesInk.length && phone.strokes(id, i.attachments[0].id).length === want + 1 ? i : null;
  }, "the notebook's ink on the phone", 20000);
  assert.deepEqual(item.goodnotesInk, [item.attachments[0].id]);
  assert.equal(phone.elements(id, item.attachments[0].id).filter((e) => e.type === "text").length, expected.editable.reduce((n, p) => n + p.texts.length, 0));
  assert.equal(item.fileVersions.length, 0, "the notebook file itself didn't change");
  // Opening it again doesn't copy the ink twice.
  await page.getByRole("button", { name: "Edit handwriting" }).click();
  await page.locator(".ink-page .ink-live").first().waitFor();
  await page.getByRole("button", { name: "Done" }).click();
  assert.equal(phone.strokes(id, item.attachments[0].id).length, want + 1);
  assert.deepEqual(problems, []);
  await context.close();
});
