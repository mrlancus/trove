// PDFs like a PDF app (ROADMAP S5): text for search, highlights, quotes, form values and export as
// real annotations. core/pdfmarks.js is checked against Fixtures/pdf-cases.json (PDFMarksTests.swift
// checks the same file); pdf.js runs here in Node for text extraction and the annotated export.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { b64uEncode } from "../public/core/bytes.js";
import { importVaultKeys } from "../public/core/keys.js";
import { elementView } from "../public/core/ink.js";
import { cleanQuote, fieldElementId, findAll, highlightGeometry, highlightRects, joinPdfText, pageTextFromItems, pdfPageBox } from "../public/core/pdfmarks.js";
import { annotatedPdf, formWidgets } from "../public/pdfannots.js";
import { formPdf } from "./make-pdf.mjs";

const fixture = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/pdf-cases.json", import.meta.url), "utf8"));
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} vs ${b}`);

let pdfjs = null;
async function openPdf(bytes) {
  if (!pdfjs) {
    pdfjs = await import("../public/vendor/pdfjs-4.10.38/pdf.min.mjs");
    pdfjs.GlobalWorkerOptions.workerSrc = new URL("../public/vendor/pdfjs-4.10.38/pdf.worker.min.mjs", import.meta.url).href;
  }
  return pdfjs.getDocument({ data: bytes.slice(), isEvalSupported: false, verbosity: 0 }).promise;
}

test("PDF text, quotes, highlights, page boxes and field ids match Fixtures/pdf-cases.json", () => {
  for (const c of fixture.text) {
    const pages = c.pages ?? c.repeat.map(([s, n]) => s.repeat(n));
    const out = Array.from(joinPdfText(pages));
    if (c.repeat) { assert.equal(out.length, c.expectedLength, c.name); assert.equal(out.slice(-5).join(""), c.expectedTail, c.name); }
    else assert.equal(out.join(""), c.expected, c.name);
  }
  for (const q of fixture.quotes) assert.equal(cleanQuote(q.input), q.expected);
  for (const c of fixture.highlights) {
    const boxes = c.boxes.map((b) => Object.fromEntries(Object.entries(b).map(([k, v]) => [k, v ?? Number.NaN])));
    const g = highlightGeometry(boxes);
    assert.deepEqual(g, c.expected, c.name);
    if (g) assert.deepEqual(highlightRects(g), c.absolute, c.name);
  }
  for (const c of fixture.boxes) {
    const b = pdfPageBox(c.view, c.rotate);
    assert.deepEqual([b.width, b.height], c.size);
    c.points.forEach((p, i) => { assert.deepEqual(b.toPage(p), c.page[i]); assert.deepEqual(b.toPdf(b.toPage(p)), c.back[i]); });
  }
  for (const f of fixture.fieldIds) assert.equal(fieldElementId(f.item, f.layer, f.name), f.id);
  // Old readers see new element types as empty text boxes (no `text`), so they draw nothing.
  const views = fixture.elements.records.map((r) => elementView(r));
  assert.deepEqual(views.map((e) => e.type), ["text", "highlight", "field", "highlight"]);
  assert.ok(views.slice(1).every((e) => e.text === ""));
  for (const [id, rects] of Object.entries(fixture.elements.absolute)) {
    highlightRects(views.find((e) => e.id === id)).forEach((r, i) => { for (const k of ["x", "y", "w", "h"]) close(r[k], rects[i][k], `${id} ${k}`); });
  }
});

test("page boxes agree with pdf.js viewports in every rotation", async () => {
  const doc = await openPdf(formPdf());
  const page = await doc.getPage(1);
  for (const rotation of [0, 90, 180, 270]) {
    const vp = page.getViewport({ scale: 1, rotation });
    const box = pdfPageBox(page.view, rotation);
    close(box.width, vp.width, "width");
    close(box.height, vp.height, "height");
    for (const p of [[0, 0], [72, 600], [612, 792]]) {
      const [x, y] = vp.convertToViewportPoint(...p);
      const [a, b] = box.toPage(p);
      close(a, x, `x at ${rotation}`);
      close(b, y, `y at ${rotation}`);
    }
  }
  await doc.destroy();
});

test("text is read from a typed PDF with pdf.js, and search finds every hit", async () => {
  const doc = await openPdf(formPdf());
  const pages = [];
  for (let n = 1; n <= doc.numPages; n++) pages.push(pageTextFromItems((await (await doc.getPage(n)).getTextContent()).items));
  const text = joinPdfText(pages);
  assert.ok(text.startsWith("Trove test document\nThe quick brown fox jumps over the lazy dog."), text);
  assert.ok(text.includes("\n\nPage two\nThe second page also mentions the quick brown fox."));
  assert.deepEqual(findAll(text, "QUICK  brown").length, 2);
  assert.deepEqual(findAll("Fox\nJumps", "fox jumps"), [[0, 9]]);
  await doc.destroy();
});

async function testVault() {
  const { Vault } = await import("../public/core/vault.js");
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  let t = 1_760_000_000_000;
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const blobs = new Map();
  const fetch = async (url, init = {}) => {
    const id = /blobs\/([0-9a-f]+)$/.exec(url)?.[1];
    if (id && init.method === "PUT") { blobs.set(id, init.body); return new Response(null, { status: 204 }); }
    if (id) return blobs.has(id) ? new Response(blobs.get(id)) : new Response("", { status: 404 });
    return new Response("{}", { status: 200 });
  };
  return new Vault(storage, { deviceName: "Chrome", encrypted: true, base: "http://relay", vaultId: "V", token: "T" }, keys, { device: "WEB" }, [], [], [], 0,
    { now: () => (t += 1000), fetch });
}

test("highlights, quotes, form values and PDF text in the vault", async () => {
  const v = await testVault();
  const id = await v.addFile(formPdf(), "Form.pdf", "application/pdf");
  const att = v.item(id).attachments[0].id;
  const hl = v.addHighlight({ on: id, layer: att, page: 0, boxes: [{ x: 72, y: 90, w: 200, h: 12 }, { x: 72, y: 104, w: 150, h: 12 }], quote: "The quick brown\nfox" });
  const e = v.element(hl);
  assert.equal(e.type, "highlight");
  assert.equal(e.quote, "The quick brown fox");
  assert.equal(e.rects.length, 2);
  assert.equal(v.item(id).sketchText, "The quick brown fox", "highlighted words are searchable");
  assert.equal(v.addHighlight({ on: id, layer: att, page: 0, boxes: [], quote: "x" }), null);
  // Moving the highlight moves its pieces.
  v.transformElements([hl], { sx: 1, sy: 1, ox: 0, oy: 0, dx: 10, dy: 0 });
  assert.equal(highlightRects(v.element(hl))[0].x, 82);
  const [copy] = v.duplicateInk({ elements: [hl], on: id, layer: att, page: 0 });
  assert.equal(v.element(copy).quote, "The quick brown fox");
  assert.deepEqual(v.element(copy).rects, e.rects);

  // A quote item, connected to the PDF and filed under Highlights.
  const q = v.addQuote({ text: e.quote, from: id, page: 0 });
  const quote = v.item(q);
  assert.equal(quote.kind, "highlight");
  assert.equal(quote.category, "quote");
  assert.deepEqual(quote.links, [id]);
  assert.equal(quote.body, "> The quick brown fox\n\n— Form (p. 1)");

  // One record per field, whoever fills it; the same value again writes nothing.
  const frame = { x: 120, y: 178, w: 200, h: 20 };
  const f = v.setPdfField({ on: id, layer: att, page: 0, name: "name", value: "Ada", frame });
  assert.equal(f, fieldElementId(id, att, "name"));
  const ops = v.journal.pending.length;
  v.setPdfField({ on: id, layer: att, page: 0, name: "name", value: "Ada", frame });
  assert.equal(v.journal.pending.length, ops);
  v.setPdfField({ on: id, layer: att, page: 0, name: "agree", value: true, frame });
  assert.equal(v.setPdfField({ on: id, layer: att, page: 0, name: "bad", value: { no: 1 }, frame }), null);
  assert.deepEqual([...v.pdfFields(id, att)].map(([k, x]) => [k, x.value]), [["name", "Ada"], ["agree", true]]);
  assert.equal(v.item(id).fileVersions.length, 0, "the file itself never changes");

  v.setPdfText(id, "Some text from the PDF that is long enough to keep.");
  assert.equal(v.item(id).ocrText, "Some text from the PDF that is long enough to keep.");
});

test("export as real PDF annotations: ink, highlights, text boxes and the form", async () => {
  const bytes = formPdf();
  const doc = await openPdf(bytes);
  const strokes = (i) => (i === 0 ? [{ tool: "pen", color: "#ff0000", width: 2, points: [{ x: 72, y: 300, p: 0.5, t: 0 }, { x: 200, y: 320, p: 0.5, t: 10 }] }] : []);
  const elements = (i) => (i === 0 ? [
    { type: "highlight", color: "#ffd60a", x: 72, y: 90, w: 200, h: 26, rects: [[0, 0, 1, 0.5], [0, 0.5, 0.6, 0.5]] },
    { type: "text", text: "A typed note", size: 14, color: "#0000ff", x: 300, y: 300, w: 150, h: 20 },
    { type: "tape", color: "#f2c94c", x: 0, y: 0, w: 10, h: 10 },
  ] : []);
  const fields = new Map([["name", "Ada Lovelace"], ["agree", true], ["colour", "Blue"], ["size", "Large"]]);
  const { bytes: out, count } = await annotatedPdf(doc, { strokes, elements, fields });
  assert.equal(count, 3 + 5);
  assert.deepEqual(out.subarray(0, bytes.length), bytes, "an incremental update: the original bytes are kept as they were");
  const again = await openPdf(out);
  const annots = await (await again.getPage(1)).getAnnotations();
  const kinds = annots.map((a) => a.subtype);
  for (const k of ["Ink", "Highlight", "FreeText"]) assert.ok(kinds.includes(k), `${k} in ${kinds}`);
  const ink = annots.find((a) => a.subtype === "Ink");
  assert.deepEqual(ink.color, new Uint8ClampedArray([255, 0, 0]));
  assert.ok(Math.abs(ink.inkLists[0][0] - 72) < 0.01 && Math.abs(ink.inkLists[0][1] - (792 - 300)) < 0.01, "ink in PDF space");
  assert.equal(annots.find((a) => a.subtype === "FreeText").contentsObj.str, "A typed note");
  const widgets = await formWidgets(again);
  const value = (name, pick = (w) => w.fieldValue) => pick(widgets.find((w) => w.fieldName === name));
  assert.equal(value("name"), "Ada Lovelace");
  assert.equal(value("agree"), "Yes");
  assert.equal(value("colour"), "Blue");
  assert.deepEqual(value("size"), ["Large"]);
  await doc.destroy();
  await again.destroy();
});
