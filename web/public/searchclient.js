// The page's side of search: keeps the search Worker's index in step with the vault (small diffs,
// once per change of the vault, never per keystroke) and asks it questions. Answers come back a few
// milliseconds later; until then the last answer stays on screen.
import { clipView } from "./core/clips.js";
import { clipDoc, itemDoc } from "./core/search.js";
import { SearchService } from "./core/searchservice.js";

/** From this many clips on, clips are searched with the index instead of scanning their text. */
export const CLIP_INDEX_MIN = 20_000;

export class SearchClient {
  constructor(vault, onAnswer) {
    this.vault = vault;
    this.onAnswer = onAnswer;
    this.ready = false;
    this.sent = { items: new Map(), clips: new Map() };
    this.folderSig = "";
    this.dataSeen = -1;
    this.docsVersion = 0;
    this.scopeKey = null;
    this.seq = 0;
    this.asked = "";
    this.answer = null;     // { key, seq, items, clips }
    this.clipsIndexed = false;
    this.semantic = { on: false, ready: false, error: null };
    try {
      this.worker = new Worker(new URL("./search-worker.js", import.meta.url), { type: "module" });
      this.worker.onmessage = (e) => this.receive(e.data);
      this.worker.onerror = () => this.fallBack();
    } catch {
      this.fallBack();
    }
    this.post({ type: "init", vaultId: vault.config.vaultId });
    addEventListener("pagehide", () => this.post({ type: "save" }));
  }

  /** No Worker (or it failed to start): the same service on this thread, without saving. */
  fallBack() {
    if (this.local) return;
    this.worker?.terminate();
    this.worker = null;
    const service = new SearchService();
    let chain = Promise.resolve();
    this.local = (msg) => {
      chain = chain.then(async () => {
        if (msg.type === "init") this.receive({ type: "ready", ...(await service.init(msg.vaultId)) });
        else if (msg.type === "apply") service.apply(msg);
        else if (msg.type === "scope") service.setScope(msg.key, msg.ids);
        else if (msg.type === "query" && msg.seq === this.seq) this.receive({ type: "result", seq: msg.seq, ...(await service.query(msg)) });
      });
    };
    // Start again from nothing.
    this.ready = false;
    this.sent = { items: new Map(), clips: new Map() };
    this.dataSeen = -1;
    this.asked = "";
    this.local({ type: "init", vaultId: this.vault.config.vaultId });
  }

  post(msg) { if (this.worker) this.worker.postMessage(msg); else this.local?.(msg); }

  receive(msg) {
    if (msg.type === "ready") {
      this.sent = { items: new Map(msg.items), clips: new Map(msg.clips) };
      this.ready = true;
      this.onAnswer();
    } else if (msg.type === "result") {
      if (msg.seq !== this.seq) return; // an older question
      this.answer = { key: this.asked, seq: msg.seq, items: msg.items, clips: msg.clips };
      this.onAnswer();
    } else if (msg.type === "semantic") {
      this.semantic.ready = msg.ready;
      this.semantic.error = msg.error ?? null;
      this.onAnswer();
    }
  }

  /** Sends what changed since last time. `dataVersion` moves on with every change to the vault. */
  catchUp(dataVersion, items, folders) {
    if (!this.ready || dataVersion === this.dataSeen) return;
    this.dataSeen = dataVersion;
    const ink = this.vault.store?.inkByItem;
    const diff = (sent, list, makeDoc, sigOf) => {
      const docs = [], live = new Set();
      for (const x of list) {
        live.add(x.id);
        const sig = sigOf(x);
        if (sent.get(x.id) !== sig) { docs.push({ ...makeDoc(x), v: sig }); sent.set(x.id, sig); }
      }
      const removed = [];
      for (const id of sent.keys()) if (!live.has(id)) removed.push(id);
      for (const id of removed) sent.delete(id);
      return { docs, removed };
    };
    const inked = (id) => (ink?.get(id)?.size ?? 0) > 0;
    const itemDiff = diff(this.sent.items, items, (i) => itemDoc(i, { inked: inked(i.id) }), (i) => `${i.record.updatedHLC ?? ""}${inked(i.id) ? "+ink" : ""}`);
    const folderSig = folders.map((f) => `${f.id}/${f.name}/${f.parent ?? ""}`).join("|");
    const foldersChanged = folderSig !== this.folderSig;
    this.folderSig = folderSig;
    if (itemDiff.docs.length || itemDiff.removed.length || foldersChanged) {
      this.post({ type: "apply", index: "items", ...itemDiff, folders: foldersChanged ? folders.map(({ id, name, parent }) => ({ id, name, parent })) : undefined });
      this.docsVersion++;
    }
    const clipRecords = this.vault.store?.visibleOf("clip") ?? [];
    this.clipsIndexed = clipRecords.length >= CLIP_INDEX_MIN;
    if (this.clipsIndexed || this.sent.clips.size) {
      const clips = this.clipsIndexed ? clipRecords.map(clipView) : [];
      const clipDiff = diff(this.sent.clips, clips, clipDoc, (c) => c.record.updatedHLC ?? "");
      if (clipDiff.docs.length || clipDiff.removed.length) { this.post({ type: "apply", index: "clips", ...clipDiff }); this.docsVersion++; }
    }
  }

  /**
   * Asks for `text` among `scopeIds` (null: everything) and returns the newest answer there is, mapped
   * to item views (possibly for an earlier question while the new one is on its way), or null.
   */
  ask(text, scopeKey, scopeIds, { clips = false, clipLimit = 8 } = {}) {
    if (scopeKey !== this.scopeKey || this.scopeVersion !== this.docsVersion) {
      this.scopeKey = scopeKey;
      this.scopeVersion = this.docsVersion;
      // Ids are worked out (and sent) only when the place searched in or the vault changed.
      this.post({ type: "scope", key: scopeKey, ids: typeof scopeIds === "function" ? scopeIds() : scopeIds });
    }
    const withClips = clips && this.clipsIndexed;
    const key = `${text}\u0000${scopeKey}\u0000${this.docsVersion}\u0000${withClips}\u0000${clipLimit}\u0000${this.semantic.ready && this.semantic.on}`;
    if (this.ready && key !== this.asked) {
      this.asked = key;
      this.post({ type: "query", seq: ++this.seq, text, scope: scopeIds ? scopeKey : null, clips: withClips, clipLimit, semantic: this.semantic.on });
    }
    const a = this.answer;
    if (!a) return null;
    const vault = this.vault;
    return {
      fresh: a.key === this.asked,
      items: a.items.ids.map((id) => vault.item(id)).filter(Boolean),
      total: a.items.total,
      snippets: a.items.snippets,
      clips: a.clips ? { list: a.clips.ids.map((id) => vault.clip(id)).filter(Boolean), total: a.clips.total } : null,
    };
  }

  /** Not searching: catch up when the page is idle, so the index is warm before the first letter. */
  idle(dataVersion, items, folders) {
    if (!this.ready || dataVersion === this.dataSeen || this.idleQueued) return;
    this.idleQueued = true;
    const run = () => { this.idleQueued = false; this.catchUp(dataVersion, items, folders); };
    if (typeof requestIdleCallback === "function") requestIdleCallback(run, { timeout: 2000 }); else setTimeout(run, 200);
  }

  setSemantic(on) {
    this.semantic.on = on;
    this.post({ type: "semantic", enabled: on });
  }
}

const SNIPPET_LABEL = { ink: "Handwriting", sketch: "On the sketch" };

/** Shows a search result's matching passage (bold words) in its card instead of the usual preview. */
export function showSnippet(el, s, item, h) {
  const key = s ? `${s.field}|${s.text}|${s.ranges.join(";")}` : "";
  if ((el._snipKey ?? "") === key) return el;
  if (el._plain === undefined) el._plain = el.querySelector(".body .snippet:not(.found)");
  el.querySelector(".body .snippet.found")?.remove();
  el._snipKey = key;
  if (el._plain) el._plain.hidden = Boolean(s);
  if (!s) return el;
  const parts = [];
  let at = 0;
  for (const [a, b] of s.ranges) {
    if (a > at) parts.push(s.text.slice(at, a));
    parts.push(h("b", { text: s.text.slice(a, b) }));
    at = b;
  }
  parts.push(s.text.slice(at));
  const label = s.field === "ocr" ? (item.kind === "image" ? "In the picture" : "In the file") : SNIPPET_LABEL[s.field];
  const node = h("div", { class: "snippet found" }, label ? h("span", { class: "snippet-label", text: `${label}: ` }) : null, parts);
  el.querySelector(".body .title")?.after(node);
  return el;
}
