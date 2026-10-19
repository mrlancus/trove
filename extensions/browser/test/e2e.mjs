// End-to-end: the real extension in real Chromium, saving into a real (local) relay.
//   1. cd server && npx wrangler dev --local --config wrangler.test.jsonc --port 8787
//   2. cd extensions/browser && npm install && npm run test:e2e
// Env: TROVE_RELAY_URL (default http://127.0.0.1:8787), CHROMIUM_PATH (default: Playwright's bundled Chromium).
import { chromium } from "playwright-core";
import { cpSync, mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { b64uEncode } from "../trv1.js";
import { open, parseEnvelope } from "../../../server/src/crypto.ts";

const RELAY = process.env.TROVE_RELAY_URL ?? "http://127.0.0.1:8787";
const here = new URL("..", import.meta.url).pathname;

function findChromium() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH ?? "/opt/pw-browsers";
  const dir = readdirSync(root).find((d) => /^chromium-\d+$/.test(d));
  const exe = dir && join(root, dir, "chrome-linux", "chrome");
  if (!exe || !existsSync(exe)) throw new Error("Chromium not found; set CHROMIUM_PATH");
  return exe;
}

// A page to save, with Open Graph tags and a canonical URL.
const page = createServer((_, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<html><head><title>Raw title</title>
    <meta property="og:title" content="Best Ever Ramen">
    <meta name="description" content="Rich, quick ramen.">
    <link rel="canonical" href="https://cook.example/ramen"></head>
    <body><p id="q">Use white miso for a lighter broth.</p></body></html>`);
}).listen(0);
const pageURL = `http://127.0.0.1:${page.address().port}/ramen`;

// A vault on the relay, as the Mac app would create it.
const keys = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
const pub = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
const reg = await (await fetch(`${RELAY}/v1/vaults`, {
  method: "POST",
  body: JSON.stringify({ vaultPublicKey: b64uEncode(pub), deviceName: "Test Mac", deviceKind: "mac" }),
})).json();
assert.ok(reg.inboxToken, "relay didn't create a vault; is wrangler dev running?");
const setup = { relayURL: RELAY, vaultId: reg.vaultId, inboxToken: reg.inboxToken, vaultPublicKey: b64uEncode(pub) };

// Copy the extension and grant host access up front (a real user grants it on the setup page).
const extDir = mkdtempSync(join(tmpdir(), "trove-ext-"));
cpSync(here, extDir, { recursive: true, filter: (p) => !p.includes("node_modules") && !p.includes("/test") });
const manifest = JSON.parse(readFileSync(join(extDir, "manifest.json"), "utf8"));
manifest.host_permissions = ["http://127.0.0.1/*"];
writeFileSync(join(extDir, "manifest.json"), JSON.stringify(manifest));

const context = await chromium.launchPersistentContext(mkdtempSync(join(tmpdir(), "trove-profile-")), {
  executablePath: findChromium(),
  headless: true,
  args: [`--disable-extensions-except=${extDir}`, `--load-extension=${extDir}`, "--headless=new"],
});

let failures = 0;
async function step(name, fn) {
  try { await fn(); console.log(`✔ ${name}`); } catch (e) { failures++; console.log(`✘ ${name}\n  ${e.stack ?? e}`); }
}

try {
  const worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker"));
  const extId = new URL(worker.url()).host;
  const target = await context.newPage();
  await target.goto(pageURL);
  await target.evaluate(() => {
    const r = document.createRange();
    r.selectNodeContents(document.getElementById("q"));
    getSelection().removeAllRanges();
    getSelection().addRange(r);
  });
  const ui = await context.newPage();
  await ui.goto(`chrome-extension://${extId}/options.html`);

  await step("setup page shows how to connect", async () => {
    assert.match(await ui.textContent("h1"), /Connect to Trove/);
  });

  const inbox = async () => (await (await fetch(`${RELAY}/v1/vaults/${reg.vaultId}/inbox`, { headers: { authorization: `Bearer ${reg.deviceToken}` } })).json()).entries;
  const openEntry = async (id) => {
    const sealed = new Uint8Array(await (await fetch(`${RELAY}/v1/vaults/${reg.vaultId}/inbox/${id}`, { headers: { authorization: `Bearer ${reg.deviceToken}` } })).arrayBuffer());
    return parseEnvelope(await open(sealed, { recipientPrivateKey: keys.privateKey, recipientPublicKey: pub }));
  };
  const save = (note) => ui.evaluate(async ({ pageURL, note }) => {
    const [tab] = await chrome.tabs.query({ url: pageURL });
    const read = await chrome.runtime.sendMessage({ type: "read-page", tabId: tab.id });
    return chrome.runtime.sendMessage({ type: "save", capture: { url: read.url || tab.url, title: read.title || tab.title, text: read.text, description: read.description, note } });
  }, { pageURL, note });

  await step("refuses to save before setup", async () => {
    const r = await save("");
    assert.equal(r.ok, false);
    assert.match(r.error, /Set up/);
  });

  await ui.evaluate((setup) => chrome.storage.local.set({ setup }), setup);

  await step("saves the page + selection + note, sealed so only the vault can read it", async () => {
    const r = await save("try with chilli oil #todo");
    assert.equal(r.ok, true, JSON.stringify(r));
    const entries = await inbox();
    assert.equal(entries.length, 1);
    assert.equal(entries[0].source, "web");
    const { header, body } = await openEntry(entries[0].id);
    assert.equal(header.url, "https://cook.example/ramen");      // canonical URL from the page
    assert.equal(header.title, "Best Ever Ramen");               // og:title
    assert.equal(header.meta.description, "Rich, quick ramen.");
    assert.equal(new TextDecoder().decode(body), "Use white miso for a lighter broth.\n\ntry with chilli oil #todo");
  });

  await step("queues saves while the relay is unreachable, then flushes them", async () => {
    await ui.evaluate((setup) => chrome.storage.local.set({ setup: { ...setup, relayURL: "http://127.0.0.1:9" } }), setup);
    const r = await save("offline one");
    assert.equal(r.ok, false);
    assert.equal(r.queued, true);
    await ui.evaluate((setup) => chrome.storage.local.set({ setup }), setup);
    const flushed = await ui.evaluate(() => chrome.runtime.sendMessage({ type: "flush" }));
    assert.deepEqual(flushed, { sent: 1, left: 0 });
    assert.equal((await inbox()).length, 2);
  });

} finally {
  await context.close();
  page.close();
}
if (failures) { console.log(`\n${failures} failed`); process.exit(1); }
console.log("\nAll extension e2e checks passed");
