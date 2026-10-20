// Clipboard history for the web app (docs/PROTOCOL.md §8). Kept in step with
// Packages/TroveCore/Sources/TroveCore/Clips/Clip.swift: same fields, hashes and classification.
import { cleanURL, hashtags } from "./items.js";
import { sha256Hex } from "./bytes.js";

export const ClipField = {
  text: "text", image: "image", files: "files", hash: "hash", sourceApp: "sourceApp", sourceDevice: "sourceDevice", device: "device",
  createdAt: "createdAt", lastUsedAt: "lastUsedAt", pinned: "pinned", savedItem: "savedItem",
  sourceURL: "sourceURL", sourceTitle: "sourceTitle", sourceBundle: "sourceBundle",
  autoTitle: "autoTitle", stats: "stats", entities: "entities", aiTitle: "aiTitle", summary: "summary", ocrText: "ocrText",
  enrichment: "enrichment", needsEnrichment: "needsEnrichment", title: "title", tags: "tags", note: "note", editedAt: "editedAt", uses: "uses",
};

// ---------- insights (ClipInsights.swift; both check Fixtures/clip-cases.json) ----------

const MAX_ENTITIES = 20, TITLE_LENGTH = 60;
const uniq = (list) => [...new Set(list)].slice(0, MAX_ENTITIES);
const trimPunctuation = (s) => s.replace(/[.,;:!?)\]}]+$/u, "");

/** A title, counts, and the links, emails, phones, colours and hashtags in copied text. */
export function insights(text, kind = classify(text)) {
  const trimmed = text.trim();
  return {
    autoTitle: autoTitle(trimmed, kind),
    chars: [...text].length,
    words: text.split(/\s+/u).filter(Boolean).length,
    lines: text ? text.split("\n").length : 0,
    links: uniq([...text.matchAll(/https?:\/\/[^\s<>"'`]+/g)].map((m) => trimPunctuation(m[0]))),
    emails: uniq([...text.matchAll(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)].map((m) => m[0])),
    phones: uniq([...text.matchAll(/\+?[0-9][0-9 ()\-.]{6,}[0-9]/g)].map((m) => m[0]).filter((p) => { const n = p.replace(/\D/g, "").length; return n >= 7 && n <= 15; })),
    colors: uniq([...text.matchAll(/#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z])/g)].map((m) => m[0].toLowerCase())),
    // A colour like #ff8800 isn't a hashtag.
    hashtags: uniq(hashtags(text).filter((t) => !/^(?:[0-9a-f]{3}|[0-9a-f]{6})$/.test(t))),
  };
}

function autoTitle(s, kind) {
  if (kind === "link") {
    try {
      const u = new URL(s);
      // Like Foundation's URL.path: decoded, without a trailing slash.
      let path = u.pathname.replace(/\/+$/, "");
      try { path = decodeURIComponent(path); } catch { /* keep it encoded */ }
      return clipTitle(u.host.replace(/^www\./, "") + path);
    } catch { return clipTitle(s); }
  }
  if (kind === "color") return "Colour " + s;
  if (kind === "path") return s.split("/").filter(Boolean).pop() ?? s;
  if (kind === "json") return "JSON";
  const line = s.split("\n").map((l) => l.trim()).find(Boolean) ?? "";
  return clipTitle(line.split(/\s+/u).filter(Boolean).join(" "));
}

/** At most 60 characters, cut at a word when there's one past the middle (ClipInsights.clip). */
function clipTitle(s) {
  const chars = [...s];
  if (chars.length <= TITLE_LENGTH) return s;
  let cut = chars.slice(0, TITLE_LENGTH).join("");
  const space = cut.lastIndexOf(" ");
  if (space >= 0 && [...cut.slice(0, space)].length > TITLE_LENGTH / 2) cut = cut.slice(0, space);
  return cut.trim() + "…";
}

/** The built-in rules' tags (ClipInsights.ruleTags): the kind, a link's site, code's language,
 * `contact` for text with an email or phone number, and the text's hashtags. */
export function ruleTags(text, kind = classify(text)) {
  const s = text.trim();
  const tags = [];
  const kindTag = { link: "link", email: "email", phone: "phone", color: "colour", json: "json", path: "path", code: "code" }[kind];
  if (kindTag) tags.push(kindTag);
  if (kind === "link") { try { const site = siteName(new URL(s).hostname); if (site) tags.push(site); } catch { /* not a URL */ } }
  if (kind === "code") { const language = codeLanguage(text); if (language) tags.push(language); }
  const found = insights(text, kind);
  if (kind === "text" && (found.emails.length || found.phones.length)) tags.push("contact");
  return uniq([...tags, ...found.hashtags]).slice(0, 8);
}

/** "github" for github.com, "bbc" for www.bbc.co.uk. */
export function siteName(host) {
  const labels = host.toLowerCase().split(".").filter(Boolean);
  const n = labels.length;
  if (n < 2) return null;
  if (n >= 3 && labels[n - 1].length === 2 && ["co", "com", "org", "net", "gov", "ac", "edu"].includes(labels[n - 2])) return labels[n - 3];
  return labels[n - 2];
}

function codeLanguage(code) {
  const has = (s) => code.includes(s);
  if (has("#include")) return "c";
  if (has("fn ") && has("let mut")) return "rust";
  if (has("func ") && (has("let ") || has("var ") || has("->"))) return "swift";
  if (has("def ") || (has("import ") && has("print("))) return "python";
  if (has("SELECT ") && has(" FROM ")) return "sql";
  if (has("</") || has("/>")) return "html";
  if (has("const ") || has("=>") || has("console.") || has("function ")) return "javascript";
  return null;
}

/** Insights as record fields. */
export function insightFields(ins) {
  return {
    [ClipField.autoTitle]: ins.autoTitle,
    [ClipField.stats]: { chars: ins.chars, words: ins.words, lines: ins.lines },
    [ClipField.entities]: { links: ins.links, emails: ins.emails, phones: ins.phones, colors: ins.colors, hashtags: ins.hashtags },
  };
}

export const cleanTags = (tags) => [...new Set(tags.map((t) => t.toLowerCase().replace(/#/g, "").trim()).filter(Boolean))];

export const hashText = (text) => "t:" + sha256Hex(text);
export const hashImageHex = (hexDigest) => "i:" + hexDigest;

const clipViews = new WeakMap(); // record → { hlc, clip }

/** A read-only view of a clip record (Clip.swift), made once per version of the record. */
export function clipView(record) {
  const cached = clipViews.get(record);
  if (cached && cached.hlc === record.updatedHLC) return cached.clip;
  const clip = makeClipView(record);
  clipViews.set(record, { hlc: record.updatedHLC, clip });
  return clip;
}

function makeClipView(record) {
  const f = record.fields;
  const text = typeof f.text === "string" ? f.text : "";
  const image = f.image && typeof f.image.id === "string" ? f.image : null;
  const files = Array.isArray(f.files) ? f.files.filter((x) => typeof x === "string") : [];
  const createdAt = typeof f.createdAt === "number" ? f.createdAt : 0;
  const lastUsedAt = typeof f.lastUsedAt === "number" ? f.lastUsedAt : createdAt;
  const kind = image ? "image" : files.length ? "file" : classify(text);
  const firstLine = text.split(/\r?\n/)[0]?.trim() ?? "";
  const str = (v) => (typeof v === "string" && v ? v : null);
  const list = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string") : []);
  const preview = kind === "image" ? image.name ?? "Image" : kind === "file" ? files.map((p) => p.split("/").pop()).join(", ") : firstLine.slice(0, 200);
  const auto = str(f.autoTitle) ?? (kind === "image" || kind === "file" ? "" : insights(text, kind).autoTitle);
  const title = str(f.title), aiTitle = str(f.aiTitle);
  const stats = f.stats && typeof f.stats === "object" ? f.stats : null, entities = f.entities && typeof f.entities === "object" ? f.entities : null;
  return {
    id: record.id, record, text, image, files, kind, createdAt, lastUsedAt, sortDate: Math.max(createdAt, lastUsedAt),
    hash: typeof f.hash === "string" ? f.hash : "",
    sourceApp: typeof f.sourceApp === "string" ? f.sourceApp : null,
    sourceDevice: typeof f.sourceDevice === "string" ? f.sourceDevice : null,
    device: typeof f.device === "string" ? f.device : null,
    isPinned: f.pinned === true,
    savedItem: typeof f.savedItem === "string" ? f.savedItem : null,
    preview,
    sourceURL: str(f.sourceURL), sourceTitle: str(f.sourceTitle), sourceBundle: str(f.sourceBundle),
    title, aiTitle, autoTitle: auto,
    displayTitle: title ?? aiTitle ?? (kind === "image" ? image.name ?? "Image" : kind === "file" ? preview : auto || "Clip"),
    summary: str(f.summary), ocrText: str(f.ocrText), tags: list(f.tags), note: typeof f.note === "string" ? f.note : "",
    editedAt: typeof f.editedAt === "number" ? f.editedAt : null, uses: typeof f.uses === "number" ? f.uses : 0,
    needsEnrichment: f.needsEnrichment === true, enrichment: f.enrichment && typeof f.enrichment === "object" ? f.enrichment : null,
    stats: stats ? { chars: stats.chars ?? 0, words: stats.words ?? 0, lines: stats.lines ?? 0 } : null,
    entities: entities ? { links: list(entities.links), emails: list(entities.emails), phones: list(entities.phones), colors: list(entities.colors), hashtags: list(entities.hashtags) } : null,
  };
}

/** Clip.matches: everything known about it; `tag:x` (or `#x`), `app:x` and `is:pinned` narrow it down. */
export function clipMatches(clip, query) {
  return clipQueryMatches(parseClipQuery(query), clip, clipSearchText(clip));
}

export const fold = (text) => text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();

const searchTexts = new WeakMap(); // clip view → folded text; views are made once per version (clipView)

/** Everything searchable about a clip in one folded string (Clip.searchText), worked out once per version. */
export function clipSearchText(clip) {
  let text = searchTexts.get(clip);
  if (text === undefined) {
    text = fold([clip.text, clip.displayTitle, clip.autoTitle, clip.note, clip.tags.join(" "), clip.files.join(" "), clip.aiTitle ?? "", clip.summary ?? "",
      clip.ocrText ?? "", clip.sourceApp ?? "", clip.sourceDevice ?? "", clip.sourceTitle ?? "", clip.sourceURL ?? "", clip.image?.name ?? ""].join("\n"));
    searchTexts.set(clip, text);
  }
  return text;
}

/** ClipQuery: free words (all must appear), `tag:x` / `#x`, `app:x`, `is:pinned`. */
export function parseClipQuery(query) {
  const q = { words: [], tags: [], apps: [], pinnedOnly: false };
  for (const w of query.split(/\s+/).filter(Boolean)) {
    const lower = w.toLowerCase();
    if (lower.startsWith("tag:") && lower.length > 4) q.tags.push(lower.slice(4).replace(/#/g, ""));
    else if (lower.startsWith("#") && lower.length > 1) q.tags.push(lower.slice(1));
    else if (lower.startsWith("app:") && lower.length > 4) q.apps.push(fold(w.slice(4)));
    else if (lower === "is:pinned") q.pinnedOnly = true;
    else q.words.push(fold(w));
  }
  return q;
}

export function clipQueryMatches(q, clip, haystack) {
  if (q.pinnedOnly && !clip.isPinned) return false;
  if (q.tags.some((t) => !clip.tags.includes(t))) return false;
  if (q.apps.length) { const app = fold(clip.sourceApp ?? ""); if (q.apps.some((a) => !app.includes(a))) return false; }
  return q.words.every((w) => haystack.includes(w));
}

// ---------- tags with colours (PROTOCOL.md §8, Library+Clips.swift) ----------

export const TAG_SETTINGS_ID = "settings.tags";
export const TAG_COLORS = ["red", "orange", "yellow", "green", "mint", "teal", "blue", "indigo", "purple", "pink", "brown", "gray"];

/** The `settings.tags` record's fields (tag → colour name) as a sorted list; removed tags (null) are skipped. */
export function customTagList(fields) {
  return Object.entries(fields ?? {})
    .filter(([name, color]) => !name.startsWith("_") && typeof color === "string")
    .map(([name, color]) => ({ name, color: TAG_COLORS.includes(color) ? color : "gray" }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
}

/** A tag name as stored: lowercase, no `#`, words joined with "-". */
export const cleanTagName = (name) => cleanTags([name.trim().split(/\s+/).join("-")])[0] ?? null;

export function classify(raw) {
  const s = raw.trim();
  if (!s) return "text";
  const oneLine = !s.includes("\n");
  if (oneLine && color(s)) return "color";
  if (oneLine && !/\s/.test(s)) {
    try {
      const u = new URL(s);
      if ((u.protocol === "http:" || u.protocol === "https:") && u.host) return "link";
    } catch { /* not a URL */ }
  }
  if (oneLine && /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(s)) return "email";
  if (oneLine && /^\+?[0-9][0-9 ()\-.]{6,}[0-9]$/.test(s) && s.replace(/\D/g, "").length >= 7) return "phone";
  if (oneLine && /^[-+]?[0-9]{1,3}(,?[0-9]{3})*(\.[0-9]+)?%?$/.test(s)) return "number";
  if (oneLine && /^(~|\/)\S*$/.test(s) && s.length > 1) return "path";
  if ((s.startsWith("{") && s.endsWith("}")) || (s.startsWith("[") && s.endsWith("]"))) {
    try { JSON.parse(s); return "json"; } catch { /* not JSON */ }
  }
  if (looksLikeCode(s)) return "code";
  return "text";
}

/** {r,g,b,a} in 0…1 for #rgb, #rrggbb, #rrggbbaa, rgb()/rgba(), hsl()/hsla(). */
export function color(raw) {
  const t = raw.trim().toLowerCase();
  let m = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(t);
  if (m) {
    let hex = m[1];
    if (hex.length === 3) hex = [...hex].map((c) => c + c).join("");
    const n = (i) => parseInt(hex.slice(i, i + 2), 16) / 255;
    return { r: n(0), g: n(2), b: n(4), a: hex.length === 8 ? n(6) : 1 };
  }
  m = /^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9.]+)\s*)?\)$/.exec(t);
  if (m && [m[1], m[2], m[3]].every((v) => Number(v) <= 255)) return { r: m[1] / 255, g: m[2] / 255, b: m[3] / 255, a: m[4] ? Number(m[4]) : 1 };
  m = /^hsla?\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%\s*(?:,\s*([0-9.]+)\s*)?\)$/.exec(t);
  if (m) {
    const [r, g, b] = hslToRgb(m[1] / 360, m[2] / 100, m[3] / 100);
    return { r, g, b, a: m[4] ? Number(m[4]) : 1 };
  }
  return null;
}

function hslToRgb(h, s, l) {
  if (s <= 0) return [l, l, l];
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
  const hue = (t) => {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return [hue(h + 1 / 3), hue(h), hue(h - 1 / 3)];
}

function looksLikeCode(s) {
  const lines = s.split(/\r?\n/);
  const signals = [";\n", "{\n", "}\n", "=>", "func ", "def ", "const ", "let ", "var ", "import ", "return ", "class ", "#include",
    "</", "/>", "SELECT ", "fn ", "console.", "print(", "&&", "||", "!=", "==="];
  const hits = signals.filter((x) => s.includes(x)).length;
  const indented = lines.filter((l) => l.startsWith("    ") || l.startsWith("\t")).length;
  const symbols = [...s].filter((c) => "{}();=<>[]".includes(c)).length / Math.max(s.length, 1);
  if (lines.length >= 2) return hits >= 2 || (indented >= 1 && hits >= 1) || symbols > 0.06;
  return hits >= 2 && symbols > 0.05;
}

/** Passwords, API keys, private keys and one-time codes: never added to the synced history. */
export function isSensitive(raw) {
  const s = raw.trim();
  if (!s || s.length > 4000) return false;
  if (s.includes("PRIVATE KEY-----")) return true;
  if (/\s/.test(s)) return false;
  if (s.length >= 4 && s.length <= 8 && /^[0-9]+$/.test(s)) return true;
  const prefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "xoxa-",
    "AKIA", "ASIA", "AIza", "ya29.", "glpat-", "npm_", "pypi-", "SG.", "shpat_", "cfut_", "eyJ"];
  if (s.length >= 16 && prefixes.some((p) => s.startsWith(p))) return true;
  if (s.includes("://")) { try { new URL(s); return false; } catch { /* not a URL */ } }
  // (Only for plain text: compact JSON, colors and paths mix character classes too. Words with
  // punctuation, like "Tuesday," or "Hello-World", and file names aren't passwords.)
  if (s.length >= 8 && s.length <= 64 && classify(s) === "text" && /\p{N}/u.test(s) && !/^[\w\- ]+\.[A-Za-z0-9]{2,4}$/.test(s)) {
    const classes = [/\p{Ll}/u, /\p{Lu}/u, /\p{N}/u, /[^\p{L}\p{N}]/u].filter((r) => r.test(s)).length;
    if (classes >= 3 && !s.includes("@") && !s.startsWith("/") && !s.startsWith("~")) return true;
  }
  if (s.length >= 24 && s.length <= 200 && entropy(s) > 4.0) return true;
  return false;
}

function entropy(s) {
  const counts = new Map();
  for (const c of s) counts.set(c, (counts.get(c) ?? 0) + 1);
  const n = [...s].length;
  let e = 0;
  for (const v of counts.values()) e -= (v / n) * Math.log2(v / n);
  return e;
}

export const transforms = [
  ["trimmed", "Trim whitespace", (t) => t.trim()],
  ["singleLine", "Join into one line", (t) => t.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).join(" ")],
  ["uppercase", "UPPERCASE", (t) => t.toUpperCase()],
  ["lowercase", "lowercase", (t) => t.toLowerCase()],
  ["titleCase", "Title Case", (t) => t.toLowerCase().replace(/(^|[^\p{L}\p{N}'])(\p{L})/gu, (_, a, b) => a + b.toUpperCase())],
  ["cleanLink", "Remove link tracking", (t) => (classify(t) === "link" ? cleanURL(t.trim()).toString() : null)],
  ["prettyJSON", "Pretty JSON", (t) => jsonOf(t, 2)],
  ["minifiedJSON", "Minify JSON", (t) => jsonOf(t, 0)],
].map(([id, title, apply]) => ({ id, title, apply }));

function jsonOf(text, indent) {
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" ? JSON.stringify(v, null, indent || undefined) : null;
  } catch {
    return null;
  }
}

export function availableTransforms(text) {
  return transforms.filter((t) => { const out = t.apply(text); return out !== null && out !== text; });
}

/** Hex, rgb() and hsl() strings for a color. */
export function colorFormats({ r, g, b, a }) {
  const R = Math.round(r * 255), G = Math.round(g * 255), B = Math.round(b * 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
  let h = 0, s = 0;
  if (d > 0) {
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    h /= 6;
  }
  const alpha = a < 1 ? `, ${a.toFixed(2)}` : "";
  const hex = "#" + [R, G, B].map((v) => v.toString(16).padStart(2, "0")).join("").toUpperCase();
  return [hex, `rgb${a < 1 ? "a" : ""}(${R}, ${G}, ${B}${alpha})`, `hsl${a < 1 ? "a" : ""}(${Math.round(h * 360)}, ${Math.round(s * 100)}%, ${Math.round(l * 100)}%${alpha})`];
}

// ---------- how much history to keep (PROTOCOL.md §8, ClipKeep in Library+Clips.swift) ----------

export const CLIP_KEEP_STANDARD = { days: 30, count: 1000 };
export const KEEP_DAY_CHOICES = [[7, "1 week"], [30, "1 month"], [90, "3 months"], [180, "6 months"], [365, "1 year"], [730, "2 years"], [0, "Forever"]];
export const KEEP_COUNT_CHOICES = [500, 1000, 5000, 10000, 50000, 0].map((n) => [n, n ? `${n.toLocaleString("en")} clips` : "No limit"]);
