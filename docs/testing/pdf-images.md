# PDFs and images (PDF)

The PDF reader (`Drawing/PDFReader.swift`, PDFKit), the file viewer (Open, view-only, Edit, Print),
highlights, quotes, forms, export with annotations. PROTOCOL.md §10.

### TEST-PDF-001: Open a PDF view-only, then edit and draw
- **Feature**: file viewer
- **Priority**: critical
- **Coverage**: auto-tested (website); apps: not tested
- **Platforms**: iPad, iPhone, Mac
- **Preconditions**: any PDF item.
- **Steps**:
  1. Tap Open. Tap the page and a form field.
  2. Edit → Pen → draw a line → Done.
  3. Close and Open again.
- **Expected**: nothing changes on the tap in view-only; the line is there after reopening.
- **Failure looks like**: edits in view-only, the line lost, the viewer not opening.
- **Automated by**: website `pdf.e2e.mjs`; apps: manual.

### TEST-PDF-002: Find, highlight and quote
- **Feature**: PDF marks
- **Priority**: critical
- **Coverage**: auto-tested (geometry, website; currently flaky on CI, see RESULTS)
- **Platforms**: all
- **Preconditions**: a text PDF.
- **Steps**:
  1. Find `the`; step with ↓ twice.
  2. Select a line → a colour → Quote.
- **Expected**: every hit marked; the highlight sits exactly on the text; a quote item in Quotes & Highlights.
- **Failure looks like**: the highlight offset (also try a rotated page), no quote.
- **Automated by**: `PDFMarksTests/highlightGeometryMatchesTheWebsite`, `highlightsQuotesFormValuesAndText`; website `pdf.e2e.mjs`.

### TEST-PDF-003: A 500-page PDF opens and scrolls
- **Feature**: large PDFs
- **Priority**: critical
- **Coverage**: not tested (budget: first page < 200 ms, no hang)
- **Platforms**: iPad, iPhone, Mac
- **Preconditions**: `-TroveTestVault full` "Generated 500-page PDF", or a big PDF of yours.
- **Steps**:
  1. Watch for lag on. Open it; scroll to page 400 with the scroller.
  2. Export diagnostics.
- **Expected**: the first page at once; pages fill in as you scroll; no hang in "PDF" or "File viewer".
- **Failure looks like**: a long blank, hangs, memory warnings (iPhone).
- **Automated by**: manual.

### TEST-PDF-004: Form values are kept and the file never changes
- **Feature**: forms
- **Priority**: high
- **Coverage**: auto-tested (core, website)
- **Platforms**: iPad, Mac, web
- **Preconditions**: a fillable PDF.
- **Steps**:
  1. Edit; type in a field, tick a box; close; reopen; open on the website.
- **Expected**: the values everywhere; the original file under Versions unchanged.
- **Failure looks like**: values lost, radio buttons wrong.
- **Automated by**: `PDFMarksTests/highlightsQuotesFormValuesAndText`; website `pdf.e2e.mjs`.

### TEST-PDF-005: Export with annotations opens elsewhere
- **Feature**: export
- **Priority**: high
- **Coverage**: auto-tested (website pdf.js export)
- **Platforms**: iPad, Mac
- **Preconditions**: a PDF with ink and highlights.
- **Steps**:
  1. Export with annotations → open in Preview / Files.
- **Expected**: ink and highlights there, editable as annotations.
- **Failure looks like**: flattened or missing marks.
- **Automated by**: website `pdf.e2e.mjs`; apps: manual.

### TEST-PDF-006: A corrupt PDF fails gently
- **Feature**: robustness
- **Priority**: high
- **Coverage**: auto-tested (import)
- **Platforms**: all
- **Preconditions**: a file named `bad.pdf` holding random bytes.
- **Steps**:
  1. Import it and Open it.
- **Expected**: the item exists; the viewer says it can't show it; nothing crashes.
- **Failure looks like**: a crash or a spinner for ever.
- **Automated by**: `ImportTests/rejectsCorruptData`; viewer: manual.
