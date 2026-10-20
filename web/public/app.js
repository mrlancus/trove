// Trove for any browser. Vanilla modules, no build step; the relay serves these files.
import { storage } from "./db.js";
import { search, smartCollections } from "./core/items.js";
import { availableTransforms, clipMatches, color, colorFormats, isSensitive } from "./core/clips.js";
import { RelayError, Vault } from "./core/vault.js";
import { importActions } from "./core/importer.js";
import { renderMarkdown } from "./markdown.js";
import { $, ago, fileSize, h } from "./dom.js";
import { folderAndDescendants, folderPathOf, folderTree } from "./core/organize.js";
import { linkGraph, mentions, neighbours, related, wikilinks } from "./core/links.js";
import { isEditableText, previewKind, typeLabel } from "./core/files.js";
import { attachmentPreview, canInk, inkPages, lightbox, makeThumbnail, wantsThumbnail } from "./viewer.js";
import { openInkEditor, renderSketchPage, sketchPages, sketchThumbnail } from "./draw.js";
import { buildGraph, folderColor, graphCanvas } from "./graph.js";

const app = document.getElementById("app");
const state = { vault: null, selection: "all", query: "", openId: null, mode: null, renderQueued: false, clipFilter: "all", openClip: null,
  importRun: null, expanded: new Set(loadPref("expanded", [])), wide: false, history: false,
  selecting: false, picked: new Set(), anchor: null, shownIds: [], graphOpts: loadPref("graph", { tags: true, folderNodes: false, unlinked: false }) };

function loadPref(key, fallback) {
  try { const v = JSON.parse(localStorage.getItem(`trove.${key}`)); return v ?? fallback; } catch { return fallback; }
}
function savePref(key, value) {
  try { localStorage.setItem(`trove.${key}`, JSON.stringify(value)); } catch { /* private mode */ }
}
const ITEM_DRAG = "application/x-trove-item";
const blobURLs = new Map();
const MAX_UPLOAD = 100 * 1024 * 1024;
const MAX_ZIP = 1024 * 1024 * 1024;
const MAX_CARDS = 400;

function toast(message) {
  const el = $("#toast");
  if (!el) return;
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 3500);
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
  $("#new-sketch").addEventListener("click", () => {
    const id = vault.addSketch();
    syncSoon();
    openSketch(id, 0, () => openItem(id));
  });
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
  for (const id of ["#upload", "#import-files", "#import-folder"]) {
    $(id).addEventListener("change", (e) => {
      const files = [...e.target.files];
      e.target.value = "";
      if (files.length) importFiles(files);
    });
  }
  wireDrops();
  $("#import-show").addEventListener("click", () => { state.importRun = null; state.selection = "all"; render(); });
  $("#import-more").addEventListener("click", () => { state.importRun = null; render(); });
  $("#menu").addEventListener("click", () => $(".sidebar").classList.toggle("open"));
  $("#select-mode").addEventListener("click", () => setSelecting(!state.selecting));
  $("#sync-now").addEventListener("click", () => runSync(true));
  $("#devices").addEventListener("click", showDevices);
  $("#new-folder").addEventListener("click", (e) => { e.stopPropagation(); newFolder(null); });
  folderDropTarget($("#folders-heading"), null);
  addEventListener("hashchange", handleSharedAdd);
  $("#forget").addEventListener("click", async () => {
    if (!confirm("Remove this browser from your vault? Its access is revoked and everything stored here is deleted. Your vault stays safe on your other devices.")) return;
    stopLive();
    clearTimeout(syncTimer);
    state.vault = null; // no more syncs from this tab
    await vault.forget();
    location.reload();
  });
  document.addEventListener("keydown", onKey);
  document.addEventListener("paste", (e) => {
    if (/^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName ?? "") || !state.vault) return;
    const file = [...(e.clipboardData?.files ?? [])].find((f) => f.type.startsWith("image/"));
    const text = e.clipboardData?.getData("text/plain");
    if (!file && !text) return;
    e.preventDefault();
    addToClipboardHistory({ file, text }).then(() => { if (state.selection !== "clips") { state.selection = "clips"; render(); } });
  });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") runSync(); });
  setInterval(() => runSync(), 60_000);
  claimTab();
  handleSharedAdd();
  render();
  runSync();
  connectLive();
}

function onKey(e) {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName ?? "");
  if (e.key === "Escape" && state.openId) { closeItem(); return; }
  if (e.key === "Escape" && state.selecting) { setSelecting(false); return; }
  if (state.selecting && !typing) {
    if ((e.metaKey || e.ctrlKey) && e.key === "a") { e.preventDefault(); state.picked = new Set(state.shownIds); render(); return; }
    if ((e.key === "Delete" || e.key === "Backspace") && state.picked.size) { e.preventDefault(); deletePicked(); return; }
  }
  if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === "/") { e.preventDefault(); $("#search").focus(); }
  if (e.key === "n") { e.preventDefault(); $("#new-note").click(); }
}

// ---------- import ----------

/** Drops anywhere on the page: files and folders are imported, a dragged link or text is captured. */
function wireDrops() {
  const overlay = $("#drop-overlay"), zone = $("#dropzone");
  let depth = 0;
  const carriesFiles = (e) => e.dataTransfer?.types.includes("Files") && !e.dataTransfer.types.includes(ITEM_DRAG);
  const reset = () => { depth = 0; overlay.hidden = true; zone.classList.remove("hover"); };
  document.addEventListener("dragenter", (e) => {
    if (!carriesFiles(e)) return;
    depth++;
    overlay.hidden = state.selection === "import";
  });
  document.addEventListener("dragleave", (e) => { if (carriesFiles(e) && --depth <= 0) reset(); });
  document.addEventListener("dragover", (e) => {
    if (!e.dataTransfer) return;
    e.preventDefault();
    zone.classList.toggle("hover", zone.contains(e.target));
  });
  document.addEventListener("drop", async (e) => {
    const dt = e.dataTransfer;
    if (!dt || dt.types.includes(ITEM_DRAG) || e.defaultPrevented) return; // moving a card is handled by the folder it's dropped on
    if (e.target.closest?.("input, textarea") && !dt.files.length) return; // let text drop into fields
    e.preventDefault();
    reset();
    if (dt.files.length) { importFiles(await droppedFiles(dt)); return; }
    const text = (dt.getData("text/uri-list").split("\n").find((l) => l && !l.startsWith("#")) || dt.getData("text/plain")).trim();
    if (!text) return;
    let url = null;
    try { const u = new URL(text); if (u.protocol === "http:" || u.protocol === "https:") url = u; } catch { /* text */ }
    if (url) toast(state.vault.addLink(url.toString()).isNew ? "Link saved" : "Already saved");
    else { state.vault.addNote({ body: text }); toast("Note saved"); }
    syncSoon();
  });
}

/** Dropped files, with dropped folders walked. Entries must be taken before the first await. */
async function droppedFiles(dt) {
  const entries = [...dt.items].map((i) => i.webkitGetAsEntry?.()).filter(Boolean);
  if (!entries.length) return [...dt.files];
  const out = [];
  const walk = async (entry) => {
    if (entry.name.startsWith(".")) return;
    if (entry.isFile) {
      const f = await new Promise((ok, fail) => entry.file(ok, fail)).catch(() => null);
      // Where it sat in the dropped folder, so it's filed the same way ("/Uni/Maths/a.pdf" → Uni › Maths).
      if (f) { folderOfFile.set(f, entry.fullPath.split("/").filter(Boolean).slice(0, -1)); out.push(f); }
      return;
    }
    const reader = entry.createReader();
    for (;;) {
      const batch = await new Promise((ok, fail) => reader.readEntries(ok, fail)).catch(() => []);
      if (!batch.length) break;
      for (const e of batch) await walk(e);
    }
  };
  for (const e of entries) await walk(e);
  return out;
}

const folderOfFile = new WeakMap();
const folderOf = (file) => folderOfFile.get(file) ?? (file.webkitRelativePath ? file.webkitRelativePath.split("/").slice(0, -1) : []);

/** Imports files one by one (zips opened, exports parsed; core/importer.js), animating the Import page. */
async function importFiles(files) {
  if (state.importRun && !state.importRun.finished) { toast("Still importing. Drop the rest when it's done."); return; }
  const run = state.importRun = { total: files.length, done: 0, added: 0, current: null, recent: [], seq: 0, finished: false };
  state.selection = "import";
  render();
  for (const file of files) {
    run.current = file.name;
    renderImport();
    const isZip = /\.zip$/i.test(file.name);
    try {
      if (file.size > (isZip ? MAX_ZIP : MAX_UPLOAD)) toast(`${file.name} is too big to import here`);
      else {
        for (const action of await importActions(file.name, new Uint8Array(await file.arrayBuffer()), folderOf(file))) {
          const [count, label] = await applyImport(action);
          run.added += count;
          if (count) run.recent.unshift({ id: ++run.seq, label });
        }
        run.recent = run.recent.slice(0, 8);
      }
    } catch (e) {
      toast(`Couldn't import ${file.name}: ${e.message}`);
    }
    run.done++;
    renderImport();
  }
  run.current = null;
  run.finished = true;
  render();
  syncSoon(200);
}

async function applyImport(action) {
  const vault = state.vault;
  if (action.type === "items") {
    const n = vault.importItems(action.items);
    const kind = action.items[0]?.kind === "highlight" ? "highlight" : "link";
    return [n, `${n} ${kind}${n === 1 ? "" : "s"}`];
  }
  if (action.type === "note") {
    vault.addNote({ title: action.title, body: action.body, tags: action.tags, source: "import", folder: action.folder });
    return [1, action.title || "Note"];
  }
  if (action.bytes.length > MAX_UPLOAD) { toast(`${action.name} is over 100 MB`); return [0, action.name]; }
  await vault.addFile(action.bytes, action.name, action.mime, { source: "import", folder: action.folder });
  return [1, action.name];
}

function renderImport() {
  const view = $("#import-view"), run = state.importRun;
  if (!view) return;
  $(".dz-idle", view).hidden = Boolean(run);
  $(".dz-progress", view).hidden = !run || run.finished;
  $(".dz-done", view).hidden = !run?.finished;
  if (!run) return;
  const panel = run.finished ? $(".dz-done", view) : $(".dz-progress", view);
  // Only new arrivals are added, so each slides in once.
  const list = $(".arrivals", panel);
  for (const a of run.recent.slice(0, 5).reverse()) {
    if (!list.querySelector(`[data-id="${a.id}"]`)) list.prepend(h("li", { "data-id": a.id, text: a.label }));
  }
  while (list.children.length > 5) list.lastElementChild.remove();
  if (!run.finished) {
    $(".bar", view).style.strokeDashoffset = String(326.7 * (1 - (run.total ? run.done / run.total : 1)));
    $(".dz-added", view).textContent = run.added;
    $(".dz-current", view).textContent = run.current ? `Reading ${run.current}…` : "Finishing up…";
    $(".dz-count", view).textContent = `${run.done} of ${run.total} file${run.total === 1 ? "" : "s"}`;
    return;
  }
  if (run.celebrated) return;
  run.celebrated = true;
  $(".dz-summary", view).textContent = run.added === 0 ? "Nothing new to add" : run.added === 1 ? "Added 1 thing" : `Added ${run.added} things`;
  $(".done-mark", view).classList.toggle("none", run.added === 0);
  $(".done-mark", view).textContent = run.added ? "✓" : "?";
  $("#import-show").hidden = run.added === 0;
  const colors = ["#ff9f43", "#ff4f8b", "#a55eea", "#feca57", "#1dd1a1", "#54a0ff"];
  $(".burst", view).replaceChildren(...Array.from({ length: 14 }, (_, i) => {
    const angle = (i / 14) * 2 * Math.PI;
    const dot = h("i");
    dot.style.cssText = `background:${colors[i % colors.length]};--x:${Math.cos(angle) * 80}px;--y:${Math.sin(angle) * 80}px`;
    return dot;
  }));
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
  const folders = vault.folders();
  const now = Date.now();
  const liveFolders = new Set(folders.map((f) => f.id));
  const unfiled = items.filter((i) => !i.folder || !liveFolders.has(i.folder));
  const graph = linkGraph(items);
  const connected = items.filter((i) => graph.outgoing[i.id] || graph.incoming[i.id]).length;

  $("#smart-list").replaceChildren(...smartCollections.map((s) => {
    const count = items.filter((i) => s.contains(i, now)).length;
    if (!count && !["all", "notes", "pinned"].includes(s.id)) return null;
    return navLink(s.id, s.title, count);
  }).filter(Boolean), navLink("graph", "Connections", connected || ""), navLink("clips", "Clipboard", vault.clips().length),
  navLink("import", "Import", state.importRun && !state.importRun.finished ? state.importRun.total - state.importRun.done : ""));
  renderFolderNav(folders, items, unfiled);
  $("#collection-list").replaceChildren(...collections.map((c) => navLink(`c:${c.id}`, c.name, items.filter((i) => i.collections.includes(c.id)).length)));
  $("#collection-heading").hidden = !collections.length;
  const sources = [...new Set(items.flatMap((i) => i.sources))].filter((s) => s !== "app" && s !== "share")
    .sort((a, b) => sourceLabel(a).localeCompare(sourceLabel(b)));
  $("#source-list").replaceChildren(...sources.map((s) => navLink(`s:${s}`, sourceLabel(s), items.filter((i) => i.sources.includes(s)).length)));
  $("#source-heading").hidden = !sources.length;

  const mode = state.query.trim() && !["clips", "graph"].includes(state.selection) ? "items"
    : state.selection === "clips" ? "clips" : state.selection === "import" ? "import" : state.selection === "graph" ? "graph" : "items";
  $("#grid").classList.toggle("clip-list", mode === "clips");
  $("#capture").hidden = mode === "clips" || mode === "import" || mode === "graph";
  $("#import-view").hidden = mode !== "import";
  $("#graph-view").hidden = mode !== "graph";
  for (const id of ["#heading", "#grid"]) $(id).hidden = mode === "import" || mode === "graph";
  $("#folder-tiles").hidden = true;
  if (mode !== "graph" && graphView) { graphView.stop(); graphView = null; }
  if (mode !== "clips") $("#clip-tools")?.remove();
  if (mode !== "items") $("#clip-results")?.remove();
  $("#select-mode").hidden = mode !== "items";
  if (mode !== "items" && state.selecting) { state.selecting = false; state.picked = new Set(); renderBulkBar(); }
  if (mode === "import") { $("#empty").hidden = true; renderImport(); renderDetail(); return; }
  if (mode === "clips") { renderClips(); renderDetail(); return; }
  if (mode === "graph") { $("#empty").hidden = true; renderGraphView(items, folders); renderDetail(); return; }

  let shown;
  let title;
  const sel = state.selection;
  if (sel.startsWith("c:")) {
    const id = sel.slice(2);
    shown = items.filter((i) => i.collections.includes(id));
    title = collections.find((c) => c.id === id)?.name ?? "Collection";
  } else if (sel.startsWith("f:") && liveFolders.has(sel.slice(2))) {
    const id = sel.slice(2);
    // Searching looks inside subfolders too; browsing shows this folder's own things.
    const inside = state.query.trim() ? folderAndDescendants(id, folders) : new Set([id]);
    shown = items.filter((i) => inside.has(i.folder));
    title = folderHeading(id, folders, items);
    renderFolderTiles(id, folders, items);
  } else if (sel.startsWith("s:")) {
    const source = sel.slice(2);
    // Everything that came from here, including things that were already in Trove from elsewhere.
    shown = items.filter((i) => i.sources.includes(source));
    title = sourceLabel(source);
  } else if (sel === "unfiled") {
    shown = unfiled;
    title = h("div", { class: "heading-row" }, h("span", { text: "Unfiled" }),
      unfiled.length ? h("button", { type: "button", class: "secondary small", onclick: tidyUp }, "Tidy up: file everything") : null);
  } else {
    const smart = smartCollections.find((s) => s.id === sel) ?? smartCollections[0];
    shown = items.filter((i) => smart.contains(i, now));
    title = smart.title;
  }
  if (state.query.trim()) {
    shown = search(shown, state.query, now);
    title = `${shown.length} result${shown.length === 1 ? "" : "s"}`;
  }
  if (typeof title === "string") $("#heading").textContent = title; else $("#heading").replaceChildren(title);
  const folderNames = new Map(folders.map((f) => [f.id, f.name]));
  const inFolder = sel.startsWith("f:");
  state.shownIds = shown.slice(0, MAX_CARDS).map((i) => i.id);
  for (const id of state.picked) if (!vault.item(id)) state.picked.delete(id);
  renderBulkBar();
  $("#grid").replaceChildren(...shown.slice(0, MAX_CARDS).map((item) => card(item, inFolder ? null : folderNames.get(item.folder))));
  $("#empty").hidden = shown.length > 0 || (inFolder && !$("#folder-tiles").hidden);
  $("#empty").textContent = "Nothing here yet.";
  if (shown.length > MAX_CARDS) $("#grid").append(h("p", { class: "empty", text: `Showing the newest ${MAX_CARDS}. Search to find the rest.` }));
  $("#clip-results")?.remove();
  const fromClips = state.query.trim() && !sel.startsWith("f:") && !sel.startsWith("c:") ? clipResults(state.query) : null;
  if (fromClips) {
    fromClips.id = "clip-results";
    $("#grid").after(fromClips);
    $("#empty").hidden = true;
  }
  renderDetail();
}

// ---------- selecting several ----------

function setSelecting(on) {
  state.selecting = on;
  state.picked = new Set();
  state.anchor = null;
  render();
}

/** Adds or removes a card; with shift, everything between it and the last one picked. */
function pick(id, range) {
  if (!state.selecting) { state.selecting = true; state.picked = new Set(state.openId && state.openId !== id ? [state.openId] : []); }
  const ids = state.shownIds, a = ids.indexOf(state.anchor), b = ids.indexOf(id);
  if (range && a >= 0 && b >= 0) for (const x of ids.slice(Math.min(a, b), Math.max(a, b) + 1)) state.picked.add(x);
  else if (state.picked.has(id)) state.picked.delete(id);
  else state.picked.add(id);
  state.anchor = id;
  render();
}

function deletePicked() {
  const ids = [...state.picked];
  if (!ids.length || !confirm(`Delete ${ids.length} item${ids.length === 1 ? "" : "s"} on all your devices?`)) return;
  for (const id of ids) state.vault.delete(id);
  if (ids.includes(state.openId)) closeItem();
  toast(`Deleted ${ids.length} item${ids.length === 1 ? "" : "s"}`);
  setSelecting(false);
  syncSoon();
}

function renderBulkBar() {
  const bar = $("#bulk-bar");
  bar.hidden = !state.selecting;
  $("#select-mode").textContent = state.selecting ? "Done" : "Select";
  $("#select-mode").classList.toggle("primary", state.selecting);
  $("#select-mode").classList.toggle("secondary", !state.selecting);
  if (!state.selecting) { bar.replaceChildren(); return; }
  const vault = state.vault, ids = [...state.picked], n = ids.length;
  const all = state.shownIds.length > 0 && state.shownIds.every((id) => state.picked.has(id));
  const allPinned = n > 0 && ids.every((id) => vault.item(id)?.isPinned);
  const move = h("select", { class: "folder-select", "aria-label": "Move to folder", disabled: n ? null : true },
    h("option", { value: "__", text: "Move to…", disabled: true, selected: true }),
    h("option", { value: "", text: "No folder" }),
    folderTree(vault.folders()).map(({ folder, depth }) => h("option", { value: folder.id, text: `${" ".repeat(depth * 2)}${folder.name}` })));
  move.addEventListener("change", () => {
    const target = move.value || null;
    for (const id of ids) vault.moveItem(id, target);
    toast(target ? `Moved ${n} to ${vault.folders().find((f) => f.id === target)?.name}` : `Removed ${n} from their folders`);
    setSelecting(false);
    syncSoon();
  });
  bar.replaceChildren(
    h("span", { class: "bulk-count", text: n ? `${n} selected` : "Tap cards to select" }),
    h("button", { type: "button", class: "secondary small", onclick: () => { state.picked = all ? new Set() : new Set(state.shownIds); render(); } }, all ? "Select none" : "Select all"),
    move,
    h("button", { type: "button", class: "secondary small", disabled: n ? null : true, onclick: () => {
      for (const id of ids) vault.setPinned(id, !allPinned);
      setSelecting(false);
      syncSoon();
    } }, allPinned ? "Unpin" : "Pin"),
    h("button", { type: "button", class: "secondary small danger", disabled: n ? null : true, onclick: deletePicked }, "Delete"),
    h("button", { type: "button", class: "primary small", onclick: () => setSelecting(false) }, "Done"));
}

function navLink(id, title, count) {
  return h("a", {
    href: "#", "aria-current": state.selection === id ? "true" : "false",
    onclick: (e) => { e.preventDefault(); select(id); },
  }, h("span", { text: title }), h("span", { class: "count", text: count }));
}

function select(id) {
  state.selection = id;
  $(".sidebar").classList.remove("open");
  if (id.startsWith("f:")) for (const f of folderPathOf(id.slice(2), state.vault.folders()).slice(0, -1)) state.expanded.add(f.id);
  render();
  $(".main").scrollTop = 0;
}

// ---------- folders ----------

const FOLDER_DRAG = "application/x-trove-folder";

/** Accepts dropped cards (move the item) and dragged folders (move the folder) onto `el`. */
function folderDropTarget(el, folderId) {
  el.addEventListener("dragover", (e) => {
    const types = e.dataTransfer?.types ?? [];
    if (!types.includes(ITEM_DRAG) && !types.includes(FOLDER_DRAG)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    el.classList.add("drop-target");
  });
  el.addEventListener("dragleave", () => el.classList.remove("drop-target"));
  el.addEventListener("drop", (e) => {
    el.classList.remove("drop-target");
    const itemId = e.dataTransfer.getData(ITEM_DRAG), dragged = e.dataTransfer.getData(FOLDER_DRAG);
    if (!itemId && !dragged) return;
    e.preventDefault();
    const name = folderId ? state.vault.folders().find((f) => f.id === folderId)?.name : "the top level";
    if (itemId) { state.vault.moveItem(itemId, folderId); toast(`Moved to ${name}`); }
    else if (dragged !== folderId) {
      if (state.vault.moveFolder(dragged, folderId)) toast(`Moved into ${name}`); else toast("A folder can't go inside itself");
    }
    syncSoon();
  });
}

function folderCounts(folders, items) {
  const parent = new Map(folders.map((f) => [f.id, f.parent]));
  const total = new Map();
  for (const item of items) {
    const seen = new Set();
    for (let f = item.folder; f && parent.has(f) && !seen.has(f); f = parent.get(f)) { seen.add(f); total.set(f, (total.get(f) ?? 0) + 1); }
  }
  return total;
}

function renderFolderNav(folders, items, unfiled) {
  const counts = folderCounts(folders, items);
  const tree = folderTree(folders);
  const hasChildren = new Set(folders.map((f) => f.parent).filter(Boolean));
  const rows = [];
  const hiddenUnder = [];
  for (const { folder, depth } of tree) {
    while (hiddenUnder.length && hiddenUnder.at(-1) >= depth) hiddenUnder.pop();
    if (hiddenUnder.length) continue;
    const id = `f:${folder.id}`, open = state.expanded.has(folder.id);
    const toggle = hasChildren.has(folder.id)
      ? h("button", { type: "button", class: `disclosure${open ? " open" : ""}`, "aria-label": open ? "Collapse" : "Expand", "aria-expanded": String(open),
        onclick: (e) => { e.preventDefault(); e.stopPropagation(); open ? state.expanded.delete(folder.id) : state.expanded.add(folder.id); savePref("expanded", [...state.expanded]); render(); } }, "›")
      : h("span", { class: "disclosure-space" });
    const row = h("a", { href: "#", class: "folder-row", style: `--depth:${depth}`, draggable: "true", "aria-current": state.selection === id ? "true" : "false",
      onclick: (e) => { e.preventDefault(); select(id); } },
      toggle, h("span", { class: "folder-dot", style: `background:${folderColor(folderPathOf(folder.id, folders)[0]?.id, folders)}` }),
      h("span", { class: "folder-name", text: folder.name }), h("span", { class: "count", text: counts.get(folder.id) ?? "" }));
    row.addEventListener("dragstart", (e) => { e.dataTransfer.setData(FOLDER_DRAG, folder.id); e.dataTransfer.effectAllowed = "move"; });
    folderDropTarget(row, folder.id);
    rows.push(row);
    if (hasChildren.has(folder.id) && !open) hiddenUnder.push(depth);
  }
  if (unfiled.length) rows.push(navLink("unfiled", "Unfiled", unfiled.length));
  if (!folders.length && !unfiled.length) rows.push(h("p", { class: "side-note", text: "New things are filed into folders by themselves." }));
  $("#folder-list").replaceChildren(...rows);
}

function folderHeading(id, folders, items) {
  const path = folderPathOf(id, folders);
  const folder = path.at(-1);
  const crumbs = h("nav", { class: "crumbs", "aria-label": "Folder path" },
    path.map((f, i) => [i ? h("span", { class: "crumb-sep", "aria-hidden": "true", text: "›" }) : null,
      i === path.length - 1 ? h("span", { text: f.name }) : h("a", { href: "#", onclick: (e) => { e.preventDefault(); select(`f:${f.id}`); } }, f.name)]));
  const count = items.filter((i) => i.folder === id).length;
  const menu = h("div", { class: "folder-actions" },
    h("button", { type: "button", class: "secondary small", onclick: () => newFolder(id) }, "New folder"),
    h("button", { type: "button", class: "secondary small", onclick: () => {
      const name = prompt("Rename folder", folder.name);
      if (name?.trim()) { state.vault.renameFolder(id, name); syncSoon(); }
    } }, "Rename"),
    folder.parent ? h("button", { type: "button", class: "secondary small", onclick: () => { state.vault.moveFolder(id, null); toast("Moved to the top level"); syncSoon(); } }, "Move to top") : null,
    h("button", { type: "button", class: "secondary small danger", onclick: () => {
      if (!confirm(`Delete “${folder.name}”? ${count ? `Its ${count} item${count === 1 ? "" : "s"} and any folders inside move up a level. ` : ""}Nothing is deleted.`)) return;
      state.vault.deleteFolder(id);
      select(folder.parent ? `f:${folder.parent}` : "all");
      syncSoon();
    } }, "Delete folder"));
  return h("div", { class: "heading-row" }, crumbs, menu);
}

function renderFolderTiles(id, folders, items) {
  const counts = folderCounts(folders, items);
  const children = folders.filter((f) => f.parent === id).sort((a, b) => a.name.localeCompare(b.name));
  const el = $("#folder-tiles");
  el.hidden = !children.length;
  el.replaceChildren(...children.map((f) => {
    const tile = h("button", { type: "button", class: "folder-tile", onclick: () => select(`f:${f.id}`) },
      h("span", { class: "folder-icon", style: `--tint:${folderColor(folderPathOf(f.id, folders)[0]?.id, folders)}`, "aria-hidden": "true" }),
      h("span", { class: "folder-name", text: f.name }), h("span", { class: "count", text: counts.get(f.id) ?? 0 }));
    folderDropTarget(tile, f.id);
    return tile;
  }));
}

function newFolder(parent = null) {
  const name = prompt(parent ? "New folder inside this one" : "New folder");
  if (!name?.trim()) return;
  const id = state.vault.createFolder(name, parent);
  if (parent) state.expanded.add(parent);
  syncSoon();
  select(`f:${id}`);
}

function tidyUp() {
  const n = state.vault.tidyUp();
  toast(n ? `Filed ${n} thing${n === 1 ? "" : "s"} into folders` : "Everything is already filed");
  syncSoon();
}

// ---------- connections graph ----------

let graphView = null;

function renderGraphView(items, folders) {
  const opts = state.graphOpts;
  const data = buildGraph(items, folders, opts);
  const sig = `${data.nodes.length}/${data.edges.length}/${JSON.stringify(opts)}`;
  const toggles = [["tags", "Tags"], ["folderNodes", "Folders"], ["unlinked", "Unconnected items"]];
  $("#graph-tools").replaceChildren(
    h("div", { class: "chips", role: "group", "aria-label": "Show" }, toggles.map(([k, label]) =>
      h("button", { type: "button", "aria-pressed": String(Boolean(opts[k])), onclick: () => { opts[k] = !opts[k]; savePref("graph", opts); render(); } }, label))),
    h("div", { class: "legend" }, folders.filter((f) => !f.parent).sort((a, b) => a.name.localeCompare(b.name)).slice(0, 12).map((f) =>
      h("span", {}, h("i", { style: `background:${folderColor(f.id, folders)}` }), f.name))));
  $("#graph-count").textContent = data.nodes.length
    ? `${data.nodes.filter((n) => n.type === "item").length} items, ${data.edges.filter((e) => e.kind === "link").length} links`
    : "";
  const stage = $("#graph-stage");
  if (!data.nodes.length) {
    graphView?.stop(); graphView = null;
    stage.replaceChildren(h("div", { class: "graph-empty" }, h("p", { class: "dz-title", text: "No connections yet" }),
      h("p", { class: "hint", text: "Link notes by typing [[ and a title, or use “Connect to…” on any item. Shared #tags show up here too." })));
    return;
  }
  if (graphView?.sig === sig) return;
  graphView?.stop();
  graphView = graphCanvas(stage, data, { onOpen: (id) => { state.mode = null; openItem(id); } });
  graphView.sig = sig;
}

// ---------- clipboard history ----------

const clipFilters = [
  ["all", "All", () => true], ["pinned", "Pinned", (c) => c.isPinned], ["link", "Links", (c) => c.kind === "link"],
  ["image", "Images", (c) => c.kind === "image"], ["code", "Code", (c) => c.kind === "code" || c.kind === "json"],
  ["color", "Colors", (c) => c.kind === "color"], ["text", "Text", (c) => ["text", "email", "phone", "number", "path"].includes(c.kind)],
  ["other", "Other devices", (c) => c.device && c.device !== state.vault.config.deviceId],
];
const clipSymbol = { text: "¶", link: "🔗", email: "@", phone: "☎", color: "◐", code: "</>", json: "{ }", number: "#", path: "/", image: "▣", file: "▤" };

const autoSaveKinds = [["link", "Links"], ["image", "Images"], ["code", "Code"], ["text", "Text"], ["color", "Colours"]];

function renderClips() {
  const vault = state.vault;
  const filter = clipFilters.find(([id]) => id === state.clipFilter) ?? clipFilters[0];
  const q = state.query.trim();
  const all = vault.clips();
  const shown = all.filter((c) => filter[2](c) && clipMatches(c, q));
  const pinned = !q && state.clipFilter === "all" ? [...shown.filter((c) => c.isPinned), ...shown.filter((c) => !c.isPinned)] : shown;

  $("#heading").textContent = q ? `${shown.length} clip${shown.length === 1 ? "" : "s"}` : "Clipboard";
  let tools = $("#clip-tools");
  if (!tools) {
    tools = h("div", { id: "clip-tools", class: "clip-tools" },
      h("div", { class: "chips", role: "group", "aria-label": "Filter" }),
      h("div", { class: "row" },
        h("button", { type: "button", class: "primary", onclick: pasteFromClipboard }, "Paste"),
        h("span", { class: "hint", text: "…or press ⌘V / Ctrl+V anywhere on this page. Copies on your Mac show up here by themselves. Search with tag:, app: or is:pinned." })),
      h("details", { class: "clip-settings" }, h("summary", {}, "Save to Trove automatically"),
        h("p", { class: "hint", text: "Copies of these kinds go straight into your library, with where they came from. Applies on every device." }),
        h("div", { class: "chips", role: "group", "aria-label": "Save automatically" })));
    $("#heading").after(tools);
  }
  $(".chips", tools).replaceChildren(...clipFilters.map(([id, title]) =>
    h("button", { type: "button", "aria-pressed": String(state.clipFilter === id), onclick: () => { state.clipFilter = id; render(); } }, title)));
  const auto = vault.clipAutoSaveKinds();
  $(".clip-settings .chips", tools).replaceChildren(...autoSaveKinds.map(([kind, title]) => {
    const on = auto.includes(kind);
    return h("button", { type: "button", "aria-pressed": String(on), onclick: () => {
      vault.setClipAutoSave(on ? auto.filter((k) => k !== kind) : [...auto, kind]);
      syncSoon();
    } }, title);
  }));
  // Don't throw away what's being typed in an open clip when something syncs.
  const open = $("#grid .clip.open");
  if (open && open.contains(document.activeElement) && /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)) return;
  $("#grid").replaceChildren(...pinned.slice(0, 300).map(clipRow));
  $("#empty").hidden = pinned.length > 0;
  $("#empty").textContent = all.length ? "No clips match." : "Nothing copied yet. Copy something on your Mac, or paste here.";
}

/** Clips matching a search of the library, under the items. */
function clipResults(query) {
  const found = state.vault.clips().filter((c) => clipMatches(c, query));
  if (!found.length) return null;
  return h("section", { class: "clip-results" },
    h("h2", { class: "side-heading" }, h("button", { type: "button", class: "link-button", onclick: () => { state.selection = "clips"; render(); } },
      `From your clipboard (${found.length})`)),
    h("div", { class: "grid clip-list" }, found.slice(0, 8).map(clipRow)));
}

function clipRow(clip) {
  const open = state.openClip === clip.id;
  const c = clip.kind === "color" ? color(clip.text) : null;
  const badge = h("span", { class: "clip-badge", "aria-hidden": "true" }, c ? "" : clipSymbol[clip.kind] ?? "¶");
  if (c) badge.style.setProperty("background", `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${c.a})`);
  if (clip.image) blobURL(clip.image).then((url) => badge.replaceChildren(h("img", { src: url, alt: "" }))).catch(() => {});
  const where = clip.sourceTitle && clip.sourceTitle !== clip.sourceApp ? `${clip.sourceApp ?? ""} — ${clip.sourceTitle}`.replace(/^ — /, "") : clip.sourceApp;
  const meta = [where, clip.device !== state.vault.config.deviceId ? clip.sourceDevice : null, ago(clip.sortDate)].filter(Boolean).join(" · ");
  const snippet = clip.summary ?? (clip.kind === "image" ? clip.ocrText?.split("\n")[0] : clip.preview);
  const row = h("div", { class: `clip${open ? " open" : ""}`, "data-clip": clip.id },
    h("button", { type: "button", class: "clip-main", title: "Copy", onclick: () => copyClip(clip) },
      badge,
      h("span", { class: "clip-text" },
        h("span", { class: "clip-title", text: clip.displayTitle }),
        snippet && snippet !== clip.displayTitle ? h("span", { class: `clip-preview${["code", "json"].includes(clip.kind) ? " mono" : ""}`, text: snippet }) : null,
        h("span", { class: "clip-meta" }, meta, clip.tags.length ? h("span", { class: "clip-tags", text: clip.tags.map((t) => `#${t}`).join(" ") }) : null)),
      clip.isPinned ? h("span", { class: "pin", "aria-label": "Pinned", text: "●" }) : null),
    h("button", { type: "button", class: "icon-button clip-more", "aria-label": open ? "Less" : "More", "aria-expanded": String(open),
      onclick: () => { state.openClip = open ? null : clip.id; render(); } }, open ? "▴" : "▾"));
  if (open) row.append(clipDetails(clip, c));
  return row;
}

/** The open clip: rename, edit, tag and annotate it, and everything found in it. */
function clipDetails(clip, c) {
  const vault = state.vault;
  const save = (fn) => { fn(); syncSoon(); };
  const details = h("div", { class: "clip-details" });
  // Renders wait while you type here (renderClips); catch up when you leave.
  details.addEventListener("focusout", (e) => { if (!details.contains(e.relatedTarget)) queueRender(); });
  const blurOnEnter = (e) => { if (e.key === "Enter") e.target.blur(); };
  details.append(h("label", { class: "clip-field" }, h("span", { class: "hint", text: "Name" }),
    h("input", { type: "text", value: clip.title ?? "", placeholder: clip.aiTitle ?? clip.autoTitle ?? "Clip", "aria-label": "Name",
      onchange: (e) => save(() => vault.renameClip(clip.id, e.target.value)), onkeydown: blurOnEnter })));
  if (clip.summary) details.append(h("p", { class: "clip-summary", text: clip.summary }));

  if (clip.image) {
    const img = h("img", { alt: clip.image.name });
    blobURL(clip.image).then((url) => { img.src = url; }).catch(() => {});
    details.append(img);
    if (clip.ocrText) details.append(h("div", { class: "clip-ocr" }, h("span", { class: "hint", text: "Text in the image" }),
      h("pre", { text: clip.ocrText.slice(0, 20_000) }), h("div", { class: "row" }, h("button", { type: "button", class: "secondary small", onclick: () => copyText(clip.ocrText) }, "Copy text"))));
  } else if (c) {
    details.append(h("div", { class: "chips" }, colorFormats(c).map((f) => h("button", { type: "button", onclick: () => copyText(f) }, f))));
  } else if (clip.kind !== "file") {
    const area = h("textarea", { class: ["code", "json"].includes(clip.kind) ? "mono" : "", rows: String(Math.min(12, Math.max(3, clip.text.split("\n").length + 1))),
      "aria-label": "Text", spellcheck: "false" });
    area.value = clip.text.slice(0, 200_000);
    const saveText = h("button", { type: "button", class: "secondary small", hidden: true, onclick: () => {
      if (!area.value.trim()) { toast("A clip can't be empty"); return; }
      save(() => vault.editClip(clip.id, area.value));
      toast("Saved");
    } }, "Save text");
    area.addEventListener("input", () => { saveText.hidden = area.value === clip.text; });
    details.append(area, saveText);
    const transforms = availableTransforms(clip.text);
    if (transforms.length) details.append(h("div", { class: "chips" }, h("span", { class: "hint", text: "Copy as" }),
      transforms.map((t) => h("button", { type: "button", onclick: () => copyText(t.apply(clip.text), clip) }, t.title))));
  } else {
    details.append(h("pre", { text: clip.files.join("\n") }));
  }

  const e = clip.entities;
  if (e) {
    const found = [
      ...e.links.map((u) => h("a", { class: "chip-link", href: u, target: "_blank", rel: "noopener noreferrer", text: shortLink(u) })),
      ...e.emails.map((m) => h("a", { class: "chip-link", href: `mailto:${m}`, text: m })),
      ...e.phones.map((p) => h("a", { class: "chip-link", href: `tel:${p.replace(/[^\d+]/g, "")}`, text: p })),
      ...e.colors.map((col) => { const b = h("button", { type: "button", class: "chip-colour", onclick: () => copyText(col) }, h("span", { class: "swatch" }), col);
        b.firstChild.style.setProperty("background", col); return b; }),
    ];
    if (found.length && clip.kind !== "link" && clip.kind !== "color") details.append(h("div", { class: "chips found" }, h("span", { class: "hint", text: "Found" }), found));
  }

  details.append(h("label", { class: "clip-field" }, h("span", { class: "hint", text: "Tags" }),
    h("input", { type: "text", value: clip.tags.join(", "), placeholder: "work, ideas", "aria-label": "Tags",
      onchange: (ev) => save(() => vault.setClipTags(clip.id, ev.target.value.split(/[,\s]+/))), onkeydown: blurOnEnter })));
  const note = h("textarea", { rows: "2", placeholder: "Add a note…", "aria-label": "Note", onchange: (ev) => save(() => vault.setClipNote(clip.id, ev.target.value)) });
  note.value = clip.note;
  details.append(h("label", { class: "clip-field" }, h("span", { class: "hint", text: "Note" }), note));

  // Where and when it came from.
  const facts = [];
  if (clip.sourceApp) facts.push(["App", clip.sourceApp]);
  if (clip.sourceTitle) facts.push(["Window", clip.sourceTitle]);
  if (clip.sourceURL) facts.push(["Page", h("a", { href: clip.sourceURL, target: "_blank", rel: "noopener noreferrer", text: shortLink(clip.sourceURL) })]);
  facts.push(["Device", clip.sourceDevice ?? "Unknown"]);
  facts.push(["Copied", new Date(clip.createdAt).toLocaleString()]);
  if (clip.editedAt) facts.push(["Edited", new Date(clip.editedAt).toLocaleString()]);
  if (clip.uses) facts.push(["Used", `${clip.uses} more time${clip.uses === 1 ? "" : "s"}`]);
  if (clip.stats && clip.kind !== "image") facts.push(["Size", [[clip.stats.chars, "character"], [clip.stats.words, "word"], [clip.stats.lines, "line"]].map(([n, w]) => `${n.toLocaleString()} ${w}${n === 1 ? "" : "s"}`).join(" · ")]);
  if (clip.enrichment) facts.push(["Named by", ["Built-in rules", "Apple Intelligence", "Helper", "Cloud AI"][clip.enrichment.tier] ?? "AI"]);
  details.append(h("dl", { class: "clip-facts" }, facts.flatMap(([k, v]) => [h("dt", { text: k }), h("dd", {}, v)])));

  details.append(h("div", { class: "row" },
    h("button", { type: "button", class: "secondary", onclick: () => save(() => vault.setClipPinned(clip.id, !clip.isPinned)) }, clip.isPinned ? "Unpin" : "Pin"),
    clip.savedItem && vault.item(clip.savedItem)
      ? h("button", { type: "button", class: "secondary", onclick: () => { state.selection = "all"; state.query = ""; openItem(clip.savedItem); } }, "Open in Trove")
      : h("button", { type: "button", class: "secondary", onclick: async () => {
        try { await vault.saveClipToLibrary(clip.id); toast("Saved to Trove"); syncSoon(); } catch (err) { toast(`Couldn't save: ${err.message}`); }
      } }, "Save to Trove"),
    clip.kind === "link" ? h("a", { class: "secondary", href: clip.text.trim(), target: "_blank", rel: "noopener noreferrer" }, "Open") : null,
    h("button", { type: "button", class: "secondary danger", onclick: () => { vault.deleteClip(clip.id); state.openClip = null; syncSoon(); } }, "Delete")));
  return details;
}

function shortLink(u) {
  try { const x = new URL(u); return (x.host.replace(/^www\./, "") + x.pathname.replace(/\/$/, "")).slice(0, 60); } catch { return u.slice(0, 60); }
}

async function copyText(text, clip) {
  try {
    await navigator.clipboard.writeText(text);
    if (clip) { state.vault.markClipUsed(clip.id); syncSoon(); }
    toast("Copied");
  } catch {
    toast("Your browser blocked copying. Select the text and copy it instead.");
  }
}

async function copyClip(clip) {
  if (clip.image) {
    try {
      const blob = await (await fetch(await blobURL(clip.image))).blob();
      await navigator.clipboard.write([new ClipboardItem({ [blob.type || "image/png"]: blob })]);
      state.vault.markClipUsed(clip.id);
      syncSoon();
      toast("Image copied");
    } catch {
      toast("Your browser can't copy images here. Open it with ▾ instead.");
    }
    return;
  }
  await copyText(clip.text, clip);
}

/** Adds text or an image to the history (the web can't watch the clipboard, so you paste). */
async function addToClipboardHistory({ text, file }) {
  if (file && file.type.startsWith("image/")) {
    const id = await state.vault.addImageClip(new Uint8Array(await file.arrayBuffer()), file.type);
    await state.vault.autoSaveClip(id).catch(() => {});
    toast("Image added to your clipboard history");
  } else if (text && text.trim()) {
    if (isSensitive(text)) { toast("That looks like a password or code, so it wasn't saved"); return; }
    await state.vault.autoSaveClip(state.vault.addClip(text, { sourceApp: "Web" })).catch(() => {});
    toast("Added to your clipboard history");
  } else {
    return;
  }
  syncSoon();
}

async function pasteFromClipboard() {
  try {
    if (navigator.clipboard.read) {
      for (const entry of await navigator.clipboard.read()) {
        const imageType = entry.types.find((t) => t.startsWith("image/"));
        if (imageType) { await addToClipboardHistory({ file: new File([await entry.getType(imageType)], "image", { type: imageType }) }); return; }
      }
    }
    await addToClipboardHistory({ text: await navigator.clipboard.readText() });
  } catch {
    toast("Your browser didn't allow reading the clipboard. Press ⌘V / Ctrl+V instead.");
  }
}

const sourceLabels = { app: "Trove", share: "Share sheet", web: "Browser", email: "Email", goodnotes: "GoodNotes", kindle: "Kindle",
  readwise: "Readwise", obsidian: "Obsidian", appleNotes: "Apple Notes", notion: "Notion", screenshot: "Screenshots", voice: "Voice",
  scan: "Scan", import: "Import", clipboard: "Copied" };
const sourceLabel = (s) => sourceLabels[s] ?? s;
const kindLabel = { note: "Note", link: "Link", image: "Image", pdf: "PDF", audio: "Audio", video: "Video", file: "File", highlight: "Highlight", email: "Email", sketch: "Sketch" };

function card(item, folderName) {
  const snippet = item.kind === "highlight" ? item.body.replace(/^> /gm, "") : item.summary || item.body.trim() || item.ocrText || "";
  const price = item.priceWatch?.price ?? item.extracted.product?.price;
  const currency = item.priceWatch?.currency ?? item.extracted.product?.currency;
  const att = item.attachments[0];
  let thumb = null;
  if (item.thumbnail || (att && wantsThumbnail(att))) {
    thumb = h("div", { class: `thumb-wrap kind-${item.kind}`, "data-id": item.id }, h("span", { class: "type-tile", text: typeLabel(att?.name ?? "", att?.mime ?? "") }));
    thumbObserver.observe(thumb);
  } else if (item.imageURL?.startsWith("https://")) {
    thumb = h("img", { class: "thumb", src: item.imageURL, alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => e.target.remove() });
  } else if (att) {
    thumb = h("div", { class: `thumb-wrap small kind-${item.kind}` }, h("span", { class: "type-tile", text: typeLabel(att.name, att.mime) }));
  } else if (item.kind === "sketch") {
    thumb = h("div", { class: "thumb-wrap small kind-sketch" }, h("span", { class: "type-tile", text: "✎ Sketch" }));
  }
  const picked = state.picked.has(item.id);
  const el = h("button", { type: "button", class: `card ${item.kind}${picked ? " picked" : ""}${state.selecting ? " selecting" : ""}`, draggable: "true",
    "aria-pressed": state.selecting ? String(picked) : null,
    onclick: (e) => {
      if (state.selecting || e.metaKey || e.ctrlKey || e.shiftKey) { e.preventDefault(); pick(item.id, e.shiftKey); return; }
      state.mode = null; openItem(item.id);
    } },
    state.selecting ? h("span", { class: "pick-mark", "aria-hidden": "true", text: picked ? "✓" : "" }) : null,
    thumb,
    h("div", { class: "body" },
      h("div", { class: "meta" },
        item.isPinned ? h("span", { class: "pin", "aria-label": "Pinned", text: "●" }) : null,
        h("span", { text: [kindLabel[item.kind] ?? item.kind, item.siteName || item.url?.hostname.replace(/^www\./, ""), item.createdAt ? ago(item.createdAt) : null].filter(Boolean).join(" · ") }),
        item.hasConflicts ? h("span", { class: "danger", text: "· needs attention" }) : null),
      h("div", { class: "title", text: item.displayTitle }),
      snippet && snippet !== item.displayTitle ? h("div", { class: "snippet", text: snippet.slice(0, 400) }) : null,
      typeof price === "number" ? h("div", { class: "price", text: money(price, currency) }) : null,
      item.tags.length || folderName ? h("div", { class: "tags" }, folderName ? h("span", { class: "folder-chip", text: folderName }) : null,
        item.tags.slice(0, 4).map((t) => h("span", { class: "tag-chip", text: `#${t}` }))) : null));
  el.addEventListener("dragstart", (e) => {
    e.dataTransfer.setData(ITEM_DRAG, item.id);
    e.dataTransfer.setData("text/plain", item.displayTitle);
    e.dataTransfer.effectAllowed = "move";
  });
  return el;
}

// ---------- thumbnails (made once by whichever device sees the file first, then synced) ----------

const thumbTried = new Set();
let thumbQueue = Promise.resolve();
const thumbObserver = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { thumbObserver.unobserve(e.target); fillThumb(e.target); }
}, { rootMargin: "400px" });

async function fillThumb(el) {
  const item = state.vault?.item(el.dataset.id);
  if (!item) return;
  const show = (url) => { if (!el.isConnected) return; el.replaceChildren(h("img", { src: url, alt: "", class: "thumb" })); el.classList.add("loaded"); };
  if (item.thumbnail) { blobURL(item.thumbnail).then(show).catch(() => {}); return; }
  const att = item.attachments[0];
  if (!att || thumbTried.has(att.id)) return;
  thumbTried.add(att.id);
  thumbQueue = thumbQueue.then(async () => {
    try {
      const bytes = await state.vault.attachment(att.id);
      const jpeg = await makeThumbnail(att, bytes);
      if (!jpeg || !state.vault.item(item.id) || state.vault.item(item.id).attachments[0]?.id !== att.id) return;
      const thumb = await state.vault.setThumbnail(item.id, jpeg);
      blobURLs.set(thumb.id, URL.createObjectURL(new Blob([jpeg], { type: "image/jpeg" })));
      show(blobURLs.get(thumb.id));
      syncSoon(4000);
    } catch { /* no preview for this one */ }
  });
}

// ---------- detail ----------

const panelCache = { id: null, sig: null, previews: new Map() };

function openItem(id) {
  if (state.openId !== id) { state.history = false; panelCache.previews.clear(); panelCache.id = id; }
  state.openId = id;
  const item = state.vault.item(id);
  if (!state.mode) state.mode = item && item.kind === "note" && !item.body ? "edit" : "preview";
  renderDetail(true);
}

function closeItem() {
  flushBody();
  state.openId = null;
  state.mode = null;
  state.wide = false;
  panelCache.previews.clear();
  panelCache.sig = null;
  localGraph?.stop(); localGraph = null;
  $("#detail").hidden = true;
  $("#detail").classList.remove("wide");
  $("#detail").replaceChildren();
}

let localGraph = null;
let deviceNames = null;
function deviceName(id) {
  if (id === state.vault.journal.device) return "this browser";
  if (!deviceNames) {
    deviceNames = new Map();
    state.vault.api("GET", "devices").then(({ devices }) => { for (const d of devices) deviceNames.set(d.deviceId, d.name); panelCache.sig = null; renderDetail(); }).catch(() => {});
  }
  return deviceNames.get(id) ?? "another device";
}

function renderDetail(force = false) {
  const panel = $("#detail");
  if (!state.openId) { panel.hidden = true; return; }
  // Don't redraw under the user's cursor; their own edits are already in the store.
  if (!force && panel.contains(document.activeElement) && /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) return;
  const vault = state.vault;
  const item = vault.item(state.openId);
  if (!item) { closeItem(); return; }
  const items = vault.items();
  const graph = linkGraph(items);
  const inkSig = inkSignature(item);
  const sig = [item.id, item.record.updatedHLC, state.mode, state.history, state.wide, (graph.incoming[item.id] ?? []).join(), (graph.outgoing[item.id] ?? []).join(),
    vault.folders().length, items.length, inkSig].join("|");
  if (!force && sig === panelCache.sig) return;
  panelCache.sig = sig;
  panel.hidden = false;
  panel.classList.toggle("wide", state.wide);
  const scroll = panel.scrollTop;

  const bar = h("div", { class: "detail-bar" },
    h("button", { type: "button", class: "secondary", onclick: () => { vault.setPinned(item.id, !item.isPinned); syncSoon(); } }, item.isPinned ? "Unpin" : "Pin"),
    item.kind === "link" ? h("button", { type: "button", class: "secondary", onclick: () => { vault.markRead(item.id, item.readAt === null); syncSoon(); } }, item.readAt === null ? "Mark read" : "Mark unread") : null,
    h("span", { class: "spacer" }),
    h("button", { type: "button", class: "icon-button only-wide", "aria-label": state.wide ? "Narrow panel" : "Widen panel", title: state.wide ? "Narrow" : "Widen",
      onclick: toggleWide }, state.wide ? "⤡" : "⤢"),
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

  const parts = [bar, title, meta, folderPicker(item)];
  if (item.url) parts.push(h("a", { class: "url", href: item.url.toString(), target: "_blank", rel: "noopener noreferrer", text: item.url.toString() }));
  const origin = item.record.fields.origin;
  if (origin?.clip) {
    parts.push(h("p", { class: "copied-from" }, "Copied from ", [origin.app, origin.title].filter(Boolean).join(" — ") || "the clipboard",
      origin.url ? [" · ", h("a", { href: origin.url, target: "_blank", rel: "noopener noreferrer", text: shortLink(origin.url) })] : null));
  }
  if (item.summary) parts.push(h("p", { class: "summary", text: item.summary }));
  for (const version of item.conflictingVersions) {
    parts.push(h("div", { class: "conflict" },
      h("strong", { text: "Edited on two devices at once" }),
      h("p", { text: "Trove kept both. Pick the one to keep (you can edit it after)." }),
      h("pre", { text: version }),
      h("button", { type: "button", class: "secondary", onclick: () => { vault.resolveConflicts(item.id, version); syncSoon(); } }, "Keep this version"), " ",
      h("button", { type: "button", class: "secondary", onclick: () => { vault.resolveConflicts(item.id, item.body); syncSoon(); } }, "Keep the current text")));
  }

  if (item.kind === "sketch") parts.push(sketchSection(item));
  if (item.attachments.length) parts.push(filesSection(item));

  // Body: preview, edit or history.
  const hasFiles = item.attachments.length > 0;
  const segmented = h("div", { class: "segmented", role: "group", "aria-label": "Body view" },
    h("button", { type: "button", "aria-pressed": String(state.mode === "preview" && !state.history), onclick: () => { flushBody(); state.mode = "preview"; state.history = false; renderDetail(true); } }, "Preview"),
    h("button", { type: "button", "aria-pressed": String(state.mode === "edit" && !state.history), onclick: () => { state.mode = "edit"; state.history = false; renderDetail(true); $("#body-input")?.focus(); } }, "Edit"),
    h("button", { type: "button", "aria-pressed": String(state.history), onclick: () => { flushBody(); state.history = !state.history; renderDetail(true); } }, "History"));
  const saved = h("span", { class: "saved", id: "saved" });
  parts.push(h("section", {}, hasFiles ? h("h3", { class: "section-title", text: "Notes" }) : null, h("div", { class: "body-head" }, segmented, saved)));
  if (state.history) parts.push(historyView(item));
  else if (state.mode === "edit") parts.push(bodyEditor(item, saved));
  else {
    const preview = h("div", { class: "preview" });
    preview.innerHTML = item.body ? renderMarkdown(item.body) : `<p class="saved">${hasFiles ? "No notes yet. Use Edit to add some, and [[links]] to other things." : "No text yet."}</p>`; // escaped by renderMarkdown
    preview.addEventListener("click", (e) => {
      const tag = e.target.closest("a.tag"), wiki = e.target.closest("a.wikilink");
      if (tag) { e.preventDefault(); searchFor(`tag:${tag.dataset.tag.toLowerCase()}`); }
      if (wiki) { e.preventDefault(); openByTitle(wiki.dataset.target); }
    });
    parts.push(preview);
  }

  parts.push(connectionsSection(item, items, graph));

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
  localGraph?.stop(); localGraph = null;
  panel.replaceChildren(...parts);
  panel.scrollTop = scroll;
  const stage = $("#local-graph", panel);
  if (stage) {
    const data = buildGraph(items, vault.folders(), { tags: false, focus: item.id, depth: 2 });
    if (data.nodes.length > 1) localGraph = graphCanvas(stage, data, { focus: item.id, compact: true, onOpen: (id) => { if (id !== item.id) { flushBody(); state.mode = null; openItem(id); } } });
    else stage.parentElement.remove();
  }
}

function toggleWide() {
  state.wide = !state.wide;
  panelCache.previews.clear(); // pages re-render at the new width
  renderDetail(true);
}

// ---------- drawing ----------

/** Changes when the ink on an item changes, so its panel redraws. */
function inkSignature(item) {
  const vault = state.vault;
  const layers = vault.inkedLayers().get(item.id);
  if (!layers) return "";
  return [...layers].map((l) => `${l}:${vault.strokes(item.id, l).length}`).join(",");
}

/** A sketch's pages in the panel; click one to draw on it. */
function sketchSection(item) {
  const vault = state.vault;
  const grid = h("div", { class: `sketch-pages${item.infinite ? " endless" : ""}` });
  const specs = sketchPages(item);
  specs.forEach((spec, page) => {
    const canvas = h("canvas", { class: "sketch-page", "aria-label": item.infinite ? "Endless canvas" : `Page ${page + 1}` });
    const button = h("button", { type: "button", class: "sketch-page-button", title: "Draw on this page", onclick: () => openSketch(item.id, page) }, canvas,
      specs.length > 1 ? h("span", { class: "saved", text: `${page + 1}` }) : null);
    grid.append(button);
    requestAnimationFrame(() => renderSketchPage(canvas, vault, item, spec, Math.max(120, canvas.clientWidth || 300)));
  });
  return h("section", { class: "sketch" },
    h("div", { class: "file-head" },
      h("span", { class: "type-tile mini", text: "✎" }),
      h("span", { class: "file-name", text: item.infinite ? "Endless canvas" : `${item.sketchPages} page${item.sketchPages === 1 ? "" : "s"}` }),
      h("span", { class: "spacer" }),
      h("button", { type: "button", class: "primary small", onclick: () => openSketch(item.id, 0) }, "✎ Draw")),
    grid);
}

/** Opens a sketch in the drawing editor. */
function openSketch(id, page = 0, after = null) {
  const vault = state.vault;
  const item = vault.item(id);
  if (!item) return;
  openInkEditor({
    vault, itemId: id, title: item.displayTitle, sketch: true, startPage: page,
    changed: () => syncSoon(4000),
    onClose: async (edited) => {
      if (edited) {
        const current = vault.item(id);
        const jpeg = current && await sketchThumbnail(vault, current).catch(() => null);
        if (jpeg) { await vault.setThumbnail(id, jpeg).catch(() => {}); }
        syncSoon(500);
      }
      panelCache.sig = null;
      render();
      after?.();
    },
  });
}

/** Opens a PDF or image in the drawing editor; the ink goes on top, the file stays as it is. */
async function markUp(item, att) {
  const vault = state.vault;
  toast(`Opening ${att.name}…`);
  let pages;
  try { pages = await inkPages(att, await vault.attachment(att.id)); } catch (e) { toast(`Couldn't open ${att.name}: ${e.message}`); return; }
  openInkEditor({
    vault, itemId: item.id, layer: att.id, title: att.name, pages,
    changed: () => syncSoon(4000),
    onClose: () => { panelCache.sig = null; syncSoon(500); renderDetail(true); },
  });
}

function folderPicker(item) {
  const vault = state.vault, folders = vault.folders();
  const select = h("select", { class: "folder-select", "aria-label": "Folder" },
    h("option", { value: "", text: "No folder" }),
    folderTree(folders).map(({ folder, depth }) => h("option", { value: folder.id, selected: folder.id === item.folder ? true : null, text: `${" ".repeat(depth)}${folder.name}` })),
    h("option", { value: "__new", text: "New folder…" }));
  select.addEventListener("change", () => {
    let target = select.value || null;
    if (target === "__new") {
      const name = prompt("New folder");
      if (!name?.trim()) { select.value = item.folder ?? ""; return; }
      target = vault.createFolder(name, null);
    }
    vault.moveItem(item.id, target);
    toast(target ? `Moved to ${vault.folders().find((f) => f.id === target)?.name}` : "Removed from its folder");
    syncSoon();
  });
  const path = item.folder ? folderPathOf(item.folder, folders) : [];
  return h("div", { class: "folder-line" },
    h("span", { class: "folder-icon small", "aria-hidden": "true" }),
    path.length ? h("span", { class: "crumbs small" }, path.map((f, i) => [i ? h("span", { class: "crumb-sep", text: "›" }) : null,
      h("a", { href: "#", onclick: (e) => { e.preventDefault(); select_(f.id); } }, f.name)])) : h("span", { class: "saved", text: "Not in a folder" }),
    item.isAutoFiled ? h("span", { class: "saved", title: "Trove chose this folder. Move it and it stays where you put it.", text: "· filed automatically" }) : null,
    h("label", { class: "move-label" }, "Move", select));
}
const select_ = (folderId) => { if (matchMedia("(max-width: 760px)").matches) closeItem(); select(`f:${folderId}`); };

function filesSection(item) {
  const vault = state.vault;
  const section = h("section", { class: "files" });
  item.attachments.forEach((att, index) => {
    const upload = h("input", { type: "file", hidden: true });
    upload.addEventListener("change", async () => {
      const file = upload.files[0];
      if (!file) return;
      if (file.size > MAX_UPLOAD) { toast("That file is over 100 MB"); return; }
      toast("Uploading the new version…");
      try {
        await vault.replaceFile(item.id, new Uint8Array(await file.arrayBuffer()), { name: file.name, mime: file.type || att.mime });
        thumbTried.delete(att.id);
        toast("Saved as a new version. The old one is under Versions.");
        syncSoon();
      } catch (e) { toast(`Couldn't upload: ${e.message}`); }
    });
    const head = h("div", { class: "file-head" },
      h("span", { class: "type-tile mini", text: typeLabel(att.name, att.mime) }),
      h("span", { class: "file-name", text: att.name }), h("span", { class: "saved", text: fileSize(att.size) }),
      h("span", { class: "spacer" }),
      canInk(att) ? h("button", { type: "button", class: "secondary small", title: "Write or draw on this file. The file itself doesn't change.", onclick: () => markUp(item, att) }, "✎ Draw on it") : null,
      h("button", { type: "button", class: "secondary small", onclick: () => download(att) }, "Download"),
      index === 0 ? h("label", { class: "secondary small", title: "Upload an edited copy; the current file is kept as a version" }, "New version", upload) : null);
    const cacheKey = `${att.id}:${vault.strokes(item.id, att.id).length}`;
    let preview = panelCache.previews.get(cacheKey);
    if (!preview) {
      const editable = index === 0 && isEditableText(att.name, att.mime);
      preview = attachmentPreview(att, {
        load: () => vault.attachment(att.id),
        edit: editable ? async (bytes) => { await vault.replaceFile(item.id, bytes); syncSoon(); toast("Saved. The previous text is under Versions."); } : null,
        onExpand: state.wide ? null : toggleWide,
        eager: !att.size || att.size < 60e6 || index === 0 && att.size < 150e6,
        ink: canInk(att) ? (page) => vault.strokes(item.id, att.id, page) : null,
      });
      panelCache.previews.set(cacheKey, preview);
    }
    section.append(head, preview);
  });
  if (item.fileVersions.length) {
    const list = h("ul", { class: "versions" }, item.fileVersions.map((v) => h("li", {},
      h("span", { class: "version-when", text: ago(v.at) }),
      h("span", { class: "saved", text: [v.attachment.name !== item.attachments[0]?.name ? v.attachment.name : null, fileSize(v.attachment.size), v.by ? `replaced on ${deviceName(v.by)}` : null].filter(Boolean).join(" · ") }),
      h("span", { class: "spacer" }),
      h("button", { type: "button", class: "secondary small", onclick: () => openVersion(v.attachment) }, "Open"),
      h("button", { type: "button", class: "secondary small", onclick: () => {
        vault.restoreFileVersion(item.id, v);
        panelCache.previews.clear();
        toast("Restored. The file you had is kept as a version too.");
        syncSoon();
      } }, "Restore"))));
    section.append(h("details", { class: "versions-box" }, h("summary", {}, `Versions (${item.fileVersions.length} earlier)`), list));
  }
  return section;
}

async function download(att) {
  try {
    const a = h("a", { href: await blobURL(att), download: att.name });
    a.click();
  } catch (e) { toast(`Couldn't download: ${e.message}`); }
}

async function openVersion(att) {
  const kind = previewKind(att.name, att.mime);
  if (kind === "image") { try { lightbox(await blobURL(att), att.name); } catch (e) { toast(e.message); } return; }
  const box = h("div", { class: "dialog version-dialog", role: "dialog", "aria-modal": "true" },
    h("div", { class: "dialog-head" }, h("h2", { text: `${att.name} (earlier version)` }), h("button", { type: "button", class: "icon-button", "aria-label": "Close", onclick: () => backdrop.remove() }, "✕")),
    attachmentPreview(att, { load: () => state.vault.attachment(att.id) }));
  const backdrop = h("div", { class: "dialog-backdrop", onclick: (e) => { if (e.target === backdrop) backdrop.remove(); } }, box);
  backdrop.addEventListener("keydown", (e) => { if (e.key === "Escape") backdrop.remove(); });
  document.body.append(backdrop);
}

function historyView(item) {
  const versions = state.vault.textVersions(item.id);
  if (!versions.length) return h("p", { class: "saved", text: "No edits yet." });
  const pane = h("pre", { class: "history-text", text: versions[0].text });
  let chosen = 0;
  const restore = h("button", { type: "button", class: "primary small", disabled: true, onclick: () => {
    state.vault.setBody(item.id, versions[chosen].text);
    state.history = false;
    toast("Restored. Your newer text is still in History.");
    syncSoon();
    renderDetail(true);
  } }, "Restore this version");
  const list = h("ol", { class: "history-list" }, versions.map((v, i) => {
    const b = h("button", { type: "button", "aria-pressed": String(i === 0), onclick: () => {
      chosen = i;
      pane.textContent = v.text || "(empty)";
      restore.disabled = i === 0 || v.text === item.body;
      for (const x of list.querySelectorAll("button")) x.setAttribute("aria-pressed", String(x === b));
    } }, h("strong", { text: i === 0 ? "Latest" : ago(v.at) }), h("span", { class: "saved", text: `${new Date(v.at).toLocaleString()} · ${deviceName(v.device)}` }));
    return h("li", {}, b);
  }));
  return h("div", { class: "history" }, list, h("div", { class: "history-pane" }, pane, h("div", { class: "row" }, restore)));
}

function bodyEditor(item, saved) {
  const body = h("textarea", { class: "body-input", id: "body-input", "aria-label": "Note", placeholder: "Write in Markdown. #tags work, and [[ links to anything in your Trove." });
  body.value = item.body;
  body.dataset.id = item.id;
  const suggest = h("ul", { class: "suggest", role: "listbox", hidden: true });
  let options = [], active = 0;
  const close = () => { suggest.hidden = true; options = []; };
  const pick = (choice) => {
    const before = body.value.slice(0, body.selectionStart), after = body.value.slice(body.selectionEnd);
    const start = before.lastIndexOf("[[");
    const rest = after.startsWith("]]") ? after.slice(2) : after;
    body.value = `${before.slice(0, start)}[[${choice}]]${rest}`;
    const caret = start + choice.length + 4;
    body.setSelectionRange(caret, caret);
    close();
    body.dispatchEvent(new Event("input"));
  };
  const update = () => {
    const m = /\[\[([^[\]\n|#]*)$/.exec(body.value.slice(0, body.selectionStart));
    if (!m) { close(); return; }
    const q = m[1].trim().toLowerCase();
    options = state.vault.items().filter((i) => i.id !== item.id && i.displayTitle.toLowerCase().includes(q))
      .sort((a, b) => Number(!a.displayTitle.toLowerCase().startsWith(q)) - Number(!b.displayTitle.toLowerCase().startsWith(q)) || b.createdAt - a.createdAt)
      .slice(0, 7).map((i) => i.displayTitle);
    if (q && !options.some((o) => o.toLowerCase() === q)) options.push(m[1].trim());
    active = 0;
    suggest.hidden = !options.length;
    suggest.replaceChildren(...options.map((o, i) => h("li", { role: "option", "aria-selected": String(i === active), onmousedown: (e) => { e.preventDefault(); pick(o); } },
      i === options.length - 1 && q && !state.vault.items().some((x) => x.displayTitle.toLowerCase() === q) ? `New: ${o}` : o)));
  };
  body.addEventListener("input", () => {
    saved.textContent = "Editing…";
    clearTimeout(flushBody.timer);
    flushBody.timer = setTimeout(flushBody, 700);
    update();
  });
  body.addEventListener("keydown", (e) => {
    if (suggest.hidden) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      active = (active + (e.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
      [...suggest.children].forEach((li, i) => li.setAttribute("aria-selected", String(i === active)));
    } else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); pick(options[active]); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
  });
  body.addEventListener("blur", () => { setTimeout(close, 150); flushBody(); });
  return h("div", { class: "editor" }, body, suggest);
}

function connectionsSection(item, items, graph) {
  const vault = state.vault;
  const byId = new Map(items.map((i) => [i.id, i]));
  const out = (graph.outgoing[item.id] ?? []).map((id) => byId.get(id)).filter(Boolean);
  const inc = (graph.incoming[item.id] ?? []).map((id) => byId.get(id)).filter(Boolean);
  const linked = new Set(neighbours(graph, item.id));
  const mentioned = mentions(item, items, linked).slice(0, 8);
  const suggestions = related(item, items).filter((i) => !linked.has(i.id)).slice(0, 5);
  const unresolved = graph.unresolved[item.id] ?? [];
  const chip = (other, { remove, action } = {}) => h("span", { class: "link-chip" },
    h("a", { href: "#", onclick: (e) => { e.preventDefault(); flushBody(); state.mode = null; openItem(other.id); } }, other.displayTitle),
    action ?? null,
    remove ? h("button", { type: "button", class: "chip-x", "aria-label": `Disconnect ${other.displayTitle}`, onclick: () => { vault.disconnect(item.id, other.id); syncSoon(); } }, "×") : null);
  const manual = new Set(item.links);
  const group = (label, children) => (children.length ? h("div", { class: "link-group" }, h("span", { class: "link-label", text: label }), h("div", { class: "link-chips" }, children)) : null);
  const textLinks = new Set(wikilinks(item.body).map((t) => t.toLowerCase()));
  const section = h("section", { class: "connections" }, h("h3", { class: "section-title", text: "Connections" }),
    group("Links to", out.map((o) => chip(o, { remove: manual.has(o.id) && !textLinks.has(o.displayTitle.toLowerCase()) }))),
    group("Linked from", inc.map((o) => chip(o, { remove: o.links.includes(item.id) }))),
    group("Not made yet", unresolved.map((t) => h("button", { type: "button", class: "link-chip new", onclick: () => {
      const id = vault.addNote({ title: t });
      toast(`Made “${t}”`);
      syncSoon(); state.mode = "edit"; openItem(id);
    } }, `+ ${t}`))),
    group("Mentioned in", mentioned.map((o) => chip(o, { action: h("button", { type: "button", class: "chip-action", onclick: () => { vault.connect(o.id, item.id); syncSoon(); } }, "Link") }))),
    group("Maybe related", suggestions.map((o) => chip(o, { action: h("button", { type: "button", class: "chip-action", onclick: () => { vault.connect(item.id, o.id); syncSoon(); } }, "Connect") }))),
    connectPicker(item));
  if (out.length || inc.length) section.append(h("div", { class: "local-graph-wrap" }, h("div", { id: "local-graph", class: "local-graph" }),
    h("button", { type: "button", class: "link-button", onclick: () => select("graph") }, "Open the whole graph →")));
  return section;
}

function connectPicker(item) {
  const input = h("input", { type: "search", placeholder: "Connect to…", "aria-label": "Connect to another item", autocomplete: "off" });
  const results = h("ul", { class: "suggest inline", hidden: true });
  input.addEventListener("input", () => {
    const q = input.value.trim();
    const hits = q ? search(state.vault.items().filter((i) => i.id !== item.id && !item.links.includes(i.id)), q).slice(0, 6) : [];
    results.hidden = !hits.length;
    results.replaceChildren(...hits.map((hit) => h("li", { onmousedown: (e) => {
      e.preventDefault();
      input.value = ""; results.hidden = true;
      input.blur();
      state.vault.connect(item.id, hit.id);
      toast(`Connected to “${hit.displayTitle}”`);
      syncSoon();
    } }, h("strong", { text: hit.displayTitle }), h("span", { class: "saved", text: ` ${kindLabel[hit.kind] ?? hit.kind}` }))));
  });
  input.addEventListener("blur", () => setTimeout(() => { results.hidden = true; }, 150));
  return h("div", { class: "connect-picker" }, input, results);
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
  if (match) { flushBody(); state.mode = null; openItem(match.id); return; }
  if (confirm(`There's nothing called “${title}” yet. Make a note with that title?`)) {
    const id = state.vault.addNote({ title: title.trim() });
    syncSoon();
    state.mode = "edit";
    openItem(id);
  }
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
