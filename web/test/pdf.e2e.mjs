// The website's PDF viewer in real Chromium against a running relay (see relay.e2e.mjs for how to start
// it): find, highlighting selected text, a quote, links, filling the form, the text for search and the
// export as real annotations (ROADMAP S5, PROTOCOL.md §10 "PDF text, highlights and forms").
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { chromium } from "playwright-core";
import { Vault } from "../public/core/vault.js";
import { BASE, createVault, memoryStorage } from "./helpers.mjs";
import { formPdf } from "./make-pdf.mjs";

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

const until = async (check, what, ms = 20_000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await check(); if (v) return v; await new Promise((r) => setTimeout(r, 300)); }
  throw new Error(`timed out: ${what}`);
};

/** Selects `text` inside the PDF's text layer and lets the viewer see it (as a mouse drag would). */
async function selectText(page, text) {
  await page.evaluate((text) => {
    const span = [...document.querySelectorAll(".textLayer span")].find((s) => s.textContent.includes(text));
    const node = span.firstChild, at = node.textContent.indexOf(text);
    const range = document.createRange();
    range.setStart(node, at);
    range.setEnd(node, at + text.length);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    span.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
  }, text);
}

test("PDF: find, highlight, quote, links, the form, text for search and export", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  await phone.sync();

  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: "block", acceptDownloads: true });
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(e.message));
  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.locator("#device-name").fill("Chrome PDF test");
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#search").waitFor();

  // Added on the website: its text is read for search straight away (no Apple device needed).
  await page.locator("#upload").setInputFiles({ name: "Form.pdf", mimeType: "application/pdf", buffer: Buffer.from(formPdf()) });
  const item = await until(async () => { await phone.sync(); return phone.items().find((i) => i.kind === "pdf" && i.ocrText); }, "the PDF's text on the phone");
  assert.match(item.ocrText, /^Trove test document\nThe quick brown fox jumps over the lazy dog\./);
  assert.match(item.ocrText, /\n\nPage two\n/);

  await page.getByRole("button", { name: "Show them" }).click();
  await page.locator(".card", { hasText: "Form" }).click();
  await page.locator(".pdf-page .textLayer span").first().waitFor();

  // Find marks every hit (two pages) and steps through them.
  await page.getByRole("button", { name: "Find in PDF" }).click();
  await page.getByRole("searchbox", { name: "Find in PDF" }).fill("quick brown");
  await until(async () => (await page.locator(".pdf-find-count").textContent()) === "1 of 2", "find counts both pages");
  await page.getByRole("searchbox", { name: "Find in PDF" }).press("Enter");
  assert.equal(await page.locator(".pdf-find-count").textContent(), "2 of 2");
  await page.getByRole("button", { name: "Close find" }).click();
  assert.equal(await page.locator(".pdf-hit").count(), 0);

  // Highlighting selected text keeps the words; Quote makes a quote item linked to the PDF.
  await page.locator(".pdf-page").first().scrollIntoViewIfNeeded();
  await selectText(page, "quick brown fox");
  await page.getByRole("button", { name: "Highlight in green" }).click();
  await page.locator(".pdf-hl").first().waitFor();
  await selectText(page, "five dozen");
  await page.locator(".pdf-selbar").getByRole("button", { name: "Quote" }).click();
  const att = item.attachments[0].id;
  const marks = await until(async () => {
    await phone.sync();
    const hl = phone.elements(item.id, att).filter((e) => e.type === "highlight");
    const quote = phone.items().find((i) => i.kind === "highlight");
    return hl.length === 2 && quote ? { hl, quote } : null;
  }, "the highlights and the quote on the phone");
  assert.deepEqual(marks.hl.map((e) => [e.quote, e.color]).sort(), [["five dozen", "#34c759"], ["quick brown fox", "#34c759"]]);
  assert.ok(marks.hl.every((e) => e.pageKey === "0" && e.w > 20 && e.h > 5 && e.y > 50 && e.y < 140), "highlights sit on the text lines");
  assert.equal(marks.quote.body, "> five dozen\n\n— Form (p. 1)");
  assert.deepEqual(marks.quote.links, [item.id]);
  assert.match(phone.item(item.id).sketchText, /quick brown fox/);

  // Links: the web link opens outside; the page link scrolls to page 2.
  assert.equal(await page.locator(".pdf-link[href='https://example.com/trove']").getAttribute("target"), "_blank");

  // The form: values saved as elements (the file never changes) and shown again after a reload.
  await page.locator(".pdf-field[data-field='name']").fill("Ada Lovelace");
  await page.locator(".pdf-field[data-field='name']").press("Tab");
  await page.locator(".pdf-field[data-field='agree']").check();
  await page.locator(".pdf-field[data-field='colour'][data-value='Blue']").check();
  await page.locator(".pdf-field[data-field='size']").selectOption("Medium");
  const fields = await until(async () => {
    await phone.sync();
    const f = phone.pdfFields(item.id, att);
    return f.size === 4 ? f : null;
  }, "the form values on the phone");
  assert.deepEqual(Object.fromEntries([...fields].map(([k, e]) => [k, e.value])), { name: "Ada Lovelace", agree: true, colour: "Blue", size: "Medium" });
  assert.equal(phone.item(item.id).fileVersions.length, 0, "the PDF itself didn't change");

  // Export as real annotations: a download, and a new version of the file.
  await page.getByRole("button", { name: "Export" }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("menuitem", { name: "Download with annotations" }).click();
  const file = await (await download).path();
  const bytes = readFileSync(file);
  assert.ok(bytes.length > formPdf().length, "the original plus an incremental update");
  const tail = bytes.subarray(formPdf().length).toString("latin1");
  assert.match(tail, /\/Subtype\s*\/Highlight/);
  assert.match(tail, /Ada Lovelace/);
  await page.getByRole("button", { name: "Export" }).click();
  await page.getByRole("menuitem", { name: "Save as a new version" }).click();
  await until(async () => { await phone.sync(); return phone.item(item.id).fileVersions.length === 1; }, "the annotated version on the phone");

  assert.deepEqual(problems, []);
  await context.close();
});
