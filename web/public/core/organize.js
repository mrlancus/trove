// Where new items are filed: a port of Organizer.swift (and Folder.tree / Folder.path). Both run
// Packages/TroveCore/Tests/TroveCoreTests/Fixtures/organize-cases.json.

export const FolderName = {
  notes: "Notes", highlights: "Highlights", email: "Email", receipts: "Receipts", recipes: "Recipes", shopping: "Shopping",
  places: "Places", videos: "Videos", events: "Events", reading: "Reading", links: "Links", code: "Code", bookmarks: "Bookmarks",
  documents: "Documents", spreadsheets: "Spreadsheets", presentations: "Presentations", handwritten: "Handwritten", images: "Images",
  screenshots: "Screenshots", scans: "Scans", audio: "Audio", voiceNotes: "Voice notes", files: "Files", appleNotes: "Apple Notes",
  sketches: "Sketches",
};
const N = FolderName;
const MAX_DEPTH = 5;

const set = (s) => new Set(s.split(" "));
const documentExts = set("pdf doc docx pages odt rtf txt md markdown epub tex html htm");
const spreadsheetExts = set("xls xlsx numbers ods csv tsv");
const presentationExts = set("ppt pptx key odp");
const codeExts = set("swift js mjs ts tsx jsx py rb go rs c h cpp hpp m java kt cs php sh zsh sql json yaml yml toml xml css scss ipynb");
const handwrittenExts = set("goodnotes note notability nbn");

const extOf = (name) => { const m = /\.([^./]+)$/.exec(name ?? ""); return m ? m[1].toLowerCase() : ""; };

/** The folder path for a new item. `importPath` (the folders it was dropped in or zipped in) wins. */
export function folderPath({ kind, category = null, source, fileName = null, collection = null, importPath = [] }) {
  const cleaned = cleanPath(importPath);
  if (cleaned.length) return cleaned;
  const ext = extOf(fileName);
  const group = collection ? cleanName(collection) || null : null;
  if (source === "goodnotes" || handwrittenExts.has(ext)) return [N.handwritten];
  if (category === "receipt") return [N.receipts];
  switch (kind) {
    case "note": return source === "appleNotes" ? [N.notes, N.appleNotes] : [N.notes];
    case "highlight": return group ? [N.highlights, group] : [N.highlights];
    case "email": return [N.email];
    case "sketch": return [N.sketches];
    case "link": {
      if (source === "import") return group ? [N.bookmarks, group] : [N.bookmarks];
      return [{ recipe: N.recipes, product: N.shopping, place: N.places, video: N.videos, event: N.events, article: N.reading, code: N.code }[category] ?? N.links];
    }
    case "image":
      if (source === "screenshot") return [N.images, N.screenshots];
      if (source === "scan") return [N.documents, N.scans];
      return [N.images];
    case "audio": return source === "voice" ? [N.audio, N.voiceNotes] : [N.audio];
    case "video": return [N.videos];
    case "pdf": return [N.documents];
    default:
      if (spreadsheetExts.has(ext)) return [N.documents, N.spreadsheets];
      if (presentationExts.has(ext)) return [N.documents, N.presentations];
      if (documentExts.has(ext)) return [N.documents];
      if (codeExts.has(ext)) return [N.code];
      return [N.files];
  }
}

/** Drops empty parts and export noise, collapses "Photos/Photos", caps the depth. */
export function cleanPath(path) {
  const out = [];
  for (const raw of path ?? []) {
    const part = cleanName(raw);
    if (!part) continue;
    if (out.length && out.at(-1).localeCompare(part, undefined, { sensitivity: "accent" }) === 0) continue;
    out.push(part);
  }
  return out.slice(0, MAX_DEPTH);
}

export function cleanName(name) {
  let s = String(name ?? "").replace(/\//g, "-").trim();
  if (/^Export-[0-9a-fA-F-]{36}$/.test(s)) return "Notion";
  s = s.replace(/\s+[0-9a-f]{32}$/, "");
  if (s.startsWith(".") || s === "__MACOSX") return "";
  return [...s].slice(0, 80).join("").trim();
}

/** A folder's id from its parent and name, so devices filing at once make the same record. */
export function folderId(parent, name) {
  const part = cleanName(name).toLowerCase();
  return parent ? `${parent}/${part}` : `folder:${part}`;
}

/** [{folder, depth}] in display order (children sorted by name); orphans at the top, cycles broken. */
export function folderTree(folders) {
  const ids = new Set(folders.map((f) => f.id));
  const children = new Map();
  for (const f of folders) {
    const key = f.parent && ids.has(f.parent) && f.parent !== f.id ? f.parent : "";
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(f);
  }
  const out = [], seen = new Set();
  const walk = (key, depth) => {
    for (const f of (children.get(key) ?? []).sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))) {
      if (seen.has(f.id)) continue;
      seen.add(f.id);
      out.push({ folder: f, depth });
      walk(f.id, depth + 1);
    }
  };
  walk("", 0);
  for (const f of folders) if (!seen.has(f.id)) { seen.add(f.id); out.push({ folder: f, depth: 0 }); walk(f.id, 1); }
  return out;
}

/** The folders from the top down to `id`. */
export function folderPathOf(id, folders) {
  const byId = new Map(folders.map((f) => [f.id, f]));
  const out = [];
  for (let f = byId.get(id); f && !out.includes(f); f = f.parent ? byId.get(f.parent) : null) out.unshift(f);
  return out;
}

/** Every folder inside `id` (any depth), including itself. */
export function folderAndDescendants(id, folders) {
  const out = new Set([id]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const f of folders) if (f.parent && out.has(f.parent) && !out.has(f.id)) { out.add(f.id); grew = true; }
  }
  return out;
}
