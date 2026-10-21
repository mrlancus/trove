# Reading GoodNotes notebooks

Trove shows `.goodnotes` files (from GoodNotes' Auto Backup or dropped in by hand) page by page
with the handwriting, without GoodNotes. There are two decoders, kept in step by a shared fixture:

- `web/public/core/goodnotes.js` (website), drawn by `notebookViewer` in `web/public/viewer.js`
- `Packages/TroveCore/Sources/TroveCore/Import/GoodNotesInk.swift` (apps), drawn by
  `App/Sources/Views/NotebookView.swift`
- Fixture: `Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink.goodnotes` and `ink-expected.json`,
  made by `web/test/make-goodnotes-fixture.mjs`. It's a made-up notebook (no real notes) that
  uses every layout below. `core.test.mjs` and `GoodNotesInkTests.swift` both check against it.

GoodNotes doesn't document the format. This follows the reverse engineering in the MIT-licensed
[Document Parser for GoodNotes](https://github.com/Kaih1825/parser-for-goodnotes), and was checked
against its sample notebooks and against GoodNotes' own PDF exports of the samples in
[goodparse](https://github.com/franzthiemann/goodparse). Neither project's code or samples are in
this repo.

## Container
A zip:
- `notes/<page>`: the page's records, length-prefixed protobuf messages (some files are instead one
  message whose field-7 entries are the records).
- `index.notes.pb`: pages (`notes/…` path and page UUID per record).
- `index.events.pb`: field 54 = page created (2: page id, 3.1: template id, 4.1: order key),
  55 = page moved (3.1: new order key), 56 = page deleted (2: page id), 2 = template
  (2: id, 4: attachment id, 5: PDF page number); field 14 is the timestamp. Pages sort by their
  latest order key. Page ids gain a revision character at the end, so they're compared on the first
  32 characters.
- `index.attachments.pb`: attachment UUID → `attachments/<file>` (PDFs, images).

## Page records
- An element record has its UUID in field 1 and field 3 = 1 when erased (skip anything with that id).
- **Ink**: a field whose bytes are `\n$<uuid>` … `bv41`…`bv4$` (Apple LZ4 blocks: `bv41`
  compressed, `bv4-` stored, 8-byte sizes) … then protobuf fields: 4 = colour {1 r, 2 g, 3 b, 4 a}
  as fixed32 floats, 6 = move offset {1 dx, 2 dy}. The LZ4 holds a TPL image (`tpl` + flags + size +
  format string + values; `u` values are float bits).
  - `vuA(v)A(S(uu))A(S(uuuu))…` (pens, highlighters): width in values[1], pen-up flags in values[2]
    (0 lifts the pen), start point in values[3], two points per segment in values[4].
  - `…A(S(uuuuu))A(S(uuuuuuuuuuu))…` (pencil): start (x, y, ·, ·, r), segments
    (·, x1, y1, ·, ·, r1, x2, y2, ·, ·, r2).
  - `vA(v)A(u)A(u)…` / `vuA(v)A(u)A(u)…` (GoodNotes 6): first point (x, y, r[, 0]), then (x, y, r)
    triples with (0, 0, r) markers between curve segments. The two arrays are the first two plain
    number arrays in the format wherever they sit (`A(u)` float bits or `A(f)` doubles), since other
    versions put more fields in front.
  - Grouped ink (whiteboards, things moved together): one field can nest several strokes, each
    starting `\n$<uuid>` with its own LZ4 before the next; each is read on its own, and a stroke's
    trailer is read up to the first bytes that aren't a field.
  - Coordinates up to ±1,000,000 are kept (whiteboards are endless).
  - Alpha below 0.95 is a highlighter (drawn with multiply).
- **Shapes**: field 7 → {1 uuid, 4 colour, 9 geometry {1|2 path, 3 rectangle, 4 ellipse, 15 width}},
  move in 14 or 6. Path items: 3 = quadratic (control, end), 4 = cubic, otherwise a line point.
- **Shape fills**: field 9 → {1 uuid, 2 bounds, 4 geometry (as above), 5 the shape it fills, 7 colour
  (usually translucent)}: drawn filled under the outline, skipped when either is erased.
- **Text boxes**: field 21 → {20.1 position, 32 {1.2 LZ4 rich text, 2 size, 5.1.40 font size,
  10 inset}}. The rich text is a message of runs {1 text, 2 style {30 font name, 3 colour, 40 size,
  50 italic}}.
- **Images**: an attachment UUID in field 7 or 4, frame {2: {1 xy, 2 wh}, 3 crop} in the record or
  the next one.
- Coordinates are at 132 dpi; multiply by 72/132 for PDF points. Page size comes from the
  background PDF.
- Ink whose LZ4 holds a TPL image with points that none of the layouts above read is counted per
  page (`unread`) and shown in the viewers ("N strokes couldn't be read"), so a new layout is noticed.
- A one-page notebook (a whiteboard) also takes the records of `notes/` members the index doesn't list.

Not drawn yet: sticky notes, lasso-rotated items, audio recordings, pencil texture.

## Page size and whiteboards

A page takes its size from its PDF background's MediaBox, or US Letter (612 × 792 pt) when it has
none. GoodNotes whiteboards are endless canvases: no background, or a huge blank one, with the drawing
often far from 0, 0. So a page with no background whose content runs off the page, or any page over
2000 pt on a side, is cropped to its content's bounds plus a 36 pt margin and everything is moved to
fit (`fitToContent` in both decoders); an oversized page drops its blank background. The viewers draw
very large pages at a lower resolution instead of failing.
