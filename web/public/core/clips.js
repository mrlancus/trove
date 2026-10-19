// Clipboard history for the web app (docs/PROTOCOL.md §8). Kept in step with
// Packages/TroveCore/Sources/TroveCore/Clips/Clip.swift: same fields, hashes and classification.
import { cleanURL } from "./items.js";
import { sha256Hex } from "./bytes.js";

export const ClipField = {
  text: "text", image: "image", files: "files", hash: "hash", sourceApp: "sourceApp", sourceDevice: "sourceDevice", device: "device",
  createdAt: "createdAt", lastUsedAt: "lastUsedAt", pinned: "pinned", savedItem: "savedItem",
};

export const hashText = (text) => "t:" + sha256Hex(text);
export const hashImageHex = (hexDigest) => "i:" + hexDigest;

export function clipView(record) {
  const f = record.fields;
  const text = typeof f.text === "string" ? f.text : "";
  const image = f.image && typeof f.image.id === "string" ? f.image : null;
  const files = Array.isArray(f.files) ? f.files.filter((x) => typeof x === "string") : [];
  const createdAt = typeof f.createdAt === "number" ? f.createdAt : 0;
  const lastUsedAt = typeof f.lastUsedAt === "number" ? f.lastUsedAt : createdAt;
  const kind = image ? "image" : files.length ? "file" : classify(text);
  const firstLine = text.split(/\r?\n/)[0]?.trim() ?? "";
  return {
    id: record.id, record, text, image, files, kind, createdAt, lastUsedAt, sortDate: Math.max(createdAt, lastUsedAt),
    hash: typeof f.hash === "string" ? f.hash : "",
    sourceApp: typeof f.sourceApp === "string" ? f.sourceApp : null,
    sourceDevice: typeof f.sourceDevice === "string" ? f.sourceDevice : null,
    device: typeof f.device === "string" ? f.device : null,
    isPinned: f.pinned === true,
    savedItem: typeof f.savedItem === "string" ? f.savedItem : null,
    preview: kind === "image" ? image.name ?? "Image" : kind === "file" ? files.map((p) => p.split("/").pop()).join(", ") : firstLine.slice(0, 200),
  };
}

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
  // (Only for plain text: compact JSON, colors and paths mix character classes too.)
  if (s.length >= 8 && s.length <= 64 && classify(s) === "text") {
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
