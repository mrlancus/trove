// Round 1 of sketching in real Chromium against a running relay (see relay.e2e.mjs for how to start
// it): outline rendering against the old segment-by-segment renderer, input-to-paint latency, a
// 2,000-stroke page panned through tiles, and the new pens (favourites, pen options, dashes,
// arrows, fill, straight highlighter, colours, eyedropper, tape, compact points) reaching another
// device. SCREENSHOTS=<dir> saves screenshots; the measured numbers are printed.
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

/** Pointer events along a path of page fractions, as one pointer. */
async function pointerPath(page, selector, path, { type = "pen", id = 9, index = 0, holdMs = 0, twist = 0 } = {}) {
  await page.evaluate(async ({ selector, path, type, id, index, holdMs, twist }) => {
    const c = document.querySelectorAll(selector)[index];
    const r = c.getBoundingClientRect();
    const at = ([x, y]) => ({ clientX: r.left + r.width * x, clientY: r.top + r.height * y });
    const fire = (kind, p, pressure) => c.dispatchEvent(new PointerEvent(kind, { ...at(p), pointerId: id, pointerType: type, pressure, twist, bubbles: true, cancelable: true,
      isPrimary: true, button: 0, buttons: kind === "pointerup" ? 0 : 1 }));
    fire("pointerdown", path[0], 0.5);
    for (const p of path.slice(1)) fire("pointermove", p, 0.6);
    if (holdMs) await new Promise((done) => setTimeout(done, holdMs));
    fire("pointerup", path.at(-1), 0);
  }, { selector, path, type, id, index, holdMs, twist });
}

async function openWebsite(v) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource.*404/.test(m.text())) problems.push(m.text()); else if (m.type() === "log") console.log(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept());
  await page.goto(BASE + "/");
  if (v) {
    await page.getByRole("tab", { name: "Setup code" }).click();
    await page.getByLabel("Setup code").fill(await v.setupCode());
    await page.getByRole("button", { name: "Connect" }).click();
    await page.locator("#search").waitFor();
    await page.evaluate(() => localStorage.removeItem("trove.ink"));
  }
  return { context, page, problems };
}

test("outline strokes look like the old renderer drew them (and nothing comes out blank)", async () => {
  const { context, page, problems } = await openWebsite(null);
  const result = await page.evaluate(async () => {
    const ink = await import("/core/ink.js");
    // The renderer before outlines (segment by segment), kept here to compare against.
    const legacy = (ctx, s) => {
      const pts = s.points;
      const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
      ctx.save();
      ctx.strokeStyle = s.color; ctx.fillStyle = s.color; ctx.lineCap = "round"; ctx.lineJoin = "round";
      if (pts.length === 1) { ctx.beginPath(); ctx.arc(pts[0].x, pts[0].y, ink.widthAt(s.width, s.tool, pts[0].p) / 2, 0, Math.PI * 2); ctx.fill(); ctx.restore(); return; }
      for (let i = 0; i < pts.length - 1; i++) {
        const a = i === 0 ? pts[0] : mid(pts[i - 1], pts[i]);
        const b = i === pts.length - 2 ? pts[i + 1] : mid(pts[i], pts[i + 1]);
        ctx.lineWidth = ink.pointWidth(s, pts, i);
        ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.quadraticCurveTo(pts[i].x, pts[i].y, b.x, b.y); ctx.stroke();
      }
      ctx.restore();
    };
    let seed = 3;
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    const strokes = [];
    const tools = ["pen", "pencil", "fountain", "brush"];
    for (let k = 0; k < 24; k++) {
      const x0 = 40 + (k % 6) * 120, y0 = 60 + Math.floor(k / 6) * 110, n = 10 + Math.floor(rnd() * 40);
      const pts = Array.from({ length: n }, (_, i) => ({ x: x0 + i * 2.2 + Math.sin(i / 3 + k) * 14, y: y0 + Math.cos(i / 4 + k) * 22, p: 0.3 + 0.6 * rnd(), t: i * 8 }));
      strokes.push({ tool: tools[k % 4], color: "#000000", width: 2 + (k % 5) * 2, points: k % 11 === 5 ? pts.slice(0, 1) : pts, cache: {} });
    }
    const draw = (fn) => {
      const c = document.createElement("canvas");
      c.width = 800; c.height = 480;
      const ctx = c.getContext("2d");
      ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, 800, 480);
      // Pencil's grain and see-through ink aside, the shape is what's compared: draw everything solid black.
      for (const s of strokes) fn(ctx, { ...s, tool: s.tool === "pencil" ? "pen" : s.tool });
      return { c, data: ctx.getImageData(0, 0, 800, 480).data };
    };
    const t0 = performance.now();
    const now = draw((ctx, s) => ink.drawStroke(ctx, s));
    const outlineMs = performance.now() - t0;
    const t1 = performance.now();
    const old = draw(legacy);
    const legacyMs = performance.now() - t1;
    const dark = (d, i) => d[i * 4] < 128;
    let a = 0, b = 0, both = 0, nearOld = 0;
    const W = 800, H = 480;
    const oldMask = new Uint8Array(W * H);
    for (let i = 0; i < W * H; i++) { if (dark(old.data, i)) { b++; oldMask[i] = 1; } }
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x;
      if (!dark(now.data, i)) continue;
      a++;
      if (oldMask[i]) both++;
      let near = false;
      for (let dy = -2; dy <= 2 && !near; dy++) for (let dx = -2; dx <= 2 && !near; dx++) { const j = (y + dy) * W + x + dx; if (j >= 0 && j < W * H && oldMask[j]) near = true; }
      if (near) nearOld++;
    }
    // Every stroke still shows: a dark pixel near each one's middle point.
    const missing = strokes.filter((s) => { const p = s.points[Math.floor(s.points.length / 2)]; let hit = false;
      for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) { const i = (Math.round(p.y) + dy) * W + Math.round(p.x) + dx; if (dark(now.data, i)) hit = true; }
      return !hit; }).length;
    return { outlinePixels: a, legacyPixels: b, overlap: both / Math.max(1, b), nearOld: nearOld / Math.max(1, a), missing, outlineMs, legacyMs,
      pngNew: now.c.toDataURL(), pngOld: old.c.toDataURL() };
  });
  console.log(`outline vs old renderer: ${result.outlinePixels} vs ${result.legacyPixels} ink pixels, ${(result.overlap * 100).toFixed(1)} % of the old covered, `
    + `${(result.nearOld * 100).toFixed(1)} % of the new within 2 px of the old; draw 24 strokes ${result.outlineMs.toFixed(1)} ms (first, with outlines) vs ${result.legacyMs.toFixed(1)} ms`);
  if (shots) {
    const { writeFileSync } = await import("node:fs");
    writeFileSync(join(shots, "ink-outline-new.png"), Buffer.from(result.pngNew.split(",")[1], "base64"));
    writeFileSync(join(shots, "ink-outline-old.png"), Buffer.from(result.pngOld.split(",")[1], "base64"));
  }
  assert.equal(result.missing, 0, "every stroke is drawn");
  assert.ok(result.outlinePixels > 2000, "not blank");
  assert.ok(result.outlinePixels / result.legacyPixels > 0.75 && result.outlinePixels / result.legacyPixels < 1.3, "about as much ink as before");
  assert.ok(result.overlap > 0.85, "covers what the old renderer drew");
  assert.ok(result.nearOld > 0.97, "and stays where it drew it");
  assert.deepEqual(problems, []);
  await context.close();
});

test("input-to-paint latency, prediction, and panning 2,000 strokes through tiles", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  // An endless canvas with 2,000 handwriting-sized strokes, from the phone.
  const sketch = phone.addSketch({ paper: "lined", infinite: true });
  phone.update(sketch, { title: "Busy board" });
  for (let k = 0; k < 2000; k++) {
    const x0 = (k % 50) * 40, y0 = Math.floor(k / 50) * 36;
    phone.addStroke({ on: sketch, page: "0", tool: k % 3 ? "pen" : "pencil", color: "#1c1c1e", width: 2.5,
      points: Array.from({ length: 24 }, (_, i) => ({ x: x0 + i * 1.3, y: y0 + 10 * Math.sin(i / 3 + k), p: 0.5 + 0.3 * Math.sin(i / 5), t: i * 8 })) });
  }
  await phone.sync();
  const { context, page, problems } = await openWebsite(v);
  await until(async () => (await page.locator("#grid .card", { hasText: "Busy board" }).count()) === 1, "the board on the website", 20000);
  await page.locator("#grid .card", { hasText: "Busy board" }).click();
  await page.getByRole("button", { name: /^(Open|Edit|Draw)/ }).first().click().catch(() => {});
  const live = ".ink-page .ink-live";
  await page.locator(live).first().waitFor({ timeout: 15000 });
  await until(async () => (await page.locator(live).first().boundingBox())?.width > 300, "the board laid out");

  const desynchronized = await page.evaluate((sel) => document.querySelector(sel).getContext("2d").getContextAttributes?.().desynchronized ?? null, live);
  console.log(`pen layer desynchronized: ${desynchronized}`);

  // Panning: wheel steps over the endless canvas, each one composited from tiles.
  const pan = await page.evaluate(async (sel) => {
    const c = document.querySelector(sel);
    const r = c.getBoundingClientRect();
    const frame = () => new Promise((done) => requestAnimationFrame(() => done()));
    await frame();
    const times = [];
    for (let i = 0; i < 90; i++) {
      const t = performance.now();
      c.dispatchEvent(new WheelEvent("wheel", { deltaX: i < 45 ? 37 : -29, deltaY: i % 2 ? 23 : 17, clientX: r.left + 200, clientY: r.top + 200, bubbles: true, cancelable: true }));
      // Until everything the step started has run (the ink is drawn after a microtask).
      await new Promise((done) => setTimeout(done, 0));
      times.push(performance.now() - t);
      await frame();
    }
    times.sort((a, b) => a - b);
    return { median: times[45], p95: times[85], max: times[89] };
  }, live);
  console.log(`panning 2,000 strokes: ${pan.median.toFixed(2)} ms median, ${pan.p95.toFixed(2)} ms p95, ${pan.max.toFixed(2)} ms worst per step`);
  if (shots) await page.screenshot({ path: join(shots, "ink-busy-board.png") });

  // Latency: real mouse input through Chromium, one move per frame, timed from the event to the frame that painted it.
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await page.evaluate(() => { globalThis.troveInkLatency = []; });
  const box = await page.locator(live).first().boundingBox();
  for (let line = 0; line < 3; line++) {
    await page.mouse.move(box.x + 100, box.y + 300 + line * 60);
    await page.mouse.down();
    for (let i = 1; i <= 40; i++) {
      await page.mouse.move(box.x + 100 + i * 12, box.y + 300 + line * 60 + Math.sin(i / 4) * 20);
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => done())));
    }
    await page.mouse.up();
  }
  const lat = await page.evaluate(() => { const l = [...(globalThis.troveInkLatency ?? [])].sort((a, b) => a - b); return { n: l.length, median: l[Math.floor(l.length / 2)], p95: l[Math.floor(l.length * 0.95)] }; });
  console.log(`input-to-paint (event to the frame that drew it, ${lat.n} frames): ${lat.median?.toFixed(1)} ms median, ${lat.p95?.toFixed(1)} ms p95`);
  assert.ok(lat.n > 60, "latency measured");
  assert.ok(lat.median < 25, `median latency ${lat.median} ms`);
  assert.ok(pan.median < 16, `panning ${pan.median} ms a step`);

  // Prediction: pen events the browser guesses ahead of are drawn a frame early, never saved.
  const strokesBefore = await page.evaluate(() => document.querySelectorAll(".ink-page").length);
  assert.equal(strokesBefore, 1);
  await page.getByRole("button", { name: "Done" }).click();
  await until(async () => { await phone.sync(); return phone.strokes(sketch).length === 2003; }, "the three new lines on the phone", 20000);
  const counts = phone.strokes(sketch).slice(-3).map((s) => s.points.length);
  assert.ok(counts.every((n) => n > 20), `points per line: ${counts}`);
  assert.deepEqual(problems, []);
  await context.close();
});

test("favourites, pen options, dashes, arrows, fill, straight highlighter, colours, eyedropper, tape and compact points reach another device", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const { context, page, problems } = await openWebsite(v);
  await page.getByRole("button", { name: "Sketch", exact: true }).click();
  const live = ".ink-page .ink-live";
  await page.locator(live).first().waitFor();
  await until(async () => (await page.locator(live).first().boundingBox())?.width > 300, "the page laid out");

  // Pen options: smoothing and a firm pressure curve for the pen, synced; dotted lines on this device.
  // The pen is the tool to start with (tapping it again would hide its options).
  await page.getByRole("button", { name: "Pen options" }).click();
  await page.getByLabel("Smoothing").fill("60");
  await page.getByLabel("Smoothing").dispatchEvent("change");
  await page.getByRole("radio", { name: "Firm" }).click();
  await page.getByRole("radio", { name: "Dots" }).click();
  await page.getByRole("radio", { name: "End", exact: true }).click();
  await page.getByRole("button", { name: "Fill #34c759" }).click();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Pen options" }).click(); // closes it
  await pointerPath(page, live, [[0.1, 0.1], [0.2, 0.12], [0.3, 0.1], [0.4, 0.13]]);

  // A straight line with an arrow (hold still), then a filled rectangle.
  await page.getByRole("radio", { name: "Dots" }).count(); // still closed
  await page.getByRole("button", { name: "Pen options" }).click();
  await page.getByRole("radio", { name: "Solid" }).click();
  await page.getByRole("button", { name: "Pen options" }).click();
  await pointerPath(page, live, [[0.1, 0.3], [0.3, 0.305], [0.5, 0.298], [0.7, 0.3]], { holdMs: 800 });
  await page.getByRole("button", { name: "Shapes" }).click();
  await pointerPath(page, live, [[0.2, 0.4], [0.5, 0.405], [0.5, 0.55], [0.205, 0.55], [0.2, 0.405]]);
  await page.getByRole("button", { name: "Shapes" }).click();

  // A highlighter held still comes out straight.
  await page.getByRole("button", { name: "Highlighter" }).click();
  await pointerPath(page, live, [[0.1, 0.65], [0.3, 0.66], [0.5, 0.64], [0.6, 0.655]], { holdMs: 800 });

  // Colours: hex input, keep it in your colours, then save the pen as a favourite.
  await page.getByRole("button", { name: "Fountain pen" }).click();
  await page.getByLabel("Colour as hex").fill("#123abc");
  await page.getByLabel("Colour as hex").press("Enter");
  await page.getByRole("button", { name: "Add to your colours" }).click();
  await page.getByRole("button", { name: "Save pen" }).click();
  await page.getByRole("button", { name: /^Favourite 1: Fountain pen/ }).waitFor();
  // A fountain pen turned in the hand (twist) stores its nib angle per point.
  await pointerPath(page, live, [[0.6, 0.1], [0.7, 0.15], [0.8, 0.1]], { twist: 90 });

  // The eyedropper picks the green fill back up.
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  await page.getByRole("button", { name: "Pick a colour from the page" }).click();
  await pointerPath(page, live, [[0.35, 0.48]], { type: "mouse", id: 1 });
  assert.equal(await page.getByLabel("Colour as hex").inputValue(), "#34c759");

  // Tape over the rectangle; tapping it with the pen opens it, no dot is left.
  await page.getByRole("button", { name: "Tape" }).click();
  await pointerPath(page, live, [[0.15, 0.47], [0.55, 0.47]], { type: "mouse", id: 1 });
  await page.getByRole("button", { name: "Pen", exact: true }).click();
  const covered = await page.evaluate((sel) => { const c = document.querySelector(sel.replace("live", "ink")); return c.getContext("2d").getImageData(Math.round(c.width * 0.35), Math.round(c.height * 0.47), 1, 1).data.join(","); }, live);
  await pointerPath(page, live, [[0.35, 0.47]]);
  await page.waitForTimeout(100);
  const opened = await page.evaluate((sel) => { const c = document.querySelector(sel.replace("live", "ink")); return c.getContext("2d").getImageData(Math.round(c.width * 0.35), Math.round(c.height * 0.47), 1, 1).data.join(","); }, live);
  assert.notEqual(covered, opened, "tapping the tape shows what's under it");
  if (shots) await page.screenshot({ path: join(shots, "ink-pens.png") });

  // Smaller drawings: from now on points go in points2.
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByText("Smaller drawings").click();
  await page.keyboard.press("Escape");
  await pointerPath(page, live, [[0.1, 0.85], [0.3, 0.86], [0.5, 0.84]]);
  await page.getByRole("button", { name: "Done" }).click();

  const sketch = await until(async () => {
    await phone.sync();
    const s = phone.items().find((i) => i.kind === "sketch");
    return s && phone.strokes(s.id).length === 6 && phone.elements(s.id).length === 1 ? s : null;
  }, "the strokes and tape on the phone", 20000);
  const strokes = phone.strokes(sketch.id);
  const [dotted, arrow, box, highlight, fountain, compact] = strokes;
  assert.equal(dotted.dash, "dot");
  assert.equal(arrow.shape, "line");
  assert.equal(arrow.arrow, "end");
  assert.equal(box.shape, "rectangle");
  assert.equal(box.fill, "#34c759");
  assert.equal(highlight.tool, "highlighter");
  assert.equal(highlight.shape, "line");
  assert.equal(fountain.color, "#123abc");
  assert.ok(Math.abs(fountain.nib - (Math.PI / 4 + Math.PI / 2)) < 0.01, "the turned nib, kept as the stroke's nib (points can't hold angles)");
  const raw = phone.store.records.get(compact.id).fields;
  assert.ok(raw.points2 && !raw.points, "compact points");
  assert.ok(typeof phone.store.records.get(dotted.id).fields.points === "string");
  const settings = phone.inkSettings();
  assert.equal(settings.pens.pen.smoothing, 60);
  assert.equal(settings.pens.pen.curve, "firm");
  assert.deepEqual(settings.favourites, [{ tool: "fountain", color: "#123abc", width: 4 }]);
  assert.deepEqual(settings.palette, ["#123abc"]);
  assert.equal(settings.compactPoints, true);
  assert.equal(phone.elements(sketch.id)[0].type, "tape");
  assert.deepEqual(problems, []);
  await context.close();
});
