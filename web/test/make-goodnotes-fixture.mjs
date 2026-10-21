// Writes a small, made-up GoodNotes notebook (Fixtures/ink.goodnotes) that uses every ink layout
// core/goodnotes.js reads, plus what the JS decoder makes of it (Fixtures/ink-expected.json).
// GoodNotesInkTests.swift decodes the same file and must agree. Run: node test/make-goodnotes-fixture.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { crc32 } from "../public/core/importer.js";
import { editableInk, readNotebook } from "../public/core/goodnotes.js";

const te = new TextEncoder();
const cat = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
const varint = (n) => { const b = []; do { let x = n % 128; n = Math.floor(n / 128); if (n) x |= 128; b.push(x); } while (n); return Uint8Array.from(b); };
const bytes = (v) => (typeof v === "string" ? te.encode(v) : v);
// Protobuf fields.
const fLen = (n, v) => { const b = bytes(v); return cat(varint(n * 8 + 2), varint(b.length), b); };
const fInt = (n, v) => cat(varint(n * 8), varint(v));
const fFloat = (n, v) => { const b = new Uint8Array(4); new DataView(b.buffer).setFloat32(0, v, true); return cat(varint(n * 8 + 5), b); };
const msg = (...fields) => cat(...fields);
const xy = (x, y) => msg(fFloat(1, x), fFloat(2, y));
const delimited = (...records) => cat(...records.flatMap((r) => [varint(r.length), r]));

// Floats as the raw words TPL keeps them in.
const word = (v) => { const b = new DataView(new ArrayBuffer(4)); b.setFloat32(0, v, true); return b.getUint32(0, true); };

// TPL: the format string, then values. `A` lists start with a u32 count.
function tpl(format, write) {
  const body = [];
  const w = { u32: (v) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v >>> 0, true); body.push(b); },
    u16: (v) => { const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, v, true); body.push(b); },
    f64: (v) => { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, v, true); body.push(b); } };
  write(w);
  const head = cat(te.encode("tpl"), Uint8Array.of(0), new Uint8Array(4), te.encode(format), Uint8Array.of(0));
  const all = cat(head, ...body);
  new DataView(all.buffer).setUint32(4, all.length, true);
  return all;
}

// Apple LZ4 frames: one compressed block of plain literals (valid LZ4), then the end marker.
function lz4(data) {
  const lit = data.length;
  const token = Math.min(lit, 15) << 4;
  const ext = [];
  if (lit >= 15) { let rest = lit - 15; while (rest >= 255) { ext.push(255); rest -= 255; } ext.push(rest); }
  const block = cat(Uint8Array.of(token), Uint8Array.from(ext), data);
  const head = new Uint8Array(8);
  new DataView(head.buffer).setUint32(0, data.length, true);
  new DataView(head.buffer).setUint32(4, block.length, true);
  return cat(te.encode("bv41"), head, block, te.encode("bv4$"));
}

const colour = (r, g, b, a) => msg(fFloat(1, r), fFloat(2, g), fFloat(3, b), fFloat(4, a));
const stroke = (id, image, { rgba = [0, 0, 0, 1], move } = {}) =>
  fLen(7, msg(fLen(1, id), fLen(2, lz4(image)), fInt(3, 1), fLen(4, colour(...rgba)), move ? fLen(6, xy(...move)) : new Uint8Array(0)));
const element = (id, erased = false) => msg(fLen(1, id), erased ? fInt(3, 1) : new Uint8Array(0), fInt(16, 24));

const id = (n) => `${n.toString(16).toUpperCase().padStart(8, "0")}-1111-4000-8000-${String(n).padStart(12, "0")}`;
const PAGE1 = id(1), PAGE2 = id(2), PAGE3 = id(3), PDF = id(10), PNG = id(11), TEMPLATE = id(12);

// Pen: start + (x1, y1, x2, y2) segments, width 6.
const pen = tpl("vuA(v)A(S(uu))A(S(uuuu))vA(f)", (w) => {
  w.u16(2); w.u32(word(6));
  w.u32(3); w.u16(0); w.u16(1); w.u16(1);
  w.u32(1); w.u32(word(100)); w.u32(word(100));
  w.u32(2); for (const v of [120, 110, 140, 130, 160, 120, 180, 100]) w.u32(word(v));
  w.u16(1); w.u32(0);
});
// Highlighter: alpha 0.5, a pen lift before the second segment, moved by (10, 5).
const marker = tpl("vuA(v)A(S(uu))A(S(uuuu))vA(f)", (w) => {
  w.u16(2); w.u32(word(24));
  w.u32(3); w.u16(0); w.u16(1); w.u16(0);
  w.u32(1); w.u32(word(100)); w.u32(word(300));
  w.u32(2); for (const v of [150, 300, 200, 300, 260, 300, 320, 300]) w.u32(word(v));
  w.u16(1); w.u32(0);
});
// GoodNotes 6: start (x, y, r, 0), then (x, y, r) with a (0, 0, 0.1) marker.
const gn6 = tpl("vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)", (w) => {
  w.u16(2);
  w.u32(2); w.u16(0); w.u16(1);
  w.u32(4); for (const v of [400, 400, 0.6, 0]) w.u32(word(v));
  w.u32(9); for (const v of [420, 410, 0.7, 0, 0, 0.1, 440, 430, 0.8]) w.u32(word(v));
  for (let i = 0; i < 7; i++) w.u32(0);
});
// Pencil: 5-word start, 11-word segments.
const pencil = tpl("vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u)", (w) => {
  w.u16(1); w.u32(word(8));
  w.u32(2); w.u16(0); w.u16(1);
  w.u32(1); for (const v of [500, 600, 0, 0, 2]) w.u32(word(v));
  w.u32(1); for (const v of [0, 520, 610, 0, 0, 2.5, 540, 640, 0, 0, 3]) w.u32(word(v));
  w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0);
});

const S = (n) => id(100 + n);
const shapeLine = msg(fLen(1, S(6)), fLen(4, colour(0, 0.5, 0, 1)),
  fLen(9, msg(fLen(1, msg(fLen(1, msg(fLen(1, xy(600, 100)))), fLen(1, msg(fLen(1, xy(700, 200)))), fLen(1, msg(fLen(1, xy(600, 200)))), fLen(1, msg(fLen(1, xy(600, 100)))))), fFloat(15, 4))));
const shapeEllipse = msg(fLen(1, S(7)), fLen(4, colour(0, 0, 1, 1)),
  fLen(9, msg(fLen(4, msg(fLen(1, xy(800, 800)), fLen(2, xy(50, 25)), fFloat(3, 0))), fFloat(15, 3))));
const rich = msg(fLen(1, msg(fLen(1, "Hello "), fLen(2, msg(fFloat(40, 24))))),
  fLen(1, msg(fLen(1, "world\nagain"), fLen(2, msg(fLen(30, "Helvetica-Bold"), fLen(3, colour(1, 0, 0, 1)))))));
const textBox = msg(fLen(1, S(8)), fLen(21, msg(fLen(20, msg(fLen(1, xy(100, 900)))),
  fLen(32, msg(fLen(1, msg(fLen(2, lz4(rich)))), fLen(2, xy(300, 80)), fLen(5, msg(fLen(1, msg(fFloat(40, 20))))), fLen(10, xy(5, 5)))))));
const image = msg(fLen(1, S(9)), fLen(7, PNG), fLen(9, msg(fLen(2, msg(fLen(1, xy(700, 1000)), fLen(2, xy(200, 100)))))));

const page1 = delimited(
  element(S(1)), stroke(S(1), pen),
  element(S(2)), stroke(S(2), marker, { rgba: [1, 0.9, 0, 0.5], move: [10, 5] }),
  element(S(3)), stroke(S(3), gn6, { rgba: [0.2, 0.4, 0.8, 1] }),
  element(S(4)), stroke(S(4), pencil, { rgba: [1, 0.6, 0, 1] }),
  element(S(5), true), stroke(S(5), pen),
  fLen(7, shapeLine), fLen(7, shapeEllipse), textBox, image);
// Newer layouts: a format with an extra word in front, ink far out on a whiteboard, doubles (A(f)).
const gn6Extra = tpl("vuuA(v)A(u)A(u)A(v)", (w) => {
  w.u16(2); w.u32(word(3)); w.u32(7);
  w.u32(2); w.u16(0); w.u16(1);
  w.u32(3); for (const v of [30000, -25000, 0.9]) w.u32(word(v));
  w.u32(6); for (const v of [30020, -24990, 1, 30040, -24970, 1.1]) w.u32(word(v));
  w.u32(0);
});
const gn6Doubles = tpl("vA(v)A(f)A(f)", (w) => {
  w.u16(2);
  w.u32(2); w.u16(0); w.u16(1);
  w.u32(3); for (const v of [200, 220, 0.5]) w.f64(v);
  w.u32(6); for (const v of [210, 230, 0.6, 230, 250, 0.7]) w.f64(v);
});
// Grouped ink: two strokes nested in one field, as moved-together ink on whiteboards comes.
const strokeMsg = (sid, image, rgba) => msg(fLen(1, sid), fLen(2, lz4(image)), fInt(3, 1), fLen(4, colour(...rgba)));
const group = fLen(7, msg(fLen(1, S(29)), fLen(5, strokeMsg(S(21), pen, [0, 0.6, 0, 1])), fLen(5, strokeMsg(S(22), gn6, [0.6, 0, 0.6, 1]))));
// A filled ellipse: the fill (field 9, alpha 0.25) and its outline.
const fillOf = fLen(9, msg(fLen(1, S(25)), fLen(4, msg(fLen(4, msg(fLen(1, xy(300, 300)), fLen(2, xy(40, 20)), fFloat(3, 0))))), fLen(5, S(26)), fLen(7, colour(1, 0, 0, 0.25))));
const outline = fLen(7, msg(fLen(1, S(26)), fLen(4, colour(1, 0, 0, 1)), fLen(9, msg(fLen(4, msg(fLen(1, xy(300, 300)), fLen(2, xy(40, 20)), fFloat(3, 0))), fFloat(15, 2)))));
const page2 = delimited(element(S(20)), stroke(S(20), pen),
  element(S(23)), stroke(S(23), gn6Extra), element(S(24)), stroke(S(24), gn6Doubles, { rgba: [0, 0, 1, 1] }),
  group, fillOf, outline);
const page3 = delimited(element(S(30)), stroke(S(30), pen));

const files = {
  "index.notes.pb": delimited(...[[PAGE1, "notes/P1"], [PAGE2, "notes/P2"], [PAGE3, "notes/P3"]].map(([u, p]) => msg(fLen(1, u), fLen(2, p)))),
  "index.attachments.pb": delimited(msg(fLen(1, PDF), fLen(2, `attachments/${PDF}`)), msg(fLen(1, PNG), fLen(2, `attachments/${PNG}`))),
  // Page 2 sorts first ("a" < "b"), page 3 is deleted, page 1 uses the PDF template.
  "index.events.pb": delimited(
    msg(fLen(2, msg(fLen(2, TEMPLATE), fLen(4, PDF), fInt(5, 1)))),
    msg(fLen(54, msg(fLen(2, PAGE1), fLen(3, msg(fLen(1, TEMPLATE))), fLen(4, msg(fLen(1, "b"))))), fInt(14, 1)),
    msg(fLen(54, msg(fLen(2, PAGE2), fLen(4, msg(fLen(1, "a"))))), fInt(14, 2)),
    msg(fLen(56, msg(fLen(2, PAGE3)))), fInt(14, 3)),
  "notes/P1": page1, "notes/P2": page2, "notes/P3": page3,
  [`attachments/${PDF}`]: new Uint8Array(readFileSync(new URL("./fixtures/files/sample.pdf", import.meta.url))),
  [`attachments/${PNG}`]: Uint8Array.from(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64")),
};

// A stored (uncompressed) zip.
function zip(entries) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const [name, data] of Object.entries(entries)) {
    const n = te.encode(name), crc = crc32(data);
    const local = new Uint8Array(30 + n.length);
    const dv = new DataView(local.buffer);
    dv.setUint32(0, 0x04034b50, true); dv.setUint16(4, 20, true); dv.setUint32(14, crc, true);
    dv.setUint32(18, data.length, true); dv.setUint32(22, data.length, true); dv.setUint16(26, n.length, true);
    local.set(n, 30);
    const central = new Uint8Array(46 + n.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true); cv.setUint16(4, 20, true); cv.setUint16(6, 20, true); cv.setUint32(16, crc, true);
    cv.setUint32(20, data.length, true); cv.setUint32(24, data.length, true); cv.setUint16(28, n.length, true); cv.setUint32(42, offset, true);
    central.set(n, 46);
    locals.push(local, data); centrals.push(central);
    offset += local.length + data.length;
  }
  const dir = cat(...centrals);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true); ev.setUint16(8, centrals.length, true); ev.setUint16(10, centrals.length, true);
  ev.setUint32(12, dir.length, true); ev.setUint32(16, offset, true);
  return cat(...locals, dir, end);
}

const notebook = zip(files);
const fixtures = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/", import.meta.url);
writeFileSync(new URL("ink.goodnotes", fixtures), notebook);

// What the decoder makes of it, rounded, for the Swift side to match.
const r2 = (v) => Math.round(v * 100) / 100;
const decoded = await readNotebook(notebook);
const expected = {
  // A compressed LZ4 block with a back-reference: "abc" then copy 9 bytes from 3 back.
  lz4: { frame: Buffer.from(cat(te.encode("bv41"), Uint8Array.of(12, 0, 0, 0, 6, 0, 0, 0), Uint8Array.of(0x35, 97, 98, 99, 3, 0), te.encode("bv4$"))).toString("base64"), text: "abcabcabcabc" },
  pages: decoded.pages.map((p) => ({
    id: p.id, width: r2(p.width), height: r2(p.height), background: p.background, unread: p.unread,
    layers: p.layers.map((l) => l.kind === "ink"
      ? { kind: "ink", rgb: l.rgb.map(r2), alpha: r2(l.alpha), width: r2(l.width), shape: !!l.shape, pencil: !!l.pencil, fill: !!l.fill, runs: l.runs.map((run) => run.map((pt) => pt.map(r2))) }
      : l.kind === "text" ? { kind: "text", x: r2(l.x), y: r2(l.y), w: r2(l.w), h: r2(l.h), runs: l.runs.map((t) => ({ ...t, size: r2(t.size), rgb: t.rgb.map(r2) })) }
      : { kind: "image", attachment: l.attachment, x: r2(l.x), y: r2(l.y), w: r2(l.w), h: r2(l.h) }),
  })),
  // What Trove's editor gets from each page (GoodNotesInk.editableInk must match).
  editable: decoded.pages.map((p) => {
    const e = editableInk(p);
    return {
      strokes: e.strokes.map((s) => ({ ...s, width: r2(s.width), points: s.points.map((q) => [r2(q.x), r2(q.y), r2(q.p), q.t]) })),
      texts: e.texts.map((t) => ({ ...t, x: r2(t.x), y: r2(t.y), w: r2(t.w), h: r2(t.h), size: r2(t.size) })),
    };
  }),
};
writeFileSync(new URL("ink-expected.json", fixtures), JSON.stringify(expected, null, 1) + "\n");
console.log("wrote ink.goodnotes", notebook.length, "bytes;", expected.pages.map((p) => `${p.layers.length} layers`).join(", "));
