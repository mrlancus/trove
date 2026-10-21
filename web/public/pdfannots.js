// Export as real PDF annotations (ROADMAP S5): Trove's ink, highlights and text boxes on a PDF become
// Ink, Highlight and FreeText annotations other PDF apps can still edit, and saved form values are
// written into the form. pdf.js writes them as an incremental update to the original file, with
// appearance streams, so the file's own content is untouched. Pictures and tape aren't exported.
import { lineWidthOf, toolOpacity } from "./core/ink.js";
import { highlightRects, pdfPageBox } from "./core/pdfmarks.js";

// pdf.js's annotation editor types and the key prefix its saveDocument() reads new annotations from.
const FREETEXT = 3, HIGHLIGHT = 9, INK = 15;
const EDITOR_PREFIX = "pdfjs_internal_editor_";

const rgb = (hex) => {
  const v = parseInt(String(hex ?? "#000000").slice(1, 7), 16);
  return Number.isFinite(v) ? [(v >> 16) & 255, (v >> 8) & 255, v & 255] : [0, 0, 0];
};

function bboxOf(points, pad = 0) {
  let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
  for (const [x, y] of points) { x1 = Math.min(x1, x); y1 = Math.min(y1, y); x2 = Math.max(x2, x); y2 = Math.max(y2, y); }
  return [x1 - pad, y1 - pad, x2 + pad, y2 + pad];
}

/** A stroke as pdf.js's serialised ink annotation (PDF space, one even width). */
export function inkAnnotation(stroke, box, pageIndex) {
  const pts = stroke.points.map((p) => box.toPdf([p.x, p.y]));
  if (!pts.length) return null;
  const thickness = Math.max(0.3, lineWidthOf(stroke));
  const line = [NaN, NaN, NaN, NaN, ...pts[0]];
  for (const p of pts.slice(1)) line.push(NaN, NaN, NaN, NaN, p[0], p[1]);
  return {
    annotationType: INK, color: rgb(stroke.color), thickness, opacity: toolOpacity(stroke.tool), pageIndex, rotation: 0,
    paths: { lines: [line], points: [pts.flat()] }, rect: bboxOf(pts, thickness),
  };
}

/** A text highlight as a Highlight annotation: one quadrilateral per piece. */
export function highlightAnnotation(e, box, pageIndex) {
  const quadPoints = [], outlines = [], all = [];
  for (const r of highlightRects(e)) {
    // pdf.js's order: top-left, top-right, bottom-left, bottom-right (as seen on the page).
    const tl = box.toPdf([r.x, r.y]), tr = box.toPdf([r.x + r.w, r.y]), bl = box.toPdf([r.x, r.y + r.h]), br = box.toPdf([r.x + r.w, r.y + r.h]);
    quadPoints.push(...tl, ...tr, ...bl, ...br);
    outlines.push([...tl, ...tr, ...br, ...bl]);
    all.push(tl, tr, bl, br);
  }
  return { annotationType: HIGHLIGHT, color: rgb(e.color), opacity: 0.35, pageIndex, rotation: 0, quadPoints, outlines, rect: bboxOf(all) };
}

/** A text box as a FreeText annotation. `height` is how tall its wrapped lines are. */
export function textAnnotation(e, box, pageIndex, rotate, height = e.h) {
  const corners = [[e.x, e.y], [e.x + e.w, e.y], [e.x, e.y + height], [e.x + e.w, e.y + height]].map((p) => box.toPdf(p));
  return { annotationType: FREETEXT, color: rgb(e.color), fontSize: e.size, value: e.text, pageIndex, rotation: rotate, rect: bboxOf(corners) };
}

/**
 * Writes saved values into the form's widgets (`widgets`: pdf.js annotations of the whole file):
 * text and choices as they are, a check box ticked when true (or its export value), the radio button
 * whose value was chosen. Returns how many fields were set.
 */
export function fillForm(storage, widgets, values) {
  let n = 0;
  for (const w of widgets) {
    if (w.subtype !== "Widget" || !w.fieldName || !values.has(w.fieldName)) continue;
    const v = values.get(w.fieldName);
    if (w.checkBox) storage.setValue(w.id, { value: v === true || (typeof v === "string" && v === w.exportValue) });
    else if (w.radioButton) storage.setValue(w.id, { value: v === w.buttonValue });
    else if (w.fieldType === "Tx") storage.setValue(w.id, { value: Array.isArray(v) ? v.join(", ") : String(v) });
    else if (w.fieldType === "Ch") storage.setValue(w.id, { value: v });
    else continue;
    n++;
  }
  return n;
}

/** Every widget annotation in the document (for filling the form). */
export async function formWidgets(doc) {
  const out = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n);
    for (const a of await page.getAnnotations()) if (a.subtype === "Widget") out.push({ ...a, pageIndex: n - 1 });
  }
  return out;
}

/**
 * The PDF with Trove's marks as real annotations. `doc` is a pdf.js document opened from the
 * original bytes (it's used up: its storage is filled). `strokes(i)`, `elements(i)` give page i's
 * ink and elements; `fields` maps field names to saved values; `textHeight(e)` measures a text box.
 */
export async function annotatedPdf(doc, { strokes, elements, fields = new Map(), textHeight = (e) => e.h }) {
  const storage = doc.annotationStorage;
  let key = 0, count = 0;
  const add = (a) => { if (a) { storage.setValue(`${EDITOR_PREFIX}${key++}`, a); count++; } };
  for (let i = 0; i < doc.numPages; i++) {
    const page = await doc.getPage(i + 1);
    const box = pdfPageBox(page.view, page.rotate);
    const els = elements(i) ?? [];
    for (const e of els) if (e.type === "highlight") add(highlightAnnotation(e, box, i));
    for (const s of strokes(i) ?? []) add(inkAnnotation(s, box, i));
    for (const e of els) if (e.type === "text" && e.text.trim()) add(textAnnotation(e, box, i, page.rotate, textHeight(e)));
  }
  if (fields.size) count += fillForm(storage, await formWidgets(doc), fields);
  return { bytes: await doc.saveDocument(), count };
}
