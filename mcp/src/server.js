// The Model Context Protocol over stdio (JSON-RPC 2.0, one message per line), spoken directly so
// trove-mcp needs no dependencies. Tools read the local copy of the vault (synced from the relay)
// and write through the same ops every Trove device uses, so notes Claude makes sync everywhere.
import { search } from "../../web/public/core/items.js";
import { folderPathOf } from "../../web/public/core/organize.js";

export const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const VERSION = "0.1.0";
const SYNC_EVERY_MS = 30_000;
const MAX_BODY = 60_000;

const text = (value) => ({ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) });
const iso = (ms) => (ms ? new Date(ms).toISOString() : null);

class ToolError extends Error {}

/** Folder path from "A/B" or ["A", "B"]. */
function pathOf(folder) {
  const parts = Array.isArray(folder) ? folder : typeof folder === "string" ? folder.split("/") : [];
  return parts.map((p) => String(p).trim()).filter(Boolean).slice(0, 5);
}

function tagsOf(tags) {
  const raw = Array.isArray(tags) ? tags : typeof tags === "string" ? tags.split(/[,\s]+/) : [];
  return [...new Set(raw.map((t) => String(t).trim().replace(/^#/, "").toLowerCase()).filter(Boolean))];
}

const TOOLS = [
  {
    name: "search", title: "Search Trove", write: false,
    description: "Search the user's Trove (notes, saved links, files, highlights). Supports words and filters like tag:food, type:note, is:pinned. Returns the best matches with ids for read_item.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "What to look for" }, limit: { type: "integer", minimum: 1, maximum: 50, default: 10 } }, required: ["query"] },
  },
  {
    name: "read_item", title: "Read an item", write: false,
    description: "Read one Trove item in full: title, text, link, tags, folder, summary and any text found in its files or handwriting.",
    inputSchema: { type: "object", properties: { id: { type: "string", description: "The item id from search or list_recent" } }, required: ["id"] },
  },
  {
    name: "list_recent", title: "Recent items", write: false,
    description: "The most recently added Trove items, newest first. Optionally only one kind (note, link, pdf, image…) or one folder.",
    inputSchema: { type: "object", properties: { limit: { type: "integer", minimum: 1, maximum: 100, default: 20 }, kind: { type: "string" }, folder: { type: "string", description: "Folder path like Notes or Feeds/Tech" } } },
  },
  {
    name: "list_folders", title: "Folders", write: false,
    description: "Every folder in Trove as a path (like Documents/Spreadsheets) with how many items are directly inside.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "create_note", title: "Create a note", write: true,
    description: "Create a new note in the user's Trove. It syncs to all their devices. Markdown is fine, and [[Title]] links to other notes.",
    inputSchema: { type: "object", properties: { title: { type: "string" }, body: { type: "string", description: "The note's text (Markdown)" },
      folder: { type: "string", description: "Optional folder path like Notes/Ideas (made if missing)" }, tags: { type: "array", items: { type: "string" } } }, required: ["body"] },
  },
  {
    name: "save_link", title: "Save a link", write: true,
    description: "Save a web link to the user's Trove, with an optional note. The relay fetches its title and picture. A link already saved is not duplicated.",
    inputSchema: { type: "object", properties: { url: { type: "string" }, title: { type: "string" }, note: { type: "string" },
      folder: { type: "string" }, tags: { type: "array", items: { type: "string" } } }, required: ["url"] },
  },
];

export class TroveMCP {
  /** @param vault a web-core Vault; @param options {readOnly, log, now} */
  constructor(vault, { readOnly = false, log = () => {}, now = () => Date.now(), syncEvery = SYNC_EVERY_MS } = {}) {
    this.vault = vault;
    this.readOnly = readOnly;
    this.log = log;
    this.now = now;
    this.syncEvery = syncEvery;
    this.lastSync = 0;
    this.syncing = null;
  }

  get tools() { return TOOLS.filter((t) => !(this.readOnly && t.write)); }

  /** Pulls (and pushes) at most every 30 s; a failed sync leaves the local copy usable. */
  async freshen(force = false) {
    if (!force && this.now() - this.lastSync < this.syncEvery) return;
    this.syncing ??= this.vault.sync().then((report) => {
      this.lastSync = this.now();
      if (report.errors.length) this.log(`sync: ${report.errors.join("; ")}`);
    }, (e) => this.log(`sync failed: ${e.message}`)).finally(() => { this.syncing = null; });
    await this.syncing;
  }

  folderPath(id) {
    return id ? folderPathOf(id, this.vault.folders()).map((f) => f.name).join("/") : null;
  }

  summary(item, query = "") {
    return {
      id: item.id, title: item.displayTitle, kind: item.kind, url: item.url?.toString() ?? null, folder: this.folderPath(item.folder),
      tags: item.tags, createdAt: iso(item.createdAt), snippet: snippet(item, query),
    };
  }

  /** Handles one JSON-RPC message; returns the response object, or null for notifications. */
  async handle(message) {
    const { id, method, params } = message ?? {};
    const isRequest = id !== undefined && id !== null;
    try {
      const result = await this.dispatch(method, params ?? {});
      return isRequest ? { jsonrpc: "2.0", id, result } : null;
    } catch (e) {
      if (!isRequest) return null;
      const code = e.code ?? -32603;
      return { jsonrpc: "2.0", id, error: { code, message: e.message } };
    }
  }

  async dispatch(method, params) {
    switch (method) {
      case "initialize": {
        const asked = params.protocolVersion;
        return {
          protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "trove-mcp", title: "Trove", version: VERSION },
          instructions: "Trove is the user's private, end-to-end encrypted second brain: notes, saved links, files and highlights. " +
            "Use search and read_item to find what they've saved before answering from memory." +
            (this.readOnly ? " This connection is read-only." : " create_note and save_link add to it, and sync to all their devices."),
        };
      }
      case "notifications/initialized":
      case "notifications/cancelled":
        return {};
      case "ping":
        return {};
      case "tools/list":
        return { tools: this.tools.map(({ write, ...t }) => ({ ...t, annotations: { readOnlyHint: !write, destructiveHint: false, openWorldHint: false } })) };
      case "tools/call":
        return this.call(params.name, params.arguments ?? {});
      default: {
        const e = new Error(`method not found: ${method}`);
        e.code = -32601;
        throw e;
      }
    }
  }

  async call(name, args) {
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) {
      const e = new Error(`unknown tool: ${name}`);
      e.code = -32602;
      throw e;
    }
    if (tool.write && this.readOnly) return { content: [text("Trove is connected read-only, so it can't add anything.")], isError: true };
    try {
      await this.freshen();
      const result = await this[`tool_${name}`](args);
      return { content: [text(result)], structuredContent: result };
    } catch (e) {
      if (e instanceof ToolError) return { content: [text(e.message)], isError: true };
      throw e;
    }
  }

  // ---------- tools ----------

  tool_search({ query, limit = 10 }) {
    if (typeof query !== "string" || !query.trim()) throw new ToolError("query is required");
    const hits = search(this.vault.items(), query, this.now()).slice(0, clamp(limit, 1, 50, 10));
    return { query, count: hits.length, results: hits.map((i) => this.summary(i, query)) };
  }

  tool_read_item({ id }) {
    const item = typeof id === "string" ? this.vault.item(id) : null;
    if (!item) throw new ToolError(`No item with id ${id}.`);
    const body = item.body.length > MAX_BODY ? item.body.slice(0, MAX_BODY) + "\n…(cut)" : item.body;
    const out = {
      id: item.id, title: item.displayTitle, kind: item.kind, category: item.category, url: item.url?.toString() ?? null,
      folder: this.folderPath(item.folder), tags: item.tags, createdAt: iso(item.createdAt), source: item.source,
      summary: item.summary, body, siteName: item.siteName,
      attachments: item.attachments.map((a) => ({ name: a.name, mime: a.mime, size: a.size })),
    };
    for (const [key, value] of [["textInFiles", item.ocrText], ["handwriting", item.inkText ?? item.sketchText]]) if (value) out[key] = value.slice(0, MAX_BODY);
    return out;
  }

  tool_list_recent({ limit = 20, kind, folder }) {
    let items = this.vault.items();
    if (typeof kind === "string" && kind) items = items.filter((i) => i.kind === kind);
    if (folder !== undefined && folder !== "") {
      const want = pathOf(folder).join("/").toLowerCase();
      items = items.filter((i) => (this.folderPath(i.folder) ?? "").toLowerCase() === want);
    }
    return { count: Math.min(items.length, clamp(limit, 1, 100, 20)), items: items.slice(0, clamp(limit, 1, 100, 20)).map((i) => this.summary(i)) };
  }

  tool_list_folders() {
    const counts = new Map();
    for (const item of this.vault.items()) if (item.folder) counts.set(item.folder, (counts.get(item.folder) ?? 0) + 1);
    const folders = this.vault.folders().map((f) => ({ id: f.id, path: this.folderPath(f.id), items: counts.get(f.id) ?? 0 }));
    folders.sort((a, b) => a.path.localeCompare(b.path));
    return { count: folders.length, folders };
  }

  async tool_create_note({ title = "", body, folder, tags }) {
    if (typeof body !== "string" || !body.trim()) throw new ToolError("body is required");
    const path = pathOf(folder);
    const id = this.vault.addNote({ title: String(title ?? "").slice(0, 300), body, tags: tagsOf(tags), folder: path, source: "app" });
    if (path.length) this.vault.update(id, { folderAuto: false }); // asked for: enrichment won't move it
    await this.freshen(true);
    return { id, title: this.vault.item(id)?.displayTitle, folder: this.folderPath(this.vault.item(id)?.folder), synced: !this.vault.journal.pending.length };
  }

  async tool_save_link({ url, title = "", note = "", folder, tags }) {
    let parsed;
    try { parsed = new URL(String(url)); } catch { throw new ToolError("url must be a full http(s) link"); }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new ToolError("url must be a full http(s) link");
    const path = pathOf(folder);
    const { id, isNew } = this.vault.addLink(parsed.toString(), { title: String(title ?? ""), note: String(note ?? ""), source: "app", folder: path });
    const extra = {};
    if (isNew && path.length) extra.folderAuto = false;
    const wanted = tagsOf(tags);
    if (wanted.length) extra.tags = [...new Set([...(this.vault.item(id)?.tags ?? []), ...wanted])].sort();
    if (Object.keys(extra).length) this.vault.update(id, extra);
    if (isNew) await this.vault.fillLinkPreview(id).catch((e) => this.log(`preview: ${e.message}`));
    await this.freshen(true);
    const item = this.vault.item(id);
    return { id, isNew, title: item?.displayTitle, url: item?.url?.toString(), folder: this.folderPath(item?.folder), synced: !this.vault.journal.pending.length };
  }
}

function clamp(n, lo, hi, fallback) {
  const v = Number.isFinite(Number(n)) ? Math.round(Number(n)) : fallback;
  return Math.min(hi, Math.max(lo, v));
}

/** A short piece of the item's text around the first query word (or its start). */
export function snippet(item, query = "") {
  const source = [item.summary, item.body, item.ocrText].find((s) => s && s.trim()) ?? "";
  const flat = source.replace(/\s+/g, " ").trim();
  if (!flat) return "";
  const words = query.toLowerCase().split(/\s+/).filter((w) => w && !w.includes(":"));
  let at = -1;
  for (const w of words) { at = flat.toLowerCase().indexOf(w); if (at >= 0) break; }
  const start = Math.max(0, at - 60);
  const piece = flat.slice(start, start + 220);
  return (start > 0 ? "…" : "") + piece + (start + 220 < flat.length ? "…" : "");
}

/** Reads newline-delimited JSON-RPC from `input` and writes answers to `output` until input ends. */
export async function serveStdio(server, input = process.stdin, output = process.stdout) {
  const { createInterface } = await import("node:readline");
  const lines = createInterface({ input, crlfDelay: Infinity });
  const write = (msg) => output.write(JSON.stringify(msg) + "\n");
  const pending = new Set();
  for await (const line of lines) {
    if (!line.trim()) continue;
    let message;
    try { message = JSON.parse(line); } catch {
      write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
      continue;
    }
    const batch = Array.isArray(message) ? message : [message];
    const work = Promise.all(batch.map((m) => server.handle(m))).then((answers) => {
      const out = answers.filter(Boolean);
      if (out.length) write(Array.isArray(message) ? out : out[0]);
    });
    pending.add(work);
    work.finally(() => pending.delete(work));
  }
  await Promise.all(pending);
}
