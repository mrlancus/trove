# Drawing and handwriting: plan

_Drafted 2026-10-20. **Phases 1–4 are built** (core, website, iPad/iPhone with PencilKit, Mac); the record format is PROTOCOL.md §10. Phase 5 (search, export) and 6 are next. GoodNotes ink is now decoded directly (docs/GOODNOTES.md)._

## What we want
- **Draw anywhere you have Trove**:
  - Apple Pencil on the iPad (pressure, tilt, double-tap, squeeze)
  - Finger on the iPhone
  - Trackpad or mouse on the Mac
  - Pen, finger or mouse on the website
- **Two kinds of drawing**:
  - A **sketch**: a blank or lined page, as its own item or inside a note.
  - **Markup on top of a file**: write on a PDF page, a photo or a screenshot.
- **The same drawing everywhere.** It syncs end-to-end encrypted like everything else and merges
  when two devices draw at once. Every edit is a version (it reuses the versions built this round).
- **Searchable handwriting.** The recognised text is indexed so search finds it.

## The key decision: our own stroke format
Apple's formats are closed (`PKDrawing` data, PaperKit's `PaperMarkup`), and the website can't read
them. So **Trove stores strokes as its own data**, and every device converts that to its native
drawing view.

- **Each stroke is a small record.**
  - It's a record of kind `stroke`, encrypted and synced through the normal journal (PROTOCOL.md §3).
  - Fields:
    - `surface` (which item, attachment and page)
    - `tool` (pen, pencil, marker, highlighter…), `color`, `width`
    - `points`: a packed base64 array of `x, y, time, pressure, azimuth, altitude, width`
    - `createdAt`, `device`
  - Coordinates are in **points of the page**: the PDF page's points, the image's pixels, or a sketch
    page of 768 × 1024.
- **Why one record per stroke:**
  - Strokes from two devices simply add up. There's no merge conflict, because each stroke is
    written once.
  - Erasing is a delete (`_deleted: true`). A partial erase deletes the stroke and adds the pieces.
  - Undo is just deleting your last stroke.
- **The file underneath never changes.**
  - A PDF or photo stays exactly as imported, and the ink sits on top.
  - "Export with markup" burns the ink into a copy (a PDF with ink annotations, or a flattened
    image). That copy is saved as a new file version, so the original is still there.
- **Search:**
  - An Apple device renders the page and runs handwriting recognition: Vision now, PencilKit's new
    `PKStrokeRecognizer` once on OS 27.
  - It writes `recognizedText` on the item, which the website's search already indexes.
  - Strokes drawn on the website get recognised the next time an Apple device syncs.

## Per device

| | Drawing view | Input | Notes |
|---|---|---|---|
| **iPad** | `PKCanvasView` + `PKToolPicker` (PencilKit) | Apple Pencil: pressure, tilt, hover preview; Pencil Pro squeeze and barrel roll | Best experience. `UIPencilInteraction` gives double-tap and squeeze for switching tools. PDFs use `PDFView.pageOverlayViewProvider` with one canvas per page and `isInMarkupMode`. |
| **iPhone** | Same `PKCanvasView` | Finger (`drawingPolicy = .anyInput`) | Same code as the iPad. |
| **Mac (Intel)** | Our own `NSView` that draws strokes (shared renderer), `PKDrawing` for display | Trackpad/mouse with `NSEvent.pressure` and `NSPressureConfiguration(.primaryGeneric)`; tablets (and possibly Sidecar with the iPad's Pencil) | `PKCanvasView` doesn't exist on the native Mac app. Apple's PaperKit does, but only on macOS 26, and its data is closed, so it's not the base. |
| **Website** | `<canvas>` over the page (pdf.js already renders PDF pages) | Pointer Events: pressure and tilt, coalesced events for smooth lines (Safari 18.2+), `touch-action: none` | Vendor **perfect-freehand** (MIT, 4.5 KB, one file) for nice variable-width lines. Palm rejection: once a pen is seen, finger touches pan and zoom instead of drawing. iPad Safari needs a small fix so Scribble doesn't swallow Pencil strokes. |

**Converting on Apple devices**:
- PencilKit's `PKStrokePoint` has location, time, size, opacity, force, azimuth and altitude, so
  stroke ↔ `PKStroke` is a near-direct mapping.
- Until iOS 27 PencilKit strokes have no stable ids. The canvas delegate therefore compares the
  drawing before and after each change to find new and erased strokes, and Trove keeps its own ids.

## GoodNotes
- **Done this round**: a `.goodnotes` file shows its cover and the PDFs and images inside it.
- **Seeing your ink needs GoodNotes' PDF export.** The handwriting is in GoodNotes' own,
  undocumented format. **Recommendation**: in GoodNotes, set Auto Backup → File Format to **PDF**
  (or both). Trove's WebDAV address already receives those backups, and each new backup becomes a
  version of the same notebook item.
- **Later and optional**: decode GoodNotes ink directly. It's possible (two MIT-licensed open-source
  decoders exist to learn from), but it's fragile across GoodNotes updates.

## Phases
1. **Strokes in the core** (TroveCore + web core, tested together):
   - The stroke record and packed points, plus surface queries ("strokes on page 3 of this PDF").
   - Erase/undo as deletes.
   - Interop fixtures, like the folders and links work this round.
2. **Website first** (the user's main client today):
   - A Sketch item type.
   - Pen, highlighter, eraser, colours, undo.
   - Drawing on PDF pages and images in the viewer.
   - Pencil and touch rules (pen draws, finger pans).
   - Test with Apple Pencil in iPad Safari.
3. **iPad and iPhone app**:
   - `PKCanvasView` + tool picker for sketches.
   - PDF markup through page overlays, and image markup.
   - Squeeze or double-tap to switch tools.
   - Strokes convert both ways, so ink made on the website shows up and can be erased.
4. **Mac app**:
   - A drawing view for trackpad and mouse with pressure.
   - The same renderer shows ink everywhere.
5. **Search and export**:
   - Handwriting recognition on Apple devices → `recognizedText`.
   - "Export with markup" (flattened PDF or image) as a new version.
   - Thumbnails that include the ink.
6. **Later**:
   - Lasso select/move, shapes, text boxes, a ruler.
   - Pages with templates (lined, grid, dotted).
   - Linking a handwritten page to notes with `[[...]]`.

Each phase ships on its own and keeps everything else working. A drawing made in phase 2 opens in
phase 3 with no migration.

## Decisions for you
1. **Where to start.** The website (works today on your iPad in Safari with the Pencil, and on the
   Mac) or the iPad app first (best Pencil feel, but it needs re-sideloading every 7 days)? Plan above
   assumes the website first.
2. **GoodNotes backups as PDF.** Switching Auto Backup to PDF (or both) is the only way to see your
   handwriting from GoodNotes in Trove without decoding its private format. OK to recommend that?
3. **Sketch pages.** Infinite canvas, or pages (A4 / iPad-sized, with lined or grid templates)?
   Pages fit notes and PDFs better; infinite is nicer for brainstorming.

## Sources
The research notes, with links to Apple's docs, WWDC sessions, MDN, and the GoodNotes format write-ups,
are summarised from a research pass this session. The key ones:
- PencilKit: https://developer.apple.com/documentation/pencilkit (PKCanvasView/PKToolPicker are iOS-only; PKDrawing/PKStroke exist on macOS 11+)
- PDF markup with PencilKit, WWDC22 "What's new in PDFKit": https://developer.apple.com/videos/play/wwdc2022/10089/
- PaperKit (OS 26), WWDC25 "Meet PaperKit": https://developer.apple.com/videos/play/wwdc2025/285/
- Apple Pencil Pro squeeze and barrel roll, WWDC24: https://developer.apple.com/videos/play/wwdc2024/10214/
- PKStrokeRecognizer (OS 27), WWDC26: https://developer.apple.com/videos/play/wwdc2026/203/
- Mac pressure: https://developer.apple.com/documentation/appkit/nspressureconfiguration
- Pointer Events support: https://github.com/mdn/browser-compat-data/blob/main/api/PointerEvent.json
- Scribble vs Pencil in Safari: https://developer.apple.com/forums/thread/662874
- perfect-freehand: https://github.com/steveruizok/perfect-freehand
- GoodNotes format: https://github.com/Taylor-Nilsen/goodnotes-codec/blob/main/docs/FORMAT.md
- GoodNotes Auto Backup: https://support.goodnotes.com/hc/en-us/articles/7352786555279
