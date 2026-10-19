// Trove for any browser. Vanilla modules, no build step; the relay serves these files.
import { storage } from "./db.js";
import { search, smartCollections } from "./core/items.js";
import { RelayError, Vault } from "./core/vault.js";
import { renderMarkdown } from "./markdown.js";

const app = document.getElementById("app");
const state = { vault: null, selection: "all", query: "", openId: null, mode: null, renderQueued: false };
const blobURLs = new Map();
const MAX_UPLOAD = 100 * 1024 * 1024;
const MAX_CARDS = 400;

// ---------- tiny DOM helper ----------

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}

const $ = (sel, root = document) => root.querySelector(sel);

function toast(message) {
  const el = $("#toast");
  if (!el) return;
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 3500);
}

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
function ago(ms) {
  const s = (ms - Date.now()) / 1000;
  for (const [unit, size] of [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]]) {
    if (Math.abs(s) >= size) return relative.format(Math.round(s / size), unit);
  }
  return "just now";
}

function money(amount, currency) {
  try { return new Intl.NumberFormat(undefined, { style: "currency", currency: currency || "GBP" }).format(amount); } catch { return String(amount); }
}

function guessDeviceName() {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /Windows/.test(ua) ? "Windows" : /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Mac OS X/.test(ua) ? "Mac" : /Linux/.test(ua) ? "Linux" : "";
  return os ? `${browser} on ${os}` : browser;
}

// ---------- boot ----------

async function boot() {
  let vault = null;
  try { vault = await Vault.open(storage); } catch (e) { console.error(e); }
  app.classList.remove("loading");
  app.removeAttribute("aria-busy");
  if (vault) showMain(vault); else showSetup();
}

function showSetup(message) {
  app.replaceChildren($("#setup-view").content.cloneNode(true));
  const tabs = [...app.querySelectorAll("[data-tab]")];
  const select = (name) => {
    for (const t of tabs) t.setAttribute("aria-pressed", String(t.dataset.tab === name));
    for (const p of app.querySelectorAll("[data-panel]")) p.hidden = p.dataset.panel !== name;
    app.querySelector(`[data-panel="${name}"] textarea, [data-panel="${name}"] input`)?.focus();
  };
  for (const t of tabs) t.addEventListener("click", () => select(t.dataset.tab));
  for (const id of ["#create-name", "#device-name", "#recover-name"]) $(id).value = guessDeviceName();

  const wire = (form, run) => {
    const error = $(".error", form), button = $("button[type=submit]", form), label = button.textContent;
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      error.hidden = true;
      button.disabled = true;
      button.textContent = "Working…";
      try {
        await run();
      } catch (e) {
        error.textContent = e.message;
        error.hidden = false;
        button.disabled = false;
        button.textContent = label;
      }
    });
  };
  wire($("#create-form"), async () => {
    const { vault, recoveryCode } = await Vault.create(storage, { origin: location.origin, deviceName: $("#create-name").value.trim() });
    showRecovery(vault, recoveryCode);
  });
  wire($("#setup-form"), async () => {
    showMain(await Vault.join(storage, $("#setup-code").value, { origin: location.origin, deviceName: $("#device-name").value.trim() }));
  });
  wire($("#recover-form"), async () => {
    showMain(await Vault.recover(storage, $("#recover-code").value, { origin: location.origin, deviceName: $("#recover-name").value.trim() }));
  });
  if (message) {
    select("join");
    const error = $(".error", $("#setup-form"));
    error.textContent = message;
    error.hidden = false;
  }
}

function showRecovery(vault, code) {
  app.replaceChildren($("#recovery-view").content.cloneNode(true));
  $("#recovery-code").value = code;
  $("#copy-recovery").addEventListener("click", async () => {
    await navigator.clipboard?.writeText(code).catch(() => {});
    $("#recovery-code").select();
    $("#copy-recovery").textContent = "Copied";
  });
  $("#download-recovery").addEventListener("click", () => {
    const text = `Trove recovery code\nMade ${new Date().toLocaleString()} for ${location.origin}\nKeep this secret. Anyone with it can read your vault.\n\n${code}\n`;
    const a = h("a", { href: URL.createObjectURL(new Blob([text], { type: "text/plain" })), download: "Trove recovery code.txt" });
    a.click();
  });
  $("#saved-it").addEventListener("change", (e) => { $("#recovery-done").disabled = !e.target.checked; });
  $("#recovery-done").addEventListener("click", () => showMain(vault));
}

function showDevices() {
  const vault = state.vault;
  const frag = $("#devices-view").content.cloneNode(true);
  const backdrop = frag.firstElementChild;
  document.body.append(frag);
  const close = () => backdrop.remove();
  backdrop.addEventListener("click", (e) => { if (e.target === backdrop || e.target.closest("[data-close]")) close(); });
  backdrop.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });

  const ext = vault.browserExtensionCode();
  $("#extension-code", backdrop).value = ext ?? "Not available for this browser.";
  $("[data-copy-ext]", backdrop).addEventListener("click", () => navigator.clipboard?.writeText(ext ?? "").then(() => toast("Extension code copied")));
  $("#share-url", backdrop).textContent = `${location.origin}/#add=`;

  const error = $(".error", backdrop);
  $("#make-setup", backdrop).addEventListener("click", async () => {
    error.hidden = true;
    try {
      const code = await vault.setupCodeForNewDevice($("#add-recovery", backdrop).value);
      $("#add-recovery", backdrop).value = "";
      const out = $("#setup-out", backdrop);
      out.hidden = false;
      $("textarea", out).value = code;
      $("[data-copy]", out).onclick = () => navigator.clipboard?.writeText(code).then(() => toast("Setup code copied"));
    } catch (e) {
      error.textContent = e.message === "bad private key" ? "That isn't a recovery code." : e.message;
      error.hidden = false;
    }
  });

  const list = $("#device-list", backdrop);
  vault.api("GET", "devices").then(({ devices }) => {
    list.replaceChildren(...devices.filter((d) => !d.revoked).map((d) =>
      h("li", {}, h("span", { text: `${d.name}${d.deviceId === vault.config.deviceId ? " (this browser)" : ""}` }),
        h("span", { class: "saved", text: d.kind }))));
    list.previousElementSibling.textContent = "Devices in this vault";
  }).catch(() => {});
  $("#add-recovery", backdrop).focus();
}

/** `/#add=<url or text>`: lets an iPhone Shortcut (or a bookmarklet) save into Trove. */
function handleSharedAdd() {
  const m = /^#add=(.*)$/s.exec(location.hash);
  if (!m || !state.vault) return;
  history.replaceState(null, "", location.pathname);
  let value = "";
  try { value = decodeURIComponent(m[1]).trim(); } catch { value = m[1]; }
  if (!value) return;
  let url = null;
  try { const u = new URL(value); if (u.protocol === "http:" || u.protocol === "https:") url = u; } catch { /* text */ }
  if (url) toast(state.vault.addLink(url.toString()).isNew ? "Saved to Trove" : "Already saved");
  else { state.vault.addNote({ body: value }); toast("Note saved to Trove"); }
  syncSoon(300);
}

// ---------- main view ----------

function showMain(vault) {
  state.vault = vault;
  app.replaceChildren($("#main-view").content.cloneNode(true));
  vault.onChange(queueRender);

  $("#search").addEventListener("input", (e) => { state.query = e.target.value; queueRender(); });
  $("#new-note").addEventListener("click", () => {
    const id = vault.addNote();
    state.mode = "edit";
    openItem(id);
    syncSoon();
  });
  $("#capture").addEventListener("submit", (e) => {
    e.preventDefault();
    const input = $("#capture-input"), text = input.value.trim();
    if (!text) return;
    let url = null;
    try { const u = new URL(text); if (u.protocol === "http:" || u.protocol === "https:") url = u; } catch { /* plain text */ }
    if (url) {
      const { isNew } = vault.addLink(url.toString());
      toast(isNew ? "Link saved. Your Mac or iPhone will add the preview." : "Already saved");
    } else {
      vault.addNote({ body: text });
      toast("Note saved");
    }
    input.value = "";
    syncSoon();
  });
  $("#upload").addEventListener("change", async (e) => {
    const files = [...e.target.files];
    e.target.value = "";
    await upload(files);
  });
  document.addEventListener("dragover", (e) => { if (e.dataTransfer?.types.includes("Files")) e.preventDefault(); });
  document.addEventListener("drop", (e) => {
    if (!e.dataTransfer?.files.length) return;
    e.preventDefault();
    upload([...e.dataTransfer.files]);
  });
  $("#menu").addEventListener("click", () => $(".sidebar").classList.toggle("open"));
  $("#sync-now").addEventListener("click", () => runSync(true));
  $("#devices").addEventListener("click", showDevices);
  addEventListener("hashchange", handleSharedAdd);
  $("#forget").addEventListener("click", async () => {
    if (!confirm("Remove this browser from your vault? Its access is revoked and everything stored here is deleted. Your vault stays safe on your other devices.")) return;
    stopLive();
    await vault.forget();
    location.reload();
  });
  document.addEventListener("keydown", onKey);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") runSync(); });
  setInterval(() => runSync(), 60_000);
  claimTab();
  handleSharedAdd();
  render();
  runSync();
  connectLive();
}

function onKey(e) {
  const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName ?? "");
  if (e.key === "Escape" && state.openId) { closeItem(); return; }
  if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === "/") { e.preventDefault(); $("#search").focus(); }
  if (e.key === "n") { e.preventDefault(); $("#new-note").click(); }
}

async function upload(files) {
  for (const file of files) {
    if (file.size > MAX_UPLOAD) { toast(`${file.name} is over 100 MB`); continue; }
    toast(`Encrypting and uploading ${file.name}…`);
    try {
      await state.vault.addFile(new Uint8Array(await file.arrayBuffer()), file.name, file.type || "application/octet-stream");
      toast(`Added ${file.name}`);
    } catch (e) {
      toast(`Couldn't upload ${file.name}: ${e.message}`);
    }
  }
  syncSoon(200);
}

// ---------- rendering ----------

function queueRender() {
  if (state.renderQueued) return;
  state.renderQueued = true;
  requestAnimationFrame(() => { state.renderQueued = false; render(); });
}

function render() {
  const vault = state.vault;
  const items = vault.items();
  const collections = vault.collections();
  const now = Date.now();

  $("#smart-list").replaceChildren(...smartCollections.map((s) => {
    const count = items.filter((i) => s.contains(i, now)).length;
    if (!count && !["all", "notes", "pinned"].includes(s.id)) return null;
    return navLink(s.id, s.title, count);
  }).filter(Boolean));
  $("#collection-list").replaceChildren(...collections.map((c) => navLink(`c:${c.id}`, c.name, items.filter((i) => i.collections.includes(c.id)).length)));
  if (!collections.length) $("#collection-list").replaceChildren(h("p", { class: "side-note", text: "Make collections in the app." }));

  let shown;
  let title;
  if (state.selection.startsWith("c:")) {
    const id = state.selection.slice(2);
    shown = items.filter((i) => i.collections.includes(id));
    title = collections.find((c) => c.id === id)?.name ?? "Collection";
  } else {
    const smart = smartCollections.find((s) => s.id === state.selection) ?? smartCollections[0];
    shown = items.filter((i) => smart.contains(i, now));
    title = smart.title;
  }
  if (state.query.trim()) {
    shown = search(shown, state.query, now);
    title = `${shown.length} result${shown.length === 1 ? "" : "s"}`;
  }
  $("#heading").textContent = title;
  $("#grid").replaceChildren(...shown.slice(0, MAX_CARDS).map(card));
  $("#empty").hidden = shown.length > 0;
  if (shown.length > MAX_CARDS) $("#grid").append(h("p", { class: "empty", text: `Showing the newest ${MAX_CARDS}. Search to find the rest.` }));
  renderDetail();
}

function navLink(id, title, count) {
  return h("a", {
    href: "#", "aria-current": state.selection === id ? "true" : "false",
    onclick: (e) => { e.preventDefault(); state.selection = id; $(".sidebar").classList.remove("open"); render(); },
  }, h("span", { text: title }), h("span", { class: "count", text: count }));
}

const kindLabel = { note: "Note", link: "Link", image: "Image", pdf: "PDF", audio: "Audio", video: "Video", file: "File", highlight: "Highlight", email: "Email" };

function card(item) {
  const snippet = item.kind === "highlight" ? item.body.replace(/^> /gm, "") : item.summary || item.body.trim() || item.ocrText || "";
  const price = item.priceWatch?.price ?? item.extracted.product?.price;
  const currency = item.priceWatch?.currency ?? item.extracted.product?.currency;
  const thumb = item.imageURL?.startsWith("https://") ? h("img", { class: "thumb", src: item.imageURL, alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => e.target.remove() }) : null;
  return h("button", { type: "button", class: `card ${item.kind}`, onclick: () => openItem(item.id) },
    thumb,
    h("div", { class: "body" },
      h("div", { class: "meta" },
        item.isPinned ? h("span", { class: "pin", "aria-label": "Pinned", text: "●" }) : null,
        h("span", { text: [kindLabel[item.kind] ?? item.kind, item.siteName || item.url?.hostname.replace(/^www\./, ""), item.createdAt ? ago(item.createdAt) : null].filter(Boolean).join(" · ") }),
        item.hasConflicts ? h("span", { class: "danger", text: "· needs attention" }) : null),
      h("div", { class: "title", text: item.displayTitle }),
      snippet && snippet !== item.displayTitle ? h("div", { class: "snippet", text: snippet.slice(0, 400) }) : null,
      typeof price === "number" ? h("div", { class: "price", text: money(price, currency) }) : null,
      item.tags.length ? h("div", { class: "tags" }, item.tags.slice(0, 4).map((t) => h("span", { class: "tag-chip", text: `#${t}` }))) : null));
}

// ---------- detail ----------

function openItem(id) {
  state.openId = id;
  const item = state.vault.item(id);
  if (!state.mode) state.mode = item && item.kind === "note" && !item.body ? "edit" : "preview";
  renderDetail(true);
}

function closeItem() {
  flushBody();
  state.openId = null;
  state.mode = null;
  $("#detail").hidden = true;
  $("#detail").replaceChildren();
}

function renderDetail(force = false) {
  const panel = $("#detail");
  if (!state.openId) { panel.hidden = true; return; }
  // Don't redraw under the user's cursor; their own edits are already in the store.
  if (!force && panel.contains(document.activeElement) && /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)) return;
  const vault = state.vault;
  const item = vault.item(state.openId);
  if (!item) { closeItem(); return; }
  panel.hidden = false;

  const bar = h("div", { class: "detail-bar" },
    h("button", { type: "button", class: "secondary", onclick: () => { vault.setPinned(item.id, !item.isPinned); syncSoon(); } }, item.isPinned ? "Unpin" : "Pin"),
    item.kind === "link" ? h("button", { type: "button", class: "secondary", onclick: () => { vault.markRead(item.id, item.readAt === null); syncSoon(); } }, item.readAt === null ? "Mark read" : "Mark unread") : null,
    h("span", { class: "spacer" }),
    h("button", { type: "button", class: "secondary danger", onclick: () => { if (confirm("Delete this item on all your devices?")) { vault.delete(item.id); closeItem(); syncSoon(); } } }, "Delete"),
    h("button", { type: "button", class: "icon-button", "aria-label": "Close", onclick: closeItem }, "✕"));

  const title = h("input", { class: "title-input", value: item.title, placeholder: item.displayTitle, "aria-label": "Title" });
  title.addEventListener("change", () => { vault.update(item.id, { title: title.value.trim() }); syncSoon(); });
  title.addEventListener("keydown", (e) => { if (e.key === "Enter") title.blur(); });

  const meta = h("div", { class: "meta" },
    h("span", { text: kindLabel[item.kind] ?? item.kind }),
    item.createdAt ? h("span", { text: new Date(item.createdAt).toLocaleString() }) : null,
    item.source !== "app" ? h("span", { text: `from ${item.source}` }) : null,
    item.tags.length ? h("span", {}, item.tags.map((t) => h("a", { href: "#", onclick: (e) => { e.preventDefault(); searchFor(`tag:${t}`); } }, `#${t} `))) : null);

  const parts = [bar, title, meta];
  if (item.url) parts.push(h("a", { class: "url", href: item.url.toString(), target: "_blank", rel: "noopener noreferrer", text: item.url.toString() }));
  if (item.summary) parts.push(h("p", { class: "summary", text: item.summary }));
  for (const version of item.conflictingVersions) {
    parts.push(h("div", { class: "conflict" },
      h("strong", { text: "Edited on two devices at once" }),
      h("p", { text: "Trove kept both. Pick the one to keep (you can edit it after)." }),
      h("pre", { text: version }),
      h("button", { type: "button", class: "secondary", onclick: () => { vault.resolveConflicts(item.id, version); syncSoon(); } }, "Keep this version"), " ",
      h("button", { type: "button", class: "secondary", onclick: () => { vault.resolveConflicts(item.id, item.body); syncSoon(); } }, "Keep the current text")));
  }

  // Body: preview or edit.
  const segmented = h("div", { class: "segmented", role: "group", "aria-label": "Body view" },
    h("button", { type: "button", "aria-pressed": String(state.mode === "preview"), onclick: () => { flushBody(); state.mode = "preview"; renderDetail(true); } }, "Preview"),
    h("button", { type: "button", "aria-pressed": String(state.mode === "edit"), onclick: () => { state.mode = "edit"; renderDetail(true); $("#body-input")?.focus(); } }, "Edit"));
  const saved = h("span", { class: "saved", id: "saved" });
  parts.push(h("section", {}, h("div", { class: "body-head" }, segmented, saved)));
  if (state.mode === "edit") {
    const body = h("textarea", { class: "body-input", id: "body-input", "aria-label": "Note", placeholder: "Write in Markdown. #tags work." });
    body.value = item.body;
    body.dataset.id = item.id;
    body.addEventListener("input", () => {
      saved.textContent = "Editing…";
      clearTimeout(flushBody.timer);
      flushBody.timer = setTimeout(flushBody, 700);
    });
    body.addEventListener("blur", flushBody);
    parts.push(body);
  } else {
    const preview = h("div", { class: "preview" });
    preview.innerHTML = item.body ? renderMarkdown(item.body) : `<p class="saved">No text yet.</p>`; // escaped by renderMarkdown
    preview.addEventListener("click", (e) => {
      const tag = e.target.closest("a.tag"), wiki = e.target.closest("a.wikilink");
      if (tag) { e.preventDefault(); searchFor(`tag:${tag.dataset.tag.toLowerCase()}`); }
      if (wiki) { e.preventDefault(); openByTitle(wiki.dataset.target); }
    });
    parts.push(preview);
  }

  if (item.attachments.length) parts.push(h("section", {}, h("h3", { class: "section-title", text: "Attachments" }), item.attachments.map(attachmentView)));
  if (item.ocrText && item.kind !== "note") parts.push(h("section", {}, h("h3", { class: "section-title", text: "Text found in the file" }), h("p", { class: "saved ocr", text: item.ocrText.slice(0, 4000) })));
  if (item.priceWatch) {
    const w = item.priceWatch;
    parts.push(h("section", {}, h("h3", { class: "section-title", text: "Price tracking" }),
      h("p", { text: typeof w.price === "number" ? `Now ${money(w.price, w.currency)}${typeof w.lowest === "number" ? ` · lowest ${money(w.lowest, w.currency)}` : ""}` : "Waiting for the first check" })));
  }
  if (item.published?.url) {
    parts.push(h("section", {}, h("h3", { class: "section-title", text: "Public link" }), h("a", { href: item.published.url, target: "_blank", rel: "noopener noreferrer", text: item.published.url })));
  }
  const collections = vault.collections();
  if (collections.length) {
    parts.push(h("section", {}, h("h3", { class: "section-title", text: "Collections" }), h("div", { class: "chips" }, collections.map((c) =>
      h("button", { type: "button", "aria-pressed": String(item.collections.includes(c.id)), onclick: () => { vault.toggleCollection(item.id, c.id); syncSoon(); } }, c.name)))));
  }
  panel.replaceChildren(...parts);
}

function flushBody() {
  clearTimeout(flushBody.timer);
  const body = $("#body-input");
  if (!body || !state.vault.item(body.dataset.id)) return;
  state.vault.setBody(body.dataset.id, body.value);
  const saved = $("#saved");
  if (saved) saved.textContent = "Saved";
  syncSoon();
}

function attachmentView(att) {
  const box = h("div", { class: "attachment" });
  const label = `${att.name}${att.size ? ` · ${(att.size / 1024 / 1024).toFixed(att.size > 1e6 ? 1 : 2)} MB` : ""}`;
  const inline = /^(image|video|audio)\//.test(att.mime);
  const show = async () => {
    box.replaceChildren(h("span", { class: "saved", text: `Decrypting ${att.name}…` }));
    try {
      const url = await blobURL(att);
      const tag = att.mime.split("/")[0];
      if (tag === "image") box.replaceChildren(h("img", { src: url, alt: att.name }));
      else if (tag === "video" || tag === "audio") box.replaceChildren(h(tag, { src: url, controls: true }));
      else box.replaceChildren(h("a", { href: url, download: att.name, target: "_blank", rel: "noopener", text: `Open ${label}` }));
    } catch (e) {
      box.replaceChildren(h("span", { class: "danger", text: `Couldn't load ${att.name}: ${e.message}` }));
    }
  };
  if (inline && att.size < 25 * 1024 * 1024) show();
  else box.append(h("button", { type: "button", class: "secondary", onclick: show }, `Decrypt ${label}`));
  return box;
}

async function blobURL(att) {
  if (!blobURLs.has(att.id)) {
    const bytes = await state.vault.attachment(att.id);
    blobURLs.set(att.id, URL.createObjectURL(new Blob([bytes], { type: att.mime })));
  }
  return blobURLs.get(att.id);
}

function searchFor(query) {
  const input = $("#search");
  input.value = query;
  state.query = query;
  state.selection = "all";
  if (matchMedia("(max-width: 760px)").matches) closeItem();
  render();
}

function openByTitle(title) {
  const t = title.trim().toLowerCase();
  const match = state.vault.items().find((i) => i.displayTitle.toLowerCase() === t);
  if (match) { flushBody(); state.mode = null; openItem(match.id); } else searchFor(title);
}

// ---------- sync ----------

let syncing = false, syncAgain = false, syncTimer = null;

function syncSoon(delay = 1500) {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => runSync(), delay);
}

async function runSync(manual = false) {
  if (!state.vault || otherTabActive) return;
  if (syncing) { syncAgain = true; return; }
  syncing = true;
  try {
    const report = await state.vault.sync();
    if (report.imported) toast(report.imported === 1 ? "1 new item from your inbox" : `${report.imported} new items from your inbox`);
    setStatus(report.errors.length ? "error" : live ? "live" : "idle", report.errors[0]);
    if (manual) toast(report.errors.length ? `Sync problem: ${report.errors[0]}` : "Up to date");
  } catch (e) {
    if (e instanceof RelayError && e.status === 401) {
      stopLive();
      await storage.clear();
      showSetup("This browser was removed from your vault. Paste a new setup code to reconnect.");
      return;
    }
    setStatus("error", e.message);
    if (manual) toast(`Couldn't sync: ${e.message}`);
  } finally {
    syncing = false;
    if (syncAgain) { syncAgain = false; syncSoon(300); }
  }
}

function setStatus(kind, detail) {
  const el = $("#sync-status");
  if (!el) return;
  el.className = `sync-status ${kind}`;
  $(".label", el).textContent = kind === "live" ? "Live" : kind === "error" ? "Sync problem" : `Synced ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
  el.title = detail ?? "";
}

// ---------- live updates ----------

let socket = null, live = false, backoff = 2000, pingTimer = null, stopped = false;

function connectLive() {
  stopped = false;
  try { socket = new WebSocket(state.vault.liveURL); } catch { return; }
  socket.addEventListener("open", () => {
    live = true;
    backoff = 2000;
    setStatus("live");
    clearInterval(pingTimer);
    pingTimer = setInterval(() => socket?.readyState === 1 && socket.send("ping"), 25_000);
  });
  socket.addEventListener("message", (e) => { if (e.data !== "pong") syncSoon(150); });
  socket.addEventListener("close", (e) => {
    live = false;
    clearInterval(pingTimer);
    if (stopped) return;
    setStatus("idle");
    if (e.code === 4001) { runSync(); return; } // revoked: the next sync shows the setup screen
    setTimeout(connectLive, backoff);
    backoff = Math.min(backoff * 2, 60_000);
  });
}

function stopLive() {
  stopped = true;
  clearInterval(pingTimer);
  socket?.close();
}

// ---------- one tab at a time (they'd share one device journal) ----------

let otherTabActive = false;
const channel = "BroadcastChannel" in window ? new BroadcastChannel("trove") : null;

function claimTab() {
  otherTabActive = false;
  $("#other-tab").hidden = true;
  channel?.postMessage("claim");
  $("#use-here").onclick = async () => {
    claimTab();
    const fresh = await Vault.open(storage);
    if (fresh) { state.vault = fresh; fresh.onChange(queueRender); }
    render();
    runSync();
    connectLive();
  };
}

channel?.addEventListener("message", (e) => {
  if (e.data !== "claim" || !state.vault) return;
  flushBody();
  state.vault.save();
  otherTabActive = true;
  stopLive();
  $("#other-tab").hidden = false;
});

addEventListener("pagehide", () => { if (state.vault && !otherTabActive) { flushBody(); state.vault.save(); } });

boot();
