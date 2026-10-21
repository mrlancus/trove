// The sketch editor's editing tools in real Chromium against a running relay (ROADMAP S3; see
// relay.e2e.mjs for how to start it): the shape picker, connectors that follow a moved shape, a
// line bent by its middle handle, the lasso's turn/front/group/copy-as-image, lasso by type, text
// boxes with a font and bold, the ruler, and the elements library, all reaching a second device.
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

test("editing: shapes, connectors, handles, lasso actions, text styles, the ruler and the elements library", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE }).catch(() => {});
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

  await page.getByRole("button", { name: "Sketch", exact: true }).click();
  const live = page.locator(".ink-page .ink-live").first();
  await live.waitFor();
  await until(async () => (await live.boundingBox())?.width > 300, "the page laid out");
  // Fit the whole page so every point used below is on screen.
  const box = await live.boundingBox();
  const k = box.width / 768;
  /** Page points → screen. */
  const at = (x, y) => [box.x + x * k, box.y + y * k];
  async function drag(from, to, steps = 10) {
    const [x0, y0] = at(...from), [x1, y1] = at(...to);
    await page.mouse.move(x0, y0);
    await page.mouse.down();
    for (let i = 1; i <= steps; i++) await page.mouse.move(x0 + ((x1 - x0) * i) / steps, y0 + ((y1 - y0) * i) / steps);
    await page.mouse.up();
  }
  async function click(x, y) { const [cx, cy] = at(x, y); await page.mouse.click(cx, cy); }

  // Circle-to-select is gone from the settings.
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  assert.equal(await page.getByText("Circle to select").count(), 0);
  await page.keyboard.press("Escape");

  // The shape picker: a rectangle, an ellipse, a connector between them, a star and a line.
  await page.getByRole("button", { name: "Shape", exact: true }).click();
  await page.getByRole("radio", { name: "Rectangle" }).click();
  await drag([100, 100], [260, 200]);
  await page.getByRole("radio", { name: "Ellipse" }).click();
  await drag([460, 100], [620, 200]);
  await page.getByRole("radio", { name: "Connector" }).click();
  await drag([180, 150], [540, 150]);
  await page.getByRole("radio", { name: "Star" }).click();
  await drag([100, 300], [200, 400]);
  await page.getByRole("radio", { name: "Line" }).click();
  await drag([300, 320], [500, 320]);

  // The lasso: tap the line and drag its middle handle down, which bends it into a curve.
  await page.getByRole("button", { name: "Lasso", exact: true }).click();
  await click(350, 320);
  await until(() => page.locator(".ink-selbar").isVisible(), "the selection bar");
  assert.equal(await page.locator(".ink-selcount").textContent(), "1 selected");
  await drag([400, 320], [400, 380]);

  // Tap the rectangle's edge and move it down: the connector follows.
  await click(100, 150);
  assert.equal(await page.locator(".ink-selcount").textContent(), "1 selected");
  await drag([180, 140], [180, 440]);
  // Turn it a quarter and bring it to the front; the AI actions stay hidden while cloud AI is off.
  await page.getByRole("button", { name: "Turn a quarter right" }).click();
  await page.getByRole("button", { name: "Bring to front" }).click();
  assert.equal(await page.locator(".ink-hook-action").isVisible(), false);
  // With cloud AI on, Ask AI offers its picture actions, and Convert to text shows.
  await page.evaluate(() => document.documentElement.classList.add("ai-on"));
  assert.equal(await page.getByRole("button", { name: "Convert to text" }).isVisible(), true);
  await page.getByRole("button", { name: "Ask AI" }).click();
  for (const name of ["Summarise", "Explain", "Make flashcards"]) assert.equal(await page.getByRole("menuitem", { name }).isVisible(), true, name);
  await page.keyboard.press("Escape");
  await page.evaluate(() => document.documentElement.classList.remove("ai-on"));
  // Copy as image (to the clipboard, or downloaded where that's not allowed).
  await page.getByRole("button", { name: "Copy as image" }).click();
  await until(() => page.evaluate(() => Number(document.querySelector(".ink-editor").dataset.copiedImage || 0) > 100), "a PNG of the selection");

  // A text box, in a serif font and bold.
  await page.getByRole("button", { name: "Text", exact: true }).click();
  await page.locator(".ink-editor").getByLabel("Font").selectOption("serif");
  await click(300, 600);
  const area = page.getByLabel("Text box");
  await area.waitFor();
  await area.type("Hello");
  await page.getByRole("button", { name: "Bold" }).click();
  await area.press("Escape");
  await until(async () => (await page.getByLabel("Text box").count()) === 0, "the text box to close");

  // Lasso by type: only text, so a loop round everything picks the one text box.
  await page.getByRole("button", { name: "Lasso", exact: true }).click();
  await page.getByRole("radio", { name: "Text" }).click();
  const loop = [[40, 40], [740, 40], [740, 760], [40, 760], [40, 50]];
  {
    const [x0, y0] = at(...loop[0]);
    await page.mouse.move(x0, y0);
    await page.mouse.down();
    for (const p of loop.slice(1)) { const [x, y] = at(...p); await page.mouse.move(x, y, { steps: 6 }); }
    await page.mouse.up();
  }
  assert.equal(await page.locator(".ink-selcount").textContent(), "1 selected");
  await page.keyboard.press("Escape");

  // Everything: group it, then save it as an element in the library, and put a copy on the page.
  await page.getByRole("radio", { name: "Everything" }).click();
  await page.keyboard.press("Control+a");
  await page.getByRole("button", { name: "Group", exact: true }).click();
  await until(async () => (await page.getByRole("button", { name: "Ungroup" }).count()) === 1, "the selection grouped");
  await page.getByRole("button", { name: "Save as element" }).click();
  const pop = page.locator(".ink-elements-pop");
  await pop.getByLabel("Name").fill("Diagram");
  await pop.getByLabel("Folder", { exact: true }).fill("Mine");
  await pop.getByRole("button", { name: "Save", exact: true }).click();
  await until(async () => (await page.getByRole("button", { name: "Diagram", exact: true }).count()) === 1, "the element in the library");
  await page.keyboard.press("Escape");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Elements", exact: true }).click();
  await page.getByRole("button", { name: "Checkbox", exact: true }).click();
  await until(() => page.locator(".ink-selbar").isVisible(), "the placed element selected");
  await page.keyboard.press("Escape");

  // The ruler: a line drawn along its top edge stays on it.
  await page.getByRole("button", { name: "Ruler", exact: true }).click();
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  const mid = await page.evaluate(() => {
    const sr = document.querySelector(".ink-scroller").getBoundingClientRect(), er = document.querySelector(".ink-page").getBoundingClientRect();
    const cx = Math.max(er.left, Math.min(er.right, sr.left + sr.width / 2)), cy = Math.max(er.top, Math.min(er.bottom, sr.top + sr.height / 2));
    return { x: ((cx - er.left) / er.width) * 768, y: ((cy - er.top) / er.height) * 1024 };
  });
  const a = -Math.PI / 12, c = Math.cos(a), s = Math.sin(a);
  const onEdge = (u, wobble) => [mid.x + u * c - (-32 + wobble) * s, mid.y + u * s + (-32 + wobble) * c];
  {
    const [x0, y0] = at(...onEdge(-150, 0));
    await page.mouse.move(x0, y0);
    await page.mouse.down();
    for (let i = 1; i <= 15; i++) { const [x, y] = at(...onEdge(-150 + i * 20, (i % 3) - 1)); await page.mouse.move(x, y); }
    await page.mouse.up();
  }
  if (shots) await page.screenshot({ path: join(shots, "web-editing.png") });
  await page.getByRole("button", { name: "Ruler", exact: true }).click();
  await page.getByRole("button", { name: "Done" }).click();
  await until(async () => (await page.locator(".ink-editor").count()) === 0, "the editor to close");

  // The phone sees it all.
  await page.getByRole("button", { name: "Sync now" }).click();
  const sketch = await until(async () => {
    await phone.sync();
    const it = phone.items().find((i) => i.kind === "sketch");
    return it && phone.stickers().some((x) => x.name === "Diagram") && phone.strokes(it.id).some((x) => x.tool === "pen" && !x.shape) ? it : null;
  }, "the edits on the phone", 20000);
  const strokes = phone.strokes(sketch.id), elements = phone.elements(sketch.id);
  const rect = strokes.find((x) => x.shape === "rectangle"), ellipse = strokes.find((x) => x.shape === "ellipse");
  const connector = strokes.find((x) => x.from && x.to);
  assert.ok(rect && ellipse && connector, "rectangle, ellipse and connector");
  assert.equal(connector.from, rect.id);
  assert.equal(connector.to, ellipse.id);
  // The rectangle moved down (and turned), and the connector's start came with it.
  const rb = phone.inkBox(rect.id);
  assert.ok(rb.y > 250, `the rectangle moved down (${JSON.stringify(rb)})`);
  assert.ok(connector.points[0].y > 250, "the connector followed");
  assert.ok(strokes.some((x) => x.shape === "curve"), "the line was bent into a curve");
  assert.ok(strokes.some((x) => x.shape === "star"), "a star");
  // Brought to front: drawn after the shapes made after it.
  const order = strokes.map((x) => x.id);
  assert.ok(order.indexOf(rect.id) > order.indexOf(ellipse.id), "the rectangle is in front");
  const text = elements.find((e) => e.type === "text");
  assert.equal(text.text, "Hello");
  assert.equal(text.font, "serif");
  assert.equal(text.bold, true);
  // Grouped: the original shapes and text share one group.
  assert.equal(new Set([rect.group, ellipse.group, connector.group, text.group]).size, 1);
  assert.ok(rect.group);
  // The library element: the selection's strokes and the text box.
  const saved = phone.stickers().find((x) => x.name === "Diagram");
  assert.equal(saved.folder, "Mine");
  assert.ok(saved.strokes.length >= 5 && saved.elements.length === 1);
  // The placed checkbox: a rectangle in a group of its own.
  const boxes = strokes.filter((x) => x.shape === "rectangle");
  assert.equal(boxes.length, 2);
  // The ruler line: every point on one straight line.
  const ruled = strokes.find((x) => x.tool === "pen" && !x.shape);
  const p0 = ruled.points[0], p1 = ruled.points.at(-1);
  const len = Math.hypot(p1.x - p0.x, p1.y - p0.y);
  assert.ok(len > 200, "the ruled line is long");
  for (const p of ruled.points) assert.ok(Math.abs((p1.x - p0.x) * (p.y - p0.y) - (p1.y - p0.y) * (p.x - p0.x)) / len < 0.5, "on the ruler's edge");
  assert.ok(Math.abs(Math.atan2(p1.y - p0.y, p1.x - p0.x) - a) < 0.01, "at the ruler's angle");
  assert.deepEqual(problems, []);
  await context.close();
});
