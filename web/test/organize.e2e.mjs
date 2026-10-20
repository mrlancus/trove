// Folders, file previews, versions and connections in real Chromium against a running relay
// (see relay.e2e.mjs for how to start it). SCREENSHOTS=<dir> saves screenshots.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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
const fixture = (name) => new URL(`./fixtures/files/${name}`, import.meta.url).pathname;
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

test("imports are filed into folders; files preview, edit into versions, and connect", async () => {
  const v = await createVault();
  const phone = await Vault.join(memoryStorage(), await v.setupCode(), { origin: BASE, deviceName: "iPhone" });
  const context = await browser.newContext({ viewport: { width: 1360, height: 900 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource.*404/.test(m.text())) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(e.message));
  page.on("dialog", (d) => d.accept(d.type() === "prompt" ? "Projects" : undefined));

  await page.goto(BASE + "/");
  await page.getByRole("tab", { name: "Setup code" }).click();
  await page.getByLabel("Setup code").fill(await v.setupCode());
  await page.getByRole("button", { name: "Connect" }).click();
  await page.locator("#search").waitFor();

  // A dropped folder keeps its structure; loose files are filed by type.
  const dir = mkdtempSync(join(tmpdir(), "trove-"));
  mkdirSync(join(dir, "Uni", "Maths"), { recursive: true });
  writeFileSync(join(dir, "Uni", "Maths", "Week 1.md"), "# Week 1\n\nLimits and [[sample]] #maths\n");
  writeFileSync(join(dir, "Uni", "reading.txt"), "Chapter 3");
  await page.getByRole("link", { name: "Import" }).click();
  await page.locator("#import-folder").setInputFiles(join(dir, "Uni"));
  await page.locator(".dz-done").waitFor({ timeout: 20000 });
  await page.getByRole("button", { name: "Import more" }).click();
  await page.locator("#import-files").setInputFiles(["sample.pdf", "sample.docx", "sample.xlsx", "Lecture.goodnotes"].map(fixture));
  await page.locator(".dz-done").waitFor({ timeout: 20000 });

  const folderNames = async () => page.locator("#folder-list .folder-name").allTextContents();
  await until(async () => { const n = await folderNames(); return ["Documents", "Handwritten", "Uni"].every((x) => n.includes(x)); }, "folders in the sidebar");

  // Folder page: breadcrumb, subfolder tile, cards with thumbnails.
  await page.locator("#folder-list .folder-row", { hasText: "Documents" }).click();
  await page.locator(".folder-tile", { hasText: "Spreadsheets" }).waitFor();
  await until(async () => (await page.locator("#grid .card").count()) === 2, "two documents");
  await page.locator(".card.pdf .thumb-wrap.loaded img").waitFor({ timeout: 15000 });
  if (shots) await page.screenshot({ path: join(shots, "web-folders.png") });

  // PDF viewer.
  await page.locator(".card.pdf").click();
  await page.locator(".pdf-page canvas").first().waitFor({ timeout: 15000 });
  assert.equal(await page.locator(".pdf-page").count(), 2);
  if (shots) await page.screenshot({ path: join(shots, "web-pdf.png") });

  // Word document.
  await page.locator(".card", { hasText: "sample" }).filter({ hasNot: page.locator(".thumb-wrap.loaded") }).first().click();
  await until(async () => (await page.locator(".doc-page h1").count()) > 0 || (await page.locator("canvas").count()) > 0, "a preview");

  // GoodNotes: the document inside renders.
  await page.locator("#folder-list .folder-row", { hasText: "Handwritten" }).click();
  await page.locator(".card", { hasText: "Lecture" }).click();
  await page.locator(".goodnotes .pdf-page canvas").first().waitFor({ timeout: 15000 });
  if (shots) await page.screenshot({ path: join(shots, "web-goodnotes.png") });

  // Spreadsheet table.
  await page.locator("#folder-list .folder-row", { hasText: "Documents" }).click();
  await page.locator(".folder-tile", { hasText: "Spreadsheets" }).click();
  await page.locator(".card", { hasText: "sample" }).click();
  await page.locator("table.sheet td", { hasText: "Café" }).waitFor();

  // A text file edited in place becomes a new version.
  await page.locator("#upload").setInputFiles({ name: "todo.csv", mimeType: "text/csv", buffer: Buffer.from("item\nmilk\n") });
  await page.getByRole("link", { name: /^Everything/ }).click();
  await page.locator(".card", { hasText: "todo" }).click();
  await page.locator(".text-viewer").getByRole("button", { name: "Edit" }).click();
  await page.locator(".file-edit").fill("item\nmilk\neggs\n");
  await page.getByRole("button", { name: "Save as new version" }).click();
  await page.locator(".versions-box summary", { hasText: "1 earlier" }).waitFor();
  await page.locator("table.sheet td", { hasText: "eggs" }).waitFor();

  // Connections: the imported note links [[sample]]; the PDF shows the backlink.
  await page.locator("#search").fill("Week 1");
  await page.locator(".card", { hasText: "Week 1" }).click();
  await page.locator(".folder-line", { hasText: "Maths" }).waitFor();
  await page.locator(".connections .link-chip", { hasText: "sample" }).first().waitFor();
  // Manual connection through the picker.
  await page.getByLabel("Connect to another item").fill("todo");
  await page.locator(".connect-picker li", { hasText: "todo" }).click();
  await page.locator(".connections .link-chip", { hasText: "todo" }).waitFor();
  await page.locator("#local-graph canvas").waitFor();
  if (shots) await page.screenshot({ path: join(shots, "web-connections.png") });

  // [[ autocomplete in the editor.
  await page.getByRole("button", { name: "Edit", exact: true }).click();
  const body = page.locator("#body-input");
  await body.press("End");
  await body.pressSequentially("\nAlso [[tod");
  await page.locator(".editor .suggest li", { hasText: "todo" }).first().waitFor();
  await body.press("Enter");
  assert.match(await body.inputValue(), /\[\[todo\]\]$/);
  await page.getByRole("button", { name: "History" }).click();
  await page.locator(".history-list li").first().waitFor();

  // Graph view.
  await page.locator("#search").fill("");
  await page.getByRole("button", { name: "Close" }).click();
  await page.getByRole("link", { name: /^Connections/ }).click();
  await page.locator("#graph-stage canvas").waitFor();
  await page.waitForTimeout(1500);
  if (shots) await page.screenshot({ path: join(shots, "web-graph.png") });

  // Drag a card onto a folder to move it; make and rename folders.
  await page.getByRole("link", { name: /^Everything/ }).click();
  await page.locator(".card.file", { hasText: "todo" }).dragTo(page.locator("#folder-list .folder-row", { hasText: "Uni" }));
  await page.locator("#new-folder").click(); // prompt answers "Projects"
  await until(async () => (await folderNames()).includes("Projects"), "new folder");

  // Everything reached the phone, filed the same way.
  await until(async () => {
    await phone.sync();
    const todo = phone.items().find((i) => i.title === "todo");
    const uni = phone.folders().find((f) => f.name === "Uni");
    return todo && uni && todo.folder === uni.id && todo.fileVersions.length === 1 && phone.folders().some((f) => f.name === "Projects");
  }, "moves and versions on the phone", 15000);
  const pdf = phone.items().find((i) => i.kind === "pdf");
  assert.equal(pdf.folder, "folder:documents");
  assert.ok(pdf.thumbnail, "thumbnail synced");
  const week = phone.items().find((i) => i.title === "Week 1");
  assert.deepEqual(phone.folders().filter((f) => f.id === week.folder).map((f) => f.name), ["Maths"]);

  // Phone width.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "Show library" }).click();
  await page.waitForTimeout(400);
  if (shots) await page.screenshot({ path: join(shots, "web-phone-folders.png") });

  assert.deepEqual(problems, []);
  await context.close();
});
