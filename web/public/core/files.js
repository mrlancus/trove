// Reading files for previews: what kind of viewer a file gets, and the readable parts of the zip-based
// formats (GoodNotes, Word, Excel, PowerPoint, Pages/Keynote/Numbers). Pure, so it's tested in node.
import { readZip } from "./importer.js";

const ext = (name) => /\.([^./]+)$/.exec(name ?? "")?.[1]?.toLowerCase() ?? "";
const TEXT_EXTS = new Set(["txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "log", "ini", "css", "html", "htm", "js", "mjs",
  "ts", "tsx", "jsx", "py", "rb", "go", "rs", "swift", "c", "h", "cpp", "hpp", "m", "java", "kt", "cs", "php", "sh", "zsh", "sql", "tex", "srt", "vtt"]);

/**
 * Which viewer a file gets: image, pdf, audio, video, text, csv, docx, xlsx, pptx, iwork, goodnotes or other.
 */
export function previewKind(name, mime = "") {
  const e = ext(name);
  if (e === "goodnotes") return "goodnotes";
  if (e === "docx") return "docx";
  if (e === "xlsx") return "xlsx";
  if (e === "pptx") return "pptx";
  if (["pages", "key", "numbers"].includes(e)) return "iwork";
  if (mime === "application/pdf" || e === "pdf") return "pdf";
  if (e === "csv" || e === "tsv" || mime === "text/csv") return "csv";
  if (mime.startsWith("image/") || ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "avif", "bmp"].includes(e)) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  if (mime.startsWith("text/") || mime === "application/json" || TEXT_EXTS.has(e)) return "text";
  return "other";
}

/** Text-like files can be edited in place (each save is a new version). */
export const isEditableText = (name, mime) => ["text", "csv"].includes(previewKind(name, mime));

/** A short label for file-type badges: "PDF", "DOCX", "GOODNOTES"… */
export function typeLabel(name, mime = "") {
  const e = ext(name);
  if (e) return e.toUpperCase().slice(0, 9);
  return (mime.split("/")[1] ?? "FILE").toUpperCase().slice(0, 9);
}

/** Sniffs what some bytes are, for files without a useful name. */
export function sniff(bytes) {
  if (bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46) return "application/pdf";
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "image/png";
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return "image/jpeg";
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return "image/gif";
  return null;
}

const decoder = new TextDecoder();
async function entryText(zip, path) {
  const e = zip.entries.find((x) => x.path === path);
  return e ? decoder.decode(await zip.data(e)) : null;
}

export function xmlText(s) {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, "&");
}

/**
 * A GoodNotes notebook: its cover thumbnail and the PDFs and images inside it (the original
 * documents; the handwriting itself is in GoodNotes' own format). `{thumbnail, attachments:[{name, mime, bytes}], pages}`.
 */
export async function goodnotesParts(bytes) {
  const zip = readZip(bytes);
  const out = { thumbnail: null, attachments: [], pages: 0 };
  for (const e of zip.entries) {
    if (e.isDirectory) continue;
    if (/(^|\/)thumbnail\.(jpe?g|png)$/i.test(e.path) && !out.thumbnail) out.thumbnail = { mime: /png$/i.test(e.path) ? "image/png" : "image/jpeg", bytes: await zip.data(e) };
    else if (/^notes\//.test(e.path)) out.pages++;
    else if (/^attachments\//.test(e.path) && e.size < 200 * 1024 * 1024) {
      const data = await zip.data(e);
      const mime = sniff(data);
      if (mime) out.attachments.push({ name: e.name, mime, bytes: data });
    }
  }
  return out;
}

/** The preview image Pages, Keynote and Numbers keep inside the file. */
export async function iworkPreview(bytes) {
  const zip = readZip(bytes);
  for (const path of ["preview.jpg", "QuickLook/Preview.jpg", "preview-web.jpg", "QuickLook/Thumbnail.jpg", "preview-micro.jpg"]) {
    const e = zip.entries.find((x) => x.path === path);
    if (e) return { mime: "image/jpeg", bytes: await zip.data(e) };
  }
  return null;
}

/** A Word document as paragraphs: [{style: "h1"|"h2"|"h3"|"li"|"p", text}]. */
export async function docxParagraphs(bytes) {
  const xml = await entryText(readZip(bytes), "word/document.xml");
  if (!xml) return [];
  const out = [];
  for (const m of xml.matchAll(/<w:p[ >][\s\S]*?<\/w:p>/g)) {
    const p = m[0];
    const styleId = /<w:pStyle w:val="([^"]+)"/.exec(p)?.[1] ?? "";
    const runs = p.replace(/<w:tab\/>/g, "<w:t>\t</w:t>").replace(/<w:br\/>/g, "<w:t>\n</w:t>").match(/<w:t(?: [^>]*)?>[^<]*<\/w:t>/g) ?? [];
    const text = xmlText(runs.map((t) => t.replace(/<[^>]+>/g, "")).join(""));
    const heading = /^(Heading|Title)(\d?)$/i.exec(styleId);
    const style = heading ? (heading[1].toLowerCase() === "title" ? "h1" : `h${Math.min(3, Number(heading[2] || 1))}`) : /<w:numPr>/.test(p) ? "li" : "p";
    if (text.trim() || out.length) out.push({ style, text });
  }
  while (out.length && !out.at(-1).text.trim()) out.pop();
  return out;
}

const colIndex = (ref) => [...ref.replace(/\d+/g, "")].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;

/** The first sheet of a workbook as rows of strings (at most `maxRows`). */
export async function xlsxRows(bytes, maxRows = 200) {
  const zip = readZip(bytes);
  const shared = [];
  const sst = await entryText(zip, "xl/sharedStrings.xml");
  if (sst) for (const m of sst.matchAll(/<si>([\s\S]*?)<\/si>/g)) shared.push(xmlText((m[1].match(/<t(?: [^>]*)?>[^<]*<\/t>/g) ?? []).map((t) => t.replace(/<[^>]+>/g, "")).join("")));
  const sheetPath = zip.entries.map((e) => e.path).filter((p) => /^xl\/worksheets\/sheet\d+\.xml$/.test(p))
    .sort((a, b) => Number(/(\d+)\.xml$/.exec(a)[1]) - Number(/(\d+)\.xml$/.exec(b)[1]))[0];
  const sheet = sheetPath ? await entryText(zip, sheetPath) : null;
  if (!sheet) return [];
  const rows = [];
  for (const row of sheet.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    if (rows.length >= maxRows) break;
    const cells = [];
    for (const c of row[1].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = c[1], inner = c[2] ?? "";
      const ref = /r="([A-Z]+\d+)"/.exec(attrs)?.[1];
      const type = /t="([^"]+)"/.exec(attrs)?.[1];
      const v = /<v>([^<]*)<\/v>/.exec(inner)?.[1];
      let value = "";
      if (type === "s" && v !== undefined) value = shared[Number(v)] ?? "";
      else if (type === "inlineStr") value = xmlText((inner.match(/<t(?: [^>]*)?>[^<]*<\/t>/g) ?? []).map((t) => t.replace(/<[^>]+>/g, "")).join(""));
      else if (v !== undefined) value = xmlText(v);
      const i = ref ? colIndex(ref) : cells.length;
      if (i < 200) cells[i] = value;
    }
    rows.push(Array.from(cells, (x) => x ?? ""));
  }
  return rows;
}

/** Each slide's text, in order: [[line, …], …]. */
export async function pptxSlides(bytes) {
  const zip = readZip(bytes);
  const paths = zip.entries.map((e) => e.path).filter((p) => /^ppt\/slides\/slide\d+\.xml$/.test(p))
    .sort((a, b) => Number(/(\d+)\.xml$/.exec(a)[1]) - Number(/(\d+)\.xml$/.exec(b)[1]));
  const out = [];
  for (const p of paths) {
    const xml = await entryText(zip, p);
    out.push([...xml.matchAll(/<a:p>([\s\S]*?)<\/a:p>/g)].map((m) => xmlText((m[1].match(/<a:t>[^<]*<\/a:t>/g) ?? []).map((t) => t.slice(5, -6)).join(""))).filter((l) => l.trim()));
  }
  return out;
}

/** Splits CSV/TSV text into rows (quotes handled), at most `maxRows`. */
export function parseDelimited(text, delimiter = ",", maxRows = 500) {
  const rows = [];
  let row = [], field = "", quoted = false;
  for (let i = 0; i < text.length && rows.length < maxRows; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; } else if (ch === '"') quoted = false; else field += ch;
    } else if (ch === '"' && !field) quoted = true;
    else if (ch === delimiter) { row.push(field); field = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(field); rows.push(row); row = []; field = "";
    } else field += ch;
  }
  if ((field || row.length) && rows.length < maxRows) { row.push(field); rows.push(row); }
  return rows;
}
