// Service worker: context menus, keyboard shortcut, and an offline queue that retries uploads.
import { b64uDecode, envelope, seal } from "./trv1.js";

const MENU = [
  { id: "trove-page", title: "Save page to Trove", contexts: ["page"] },
  { id: "trove-selection", title: "Save selection to Trove", contexts: ["selection"] },
  { id: "trove-link", title: "Save link to Trove", contexts: ["link"] },
  { id: "trove-image", title: "Save image to Trove", contexts: ["image"] },
];

chrome.runtime.onInstalled.addListener(async () => {
  chrome.contextMenus.removeAll(() => MENU.forEach((m) => chrome.contextMenus.create(m)));
  chrome.alarms.create("trove-retry", { periodInMinutes: 5 });
  const { setup } = await chrome.storage.local.get("setup");
  if (!setup) chrome.runtime.openOptionsPage();
});

chrome.alarms.onAlarm.addListener((a) => { if (a.name === "trove-retry") flushQueue(); });

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const capture = { url: tab?.url, title: tab?.title };
  if (info.menuItemId === "trove-selection") capture.text = info.selectionText;
  if (info.menuItemId === "trove-link") Object.assign(capture, { url: info.linkUrl, title: info.linkUrl, text: "" });
  if (info.menuItemId === "trove-image") Object.assign(capture, { url: info.srcUrl, title: `Image from ${tab?.title ?? "page"}`, text: "" });
  if (info.menuItemId === "trove-page" && tab?.id) Object.assign(capture, await readPage(tab.id));
  await notify(await save(capture));
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "save-page") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return;
  await notify(await save({ url: tab.url, title: tab.title, ...(await readPage(tab.id)) }));
});

chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message.type === "save") save(message.capture).then(reply);
  if (message.type === "read-page") readPage(message.tabId).then(reply);
  if (message.type === "flush") flushQueue().then(reply);
  return true;
});

/** Selected text plus a short description, read from the page itself. */
async function readPage(tabId) {
  try {
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const meta = (n) => document.querySelector(`meta[property="${n}"],meta[name="${n}"]`)?.content ?? "";
        return {
          text: String(window.getSelection() ?? "").trim(),
          title: meta("og:title") || document.title,
          description: meta("og:description") || meta("description"),
          canonical: document.querySelector('link[rel="canonical"]')?.href ?? "",
        };
      },
    });
    return { text: result.text, title: result.title, description: result.description, url: result.canonical || undefined };
  } catch {
    return {}; // chrome:// pages, the Web Store, etc.
  }
}

/** Seals and uploads; queues on failure. Returns {ok, queued?, error?}. */
export async function save(capture) {
  const { setup } = await chrome.storage.local.get("setup");
  if (!setup) return { ok: false, error: "Set up the extension first (paste the code from Trove → Settings → Browser)." };
  if (!capture.url && !capture.text) return { ok: false, error: "Nothing to save on this page." };
  const note = [capture.text, capture.note].filter(Boolean).join("\n\n");
  const body = new TextEncoder().encode(note);
  const sealed = await seal(
    envelope({ source: "web", url: capture.url, title: capture.title ?? "", mime: "text/plain", meta: capture.description ? { description: capture.description } : undefined }, body),
    b64uDecode(setup.vaultPublicKey),
  );
  try {
    await upload(setup, sealed);
    flushQueue();
    return { ok: true };
  } catch (e) {
    const { queue = [] } = await chrome.storage.local.get("queue");
    queue.push({ sealed: Array.from(sealed), at: Date.now() });
    await chrome.storage.local.set({ queue: queue.slice(-200) });
    return { ok: false, queued: true, error: `Saved offline, will retry (${e.message})` };
  }
}

async function upload(setup, sealed) {
  const res = await fetch(`${setup.relayURL}/v1/vaults/${setup.vaultId}/inbox`, {
    method: "POST",
    headers: { authorization: `Bearer ${setup.inboxToken}`, "x-trove-source": "web", "content-type": "application/octet-stream" },
    body: sealed,
  });
  if (res.status !== 201) throw new Error(`relay said ${res.status}`);
}

async function flushQueue() {
  const { setup, queue = [] } = await chrome.storage.local.get(["setup", "queue"]);
  if (!setup || queue.length === 0) return { sent: 0, left: queue.length };
  const left = [];
  let sent = 0;
  for (const entry of queue) {
    try {
      await upload(setup, new Uint8Array(entry.sealed));
      sent++;
    } catch {
      left.push(entry);
    }
  }
  await chrome.storage.local.set({ queue: left });
  return { sent, left: left.length };
}

async function notify(result) {
  await chrome.action.setBadgeBackgroundColor({ color: result.ok ? "#34C759" : result.queued ? "#FF9F0A" : "#FF3B30" });
  await chrome.action.setBadgeText({ text: result.ok ? "OK" : result.queued ? "…" : "!" });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2500);
}
