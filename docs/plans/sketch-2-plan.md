# Sketch 2: plan

Written from `docs/plans/sketch-2-prompt.md`. Reviewed in `docs/plans/sketch-2-review.md`. This
version already has the review's fixes in it; the review lists what changed.

Status: **planned and reviewed, nothing built yet.** Fixes from the review are marked (R1)–(R14).

---

## 0. The bar

These numbers are what "done" means. Every workstream ends with a check against them.

| | Target | Checked by |
|---|---|---|
| Pan and pinch | Every frame is on time at the display's rate: 120 Hz on ProMotion iPads (8.3 ms) and 60 Hz elsewhere (16.7 ms). A frame may use at most **2 ms** of main-thread work. | Signposts plus a hitch meter (S1): CI simulator test as a regression guard; the iPad for the real number |
| Sharpness, vector | Ink (with S3), paper, shapes, and text up to 400 % **never** show softer than the screen's pixels: no blur-then-sharpen at all. | Screen recording on the iPad, frame by frame (user checklist) |
| Sharpness, images and PDFs | Never blank and never below half the screen's resolution. Rendered ahead and *during* the pinch. In the normal range (25–400 %, a normal pinch) sharp within 1 frame of the pinch ending, instead of the 160 ms+ now. A picture can't get sharper than its own pixels. (R4) | Same recording |
| Opening | A 30-page notebook shows its first page in under 300 ms. | Signpost |
| Battery | No timers, display links or animations running while you're not touching the screen. | Instruments energy log (the user, once) plus a code rule: every `CADisplayLink`/animation has a stop |
| Reach | Every control is visible, or one tap away under a visible button, at every supported size. Nothing scrolls off. Nothing sits under another bar, the keyboard or a screen corner. | CI simulator screenshots at 5 sizes (V2) |

## 1. Findings: what's wrong today, and why

### 1.1 Lag when panning and zooming (iPad)

The iPad canvas is a `PKCanvasView` (a scroll view). Trove draws three CPU layers of its own:
`paperView`, `boxesView` and `overlayView` (`PencilCanvas.swift:592` `follow`).

- **Pinch: everything Trove draws is repainted on the CPU, every frame, on the main thread.**
  - When the zoom changes, `follow` resizes `paperView` to the screen and calls `setNeedsDisplay()`.
  - `drawUnder` (`:656`) then repaints for each visible page:
    - the paper (ruling and grid lines),
    - the PDF or picture backdrop,
    - every picture.
  - `boxesView` re-lays out and redraws every text box and tape (`:611`).
  - At 2732×2048 px that is far beyond a 2 ms budget. It is the main pinch lag.
- **Pan: a periodic big repaint.**
  - `paperView` and `boxesView` cover the screen plus a quarter margin.
  - When a pan leaves that margin, both are repainted in one frame: about 2.25 screens of pixels,
    synchronously. The result is a regular hitch every half screen of scrolling.
- **Per-frame bookkeeping on every scroll callback.**
  - `follow` walks every slot (`prepareBitmaps`, `:739`).
  - It calls `editor.hasBoxesOver` for every slot (`:610`).
  - It calls `editor.overlay(key)` for every visible slot (`overlayHasContent`, `:686`).
  - `trackCurrent` (`:639`) can set `editor.page`, which SwiftUI observes.
  - Each item is cheap. Together, on 30+ pages, they are not.
- **The zoom label re-renders SwiftUI on every pinch frame.**
  - `scrollViewDidZoom` → `editor.zoom = z` (`:919`).
  - `editor.zoom` is observed, so `InkZoomCorner` is invalidated every frame.
  - That is small but avoidable, and it competes with the pinch.
- **"The resolution changes and takes a bit to update" has three causes:**
  1. **PDF and picture backdrop.** `InkBackdrop.refine` (`InkBackdrop.swift:82`) waits for the
     pinch to settle, then renders the sharp piece. Until then the whole-page picture is stretched,
     so it's blurry, then it snaps sharp.
  2. **PencilKit's own ink tiles.** `PKCanvasView` re-rasterises its tiles after a zoom ends. During
     the pinch it scales the old tiles. Trove can't change this from outside (the comment at
     `PencilCanvas.swift:524`, `redrawAfterFit`, shows we already fight it).
  3. **Text boxes.** Drawn into a bitmap at the current zoom, then redrawn after the change.

### 1.2 Lag on the Mac

- `InkNSView.drawInk` (`MouseInkCanvas.swift:250`) caches one bitmap of the ink, keyed by revision,
  zoom **and the visible rect**.
- Every scroll step changes the visible rect. So **panning re-renders every stroke on the page, on
  the CPU, every frame.** Zoom does the same.
- This is the Mac's pan lag, and it grows with the number of strokes.

### 1.3 Clutter and hidden controls (`InkEditorView.swift:159`)

- **The top bar has about 30 controls in one row:**
  - undo / redo / paste;
  - 13 tools, including six separate pen types (pen, ballpoint, pencil, fountain, brush, marker);
  - shapes toggle, picture, elements, guides, favourites;
  - page, pages, settings, dark page, record, present, Ask, export, Done.
- **The tools sit in a horizontal `ScrollView`.** On anything narrower than a 13" iPad in landscape,
  some tools are scrolled out of sight with no sign they exist. This is "stuff is hidden sometimes".
- **A second row (`optionsBar`, 48 pt) lies over the top of the canvas.** So does the selection bar.
- **The zoom pill (`InkZoomCorner`, `:527`) can be hidden or awkward:**
  - It is placed with `.ignoresSafeArea(.container, edges: .bottom)` and 12/10 pt padding. On iPads
    with rounded display corners this pushes it into the corner curve, and in Stage Manager under
    the window's resize grip.
  - The selection bar (`.padding(.bottom, 52)`) and the squeeze palette can sit over it on narrow
    widths.
  - The keyboard covers it while you type in a text box.
  - The page bar below shifts it.
  - Which of these the user hit is confirmed with the simulator screenshots (V2), not guessed.
- **Ask is a fixed `.inspector`** that shares a column with the pages panel (`:88`). On an iPad in
  portrait it takes a third of the canvas, and it can't be moved or resized. This is request 5.

### 1.4 The AI can't see handwriting (`Handwriting.swift`, `StudyPanel.swift`)

Five separate causes, all confirmed from the code:

1. **Out-of-sync signatures.**
   - `Handwriting.read` skips work when the item's `inkTextSig` field matches (`Handwriting.swift:22`).
   - That field is on the item record, so **it syncs**.
   - The page-by-page text (`HandwritingPages`) is in **Caches on this device only** (`:103`).
   - So handwriting read on another device, or a cache the system cleared, gives a matching
     signature with no local pages. The chat then gets no handwriting at all.
   - When every page is empty, `prepare` falls back to the item's whole-document text
     (`StudyPanel.swift:86`). For a PDF that is its `ocrText`. **That is exactly "it can see PDFs
     but not handwriting".**
2. **Context is built once per panel.** `send` builds the context only `if context == nil`
   (`StudyPanel.swift:107`). Anything written after Ask opened is invisible until the panel is
   closed and reopened.
3. **Ink on PDFs and pictures is never read.** `Handwriting.read` returns early unless
   `item.kind == .sketch` (`:18`).
4. **Battery saving reads badly.** In battery-saving mode Vision runs in `fast` mode (`:57`). Fast
   mode is poor at handwriting.
5. **Drawings are invisible.** Arrows, diagrams, circled words and maths layout never reach the
   model; it only gets Vision's text lines.

### 1.5 AI output

- **Math Assist answers are typed text boxes** in a rounded font, in the pen's colour
  (`MathAssistController.swift:132` `place`). They don't look written. The eraser's ink modes skip
  them; they're elements, not strokes.
- **Diagrams are placed at a fixed origin**: 48,72 on a page, or near the visible centre on a canvas
  (`StudyPanel.swift:146`). They are made of typed text boxes and perfect rectangles.
- **They are added through `library` directly**, so they are **not one undo step** (each piece goes
  through `library.addStroke`/`addElement`, outside `InkEditorModel`'s undo stack).
- **They aren't grouped**, so you can't move them as one. The stroke `group` field exists
  (PROTOCOL.md §ink) but isn't used here.

---

## 2. Workstreams

### S. Speed: no lag, anywhere in the sketch editor

**S1. Measure first (before any change).**
- **Signposts.** Wrap these in `Perf` signposts (`App/Sources/Services/Perf.swift`):
  - `follow`;
  - every `draw(_:)` of Trove's layers;
  - `InkBackdrop` renders;
  - the Mac's `drawInk`.
- **Hitch meter (`App/Sources/Services/FrameMeter.swift`).**
  - A `CADisplayLink` that runs only while a pan or pinch is in progress. It starts on
    `scrollViewWillBeginDragging`/`Zooming` and stops on end/decelerate-end.
  - It counts frames later than 1.5× the display's duration.
  - It is shown in a **new** Settings → Diagnostics section as "Last pan: 0 slow frames of 214".
    The section doesn't exist yet. (R11)
  - It costs nothing when idle.
- **Test notebook generator (TroveCore, `Drawing/InkStressFixture.swift`).**
  - Deterministic, from a seed.
  - 30 pages, 600 strokes per page (18 000 total), 40 text boxes, 10 pictures, a 30-page PDF section,
    and ruled and grid paper.
  - Reached from Settings → Diagnostics → "Make a test notebook" (debug builds, and release behind
    a long-press so the user can run it on the iPad).
- **CI regression guard.**
  - A **new** `TroveUITests` target in `project.yml`. It runs only on the simulator, so it needs no
    signing. (R11)
  - Its XCUITest (`SketchScrollTests`) opens the test notebook in the iPad simulator.
  - It flings and pinches, and reports `XCTOSSignpostMetric.scrollingAndDecelerationMetric` plus
    our own signposts, into `ci-logs`.
  - Simulator timings are not the device's. This catches regressions (a 2× jump), not absolute
    targets.

**S2. iPad: stop repainting on the main thread while moving.** Built in this order, measuring after
each step:

1. **A zoom container, not a repaint (R1).**
   - `PKCanvasView` zooms only PencilKit's private content view. Our subviews sit in content
     coordinates but aren't scaled, and putting layers inside PencilKit's view isn't safe.
   - So all of Trove's page layers live in one `PageLayersContainer` layer.
     `scrollViewDidZoom` sets its `transform` to the zoom scale, with implicit animations off.
   - That is one property write per frame, and **nothing is repainted during a pinch**.
   - Each page gets a `PageHostLayer` in it, at the page's frame at 100 %.
   - The overlay (lasso, eraser circle, laser) stays a screen-space view, but only exists while it
     has content.
2. **Paper as GPU layers, drawn once.**
   - Ruled lines, grids and dots become `CAReplicatorLayer`s of thin solid-colour `CALayer`s inside
     the zoomed content.
   - Margins and the page edge are plain layers too.
   - A solid-colour layer has no bitmap, so it is **sharp at every zoom with zero redraw**, and
     pinching costs only the GPU.
   - When a zoom ends, line thickness becomes max(nominal, 1 px ÷ zoom), so lines don't vanish when
     zoomed out. That is a property change, not a repaint. (R14)
   - Fancy papers (pictures, templates such as planners) go through the picture path (step 3).
   - New: `PaperLayers.swift`. Its geometry (line positions, dot pitch) comes from a new pure
     function in TroveCore, `InkPaper.lines(spec)`, already the source for `InkRenderer.drawBackground`.
     Tests check both against each other.
3. **Pictures and PDF pages: tiles in levels, made ahead of time.**
   - New `TileCache` (iPad and Mac share it).
   - Each page is cut into 512-px tiles at power-of-two levels: 0.25×, 0.5×, 1×, 2×, 4× (times
     display scale).
   - Rendered off the main thread. PDFs go through the existing `InkRenderer` CGPDF path (what
     `InkBackdrop` already does off the main thread), with one `CGPDFDocument` per worker. PDFKit's
     `PDFDocument` isn't thread-safe. (R12)
   - Pictures go through `CGImageSource` thumbnails.
   - While idle, the cache **renders the next level up and down for what's on screen**.
   - **During a pinch**, the moment the zoom crosses a level, the following level is requested.
   - A normal pinch therefore always finds a sharper level ready. A very fast one shows the level
     below, at no less than half resolution, for a few frames. (R4)
   - Shown with `CATiledLayer`-style swapping: the best tile available, never blank.
     - The coarsest level of every nearby page is always kept, about 150 KB per page.
     - A memory cap of 64 MB on the iPad drops far pages first.
   - Replaces `InkBackdrop`'s "whole picture + one detail piece after 160 ms".
4. **Text boxes and tape: one layer per box.**
   - Rendered at **2× the current zoom** (headroom). While idle, the boxes on screen also prerender
     4×; they are few and small. (R5)
   - A pinch up to 4× therefore needs no redraw.
   - Typing redraws only the box being typed in.
5. **Bookkeeping per frame gets O(visible).**
   - Slots are kept in a sorted array, with a binary search for what's visible.
   - `hasBoxesOver` and the overlay's emptiness are cached per page revision.
   - `trackCurrent` only writes `editor.page` when it changes, after the scroll ends.
6. **The zoom label stops invalidating SwiftUI per frame.**
   - `editor.zoom` is published at most every 50 ms during a gesture (a small `@Observable`
     `ZoomReadout` of its own), and exactly at the end.

**S2-Mac. The Mac, until S3.**
- Today `drawInk`'s cache is keyed by the visible rect.
- Instead, cache the **whole page's** ink at a zoom quantised to powers of √2. Above 16 M pixels,
  use 1024-px tiles from `TileCache`.
- Panning then reuses the picture. Zoom shows the nearest level scaled until the new one, rendered
  off the main thread, replaces it.
- The paper is drawn the same way.

**S3. Committed ink: Trove's own GPU renderer (decision, with a gate).**

- **Why not stay with PencilKit's tiles.**
  - `PKCanvasView` always scales old tiles during a pinch and re-rasterises after. That is the
    "goes soft then sharp" the user sees, and nothing outside PencilKit can stop it.
  - It also forces the `redrawAfterFit` hack, and slow full replacements of the drawing (`apply`).
  - GoodNotes, Notability and Freeform-class apps draw committed ink themselves for this reason.
- **The plan: `InkMetalView`.**
  - **One** screen-sized `MTKView`, pinned to the visible bounds behind PencilKit's content, used on
    both the iPad and the Mac (the Mac loses its CPU `drawInk` entirely).
  - Not one per page: a page at 400 % would need a drawable of about 500 MB. (R2)
  - It is paused (`enableSetNeedsDisplay`) and draws only when the view moves or the ink changes, so
    there is no idle display link.
  - `presentsWithTransaction = true` keeps it in the same frame as UIKit's scrolling.
  - **Geometry.** Each stroke is turned into triangles once, by its id and version, using the
    existing `InkOutline.outline`. That code is already in TroveCore, already matched to the website
    by fixtures, and is the outline exports use.
    - New `InkTessellator` (TroveCore): turns outlines and even lines (with dashes, dots, caps,
      arrowheads) into a triangle list. Tested on Linux (closed, no NaNs, area ≈ the outline's area,
      deterministic).
  - **Drawing.**
    - One vertex buffer per page, appended to while you write, rebuilt in the background after an
      erase.
    - Zoom and offset are uniforms, so the ink is **vector-sharp at every zoom on every frame**.
    - Each visible page draws in **`createdAt` order**. Runs of strokes with the same blend mode are
      batched into one draw call, so a pen stroke over a highlight stays on top. (R3)
    - Dark page: the black/white swap (`InkDark`) is a colour uniform, with no re-tessellation.
  - **Inks.**
    - Pen, ballpoint, fountain, brush and marker: solid fills from the outline.
    - Highlighter: multiply blending, in its place in the stroke order (R3).
    - Pencil: a grain texture sampled in page space, so it doesn't swim.
    - Look-match tests compare GPU renders to `InkRenderer` renders of the same strokes (CI:
      render both in the simulator, compare at most 2 % pixel difference).
  - **Writing.**
    - PencilKit **stays the input on the iPad.** Its latency, prediction and Pencil features are the
      best there is.
    - Trove's eraser and lasso already work on the model (`toolTouch`), not on the `PKDrawing`, so
      PencilKit only ever needs the live stroke. Confirm this when building it.
    - While a stroke is being written, `PKCanvasView` shows only that stroke.
    - When the stroke ends, it's converted (as today) and added to the Metal page's buffer.
    - The stroke is removed from PencilKit on the frame the Metal frame containing it is presented
      (`MTKView` presented handler), so there's no flicker and no gap.
    - The Mac draws the live stroke in Metal too (no PencilKit there).
- **The gate.**
  - S3 ships behind Settings → Sketch → "New ink renderer" (default off) until the user has tried it
    on the iPad.
  - It becomes the default once the user agrees it looks the same and feels faster.
  - If the look can't be matched for an ink (the pencil is the risk), that ink alone keeps a
    PencilKit layer, and the setting says so.
- **Unchanged.** Exports, thumbnails and the website keep `InkRenderer` and the JS renderer.

**S4. Opening and paging.** The first page is drawn from the stroke records before the rest load
(stream pages in order of distance from the one being opened). A 300 ms target for 30 pages.

**S5. "Anywhere in the app" sweep (after S1–S3).**
- Use the same hitch meter on: the library grid scroll, the notes editor, the PDF reader, the
  clipboard palette.
- Each gets a signpost and one CI scroll test.
- Fix whatever goes over budget (each found item becomes a MASTER_PLAN P-item).

### T. Toolbar and controls: sleek, nothing hidden

**T1. One compact bar, with the tool's options inline (R8).** Mock-up at iPad full width:

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ ‹ Biology ▾ │ ✎● ▤ ⌫ ◌ ⬠ T ⊕ │ ● ● ● ●  ·  •  ● │                      ↶ ↷   ✦ Ask   ⋯ │
└───────────────────────────────────────────────────────────────────────────────────────────┘
  done+title    pens hi eraser lasso   the selected tool's 4 colours        undo redo  AI  more
                shapes text insert     and 3 sizes (inline, like GoodNotes)
```

- **No second row over the canvas at all.** The selected tool's 4 most-used colours and 3 sizes sit
  in the bar. Tapping the selected tool again opens its **tray**, a popover under it (T2).
- **Pens (`✎`, one button).**
  - Remembers the last pen type and shows its colour dot.
  - The six pen types (pen, ballpoint, pencil, fountain, brush, marker) become a segmented row in the
    pen's tray.
  - 13 tool buttons become 7.
- **The other tool buttons:** highlighter (`▤`), eraser (`⌫`), lasso (`◌`), shapes (`⬠`, also holds
  the "shapes come out clean" toggle), text (`T`).
- **Insert (`⊕`):** picture (Photos, Files), elements, tape, ruler, protractor, laser, page from
  template, record audio.
- **Done and title ("‹ Biology ▾").** `‹` is Done.
  - The title menu has: rename, page settings (paper, colour, size), pages panel, dark page, export
    (PDF, GoodNotes), present, notebook info.
- **More (`⋯`):**
  - the editor's settings: Math Assist, scribble to erase, compact points, opening zoom, new ink
    renderer, Math Assist answers;
  - "Customise toolbar…".
- **Ask (`✦ Ask`)** opens the floating box (A4).
- **Favourites** live in the pen's tray (top row) and in a `★` menu next to the inline options.
- **Keyboard (iPad and Mac):**
  - P pen, H highlighter, E eraser, L lasso, S shapes, T text;
  - ⌘K Ask;
  - ⌘Z / ⇧⌘Z undo and redo;
  - ⌘+ / ⌘- / ⌘0 zoom. (R14)
- **Width rules.** No `ScrollView` anywhere in the bar. Groups have priorities. When the bar is
  narrow, the lowest-priority groups fold into `⋯` or the tray, as a group, in this order:
  1. inline sizes → tray;
  2. inline colours → the tool's colour dot (tap opens the tray);
  3. Insert → `⋯`;
  4. the title becomes an icon;
  5. shapes and text → `⋯`.
  - Pens, highlighter, eraser, lasso, undo, Ask and `⋯` never fold.
  - Done by a SwiftUI `Layout` (`AdaptiveToolbarLayout`), not by guessing widths. Its fold decision
    is a pure function in TroveCore (`ToolbarFold`), tested on Linux at the four widths below.

At other widths:

```
iPad ½ (Split View, ~500 pt)
│ ‹ │ ✎● ▤ ⌫ ◌ ⬠ T │ ● ● ● ● │   ↶ ↷  ✦  ⋯ │

iPhone (bottom bar, thumb reach; title + Done stay in the nav bar)
│ ✎● ▤ ⌫ ◌ ⊕ │ ↶ ↷ ✦ ⋯ │

Mac (window toolbar, unified with the title bar; same order, keyboard shortcuts on every tool)
│ ● ● ●  Biology ▾ │ ✎● ▤ ⌫ ◌ ⬠ T ⊕ │ ● ● ● ●  · • ● │        ↶ ↷  ✦ Ask  ⋯ │
```

**T2. The tool's tray (a popover, not an overlay row).**
- Opened by tapping the selected tool again, or its colour dot when folded.
- Contents:
  - all colours (`InkColorPresets` plus the picker);
  - the size slider;
  - the tool's modes (eraser kind, highlighter-only, protect tape, laser line/dot, lasso picks,
    shape kinds, text style);
  - for pens: the pen type and favourites ("Save pen" is here).
- It closes when you touch the canvas. It never stays over the page while you write.
- **Lasso.** Its actions stay in the selection bar (`selectionBar`). That bar is now placed by the
  HUD layout (T4), above the zoom cluster, never on it.

**T3. Customise toolbar.**
- `⋯` → "Customise toolbar…" opens a sheet listing every tool and action, each with a toggle and a
  drag handle.
- Stored per device (`UserDefaults`, key `ink.toolbar`), with a reset button.
- Default as in T1. This is how "access everything quickly" stays true for people who use a hidden
  tool all the time.

**T4. HUD layout: nothing ever covers anything.**
- One `ZStack` layer, `EditorHUD`, owns every floating control:
  - the zoom cluster;
  - the page indicator;
  - the selection bar;
  - the tool tray;
  - the AI placement controls (A3);
  - the "AI is looking" chip (A6);
  - the floating Ask box (A4).
- Each declares a preferred anchor. A small solver (TroveCore `HUDPlacement`, pure, tested on Linux)
  places them in priority order inside the safe area, minus the keyboard and the Ask box's rect,
  avoiding overlaps.
  - The selection bar moves above the zoom cluster rather than over it.
  - If two can't both fit, the lower-priority one collapses to an icon.
- **Corners:** no HUD control uses `ignoresSafeArea`. Everything sits inside the safe area plus
  8 pt. That keeps it clear of the rounded corners, the home indicator and the Stage Manager grip.
  (R10)
- **Present mode** hides everything except the end-presentation button. (R14)

**T5. Zoom: your own 100 %.**
- **The zoom pill shows the zoom relative to your 100 %.**
- **Its menu:**
  - "Go to 100 %"
  - "Set current zoom as my 100 %"
  - "Reset 100 % to original"
  - Fit page, Fit width
  - 50 / 150 / 200 / 400 %
  - zoom in / out (also ⌘+ / ⌘- / ⌘0)
- **Two-finger double-tap** on the canvas goes to your 100 % (and back to where you were if you're
  already there).
- **Stored:** one value per device (`zoom.base`). The "original" 100 % is 1 point = 1 point at the
  screen's scale (today's meaning). A per-notebook override is possible later, not built now. (R9)
- **TroveCore `ZoomBase`:** relative ↔ absolute conversion and preset generation, tested on Linux.
- When a sketch opens, "When a drawing opens" gets a third choice: "At my 100 %".

**T6. A new sketch asks for its page settings first** (the user, 2026-11-03: "when u create a new
sketch it should immediately ask u about page settings n stuff").
- Today `AppModel.newSketch` (`AppModel.swift:525`) creates a sketch with defaults and opens it.
- Now every "New sketch" (sidebar, menus, ⌘ shortcut, command palette, iPhone) first opens a
  **New sketch** sheet:
  - **Name** (focused, optional; "Sketch" if left empty).
  - **Kind:** Notebook (pages) · Whiteboard (one big page) · Endless canvas.
  - **Paper**, as a row of live thumbnails: blank, ruled (narrow / wide), grid, dots, Cornell, music,
    and the planners and templates.
  - **Size and orientation:** A4, A5, Letter, iPad screen; portrait / landscape. Notebooks only.
  - **Paper colour:** white, cream, grey, dark.
  - **Cover:** notebooks only; uses the existing `NotebookCover` picker.
  - **Folder:** preset to where you clicked "New sketch here".
- **Every choice starts at what you used last time**, so a big **Create** button (Return) makes the
  usual sketch in one tap. A small preview of the first page updates as you choose.
- **"Ask every time"** sits at the bottom of the sheet, also in Settings → Sketch. Turning it off
  makes "New sketch" create with your last choices straight away, as it does now. A long-press or
  ⌥-click on "New sketch" always shows the sheet.
- **Shared model.** The sheet uses the same page model as the editor's Page settings
  (`InkPageSettings`), so the two can't drift.
  - The "last used" set is a small `NewSketchDefaults` value (TroveCore, Codable, Linux-tested),
    stored per device.
- **iPhone:** the same sheet with a medium detent.
- **Mac:** a sheet on the window.
- **Verified by:** a V2 screenshot of the sheet at all sizes, and a UI test (New sketch → change
  paper → Create → the editor opens with that paper).

### A. AI on the page

**A1. Handwriting synthesis (TroveCore `Drawing/InkHandwriting.swift`).**

Turns text into real `InkLine` strokes that look handwritten. Entirely on the device; no AI tokens.

- **Glyph source.** A single-line (centre-line) font, so each letter is pen paths, not outlines.
  - Candidate: the **EMS / Hershey Text** single-line fonts from Evil Mad Scientist ("EMS Allure",
    "EMS Delight", "EMS Readability"). Published as SVG fonts.
  - **Their licence is checked before use** (the expectation is SIL OFL 1.1; Hershey-derived glyphs
    carry the NBS attribution).
  - Build-time converter (`scripts/glyphs.py`): SVG font → a compact JSON table of polylines per
    glyph, with advance and baseline, at about 60 KB per style, in `Packages/TroveCore/Resources`.
  - Two styles to start. **The default is natural, neat handwriting** (the user, 2026-11-03: "near
    handwriting that still looks real"): clearly a person's writing, not a font, but tidy enough
    to read at a glance. A looser script is the second choice in Settings → AI → Handwriting.
  - The single-line font is only the skeleton. The humaniser (below) is what makes it look real, and
    its ranges are tuned on the iPad until it does.
- **Size: match the writing around it** (the user: "should mimic size of writing around it … like
  if it's filling out a fill in the gaps it should be a similar size").
  - `InkHandwriting.sizeNear(rect, strokes:, lines:)` (TroveCore, pure) estimates the local
    **x-height and slant** from the user's own ink near the target. It looks at strokes within about
    3 line-heights:
    - Vision's line boxes when they exist;
    - otherwise stroke clusters, using the median height of letter-sized strokes, ignoring long
      lines, arrows and drawings.
  - Nearer writing counts more. Writing on the same line counts most.
  - **Gaps** (fill-in-the-blanks: a `____` line, a space between words, an empty table cell or box)
    take the size of the writing **on the same line**, then sit on the blank's baseline or in the
    box's middle.
  - The local slant is copied too, within ±8°, so it leans like the user's writing.
  - Fallbacks, in order:
    1. the writing on the same line;
    2. nearby writing;
    3. the ruling (x-height ≈ 45 % of the line spacing);
    4. the target box (A3);
    5. the median x-height of all ink on the page;
    6. 5 mm.
  - When nothing fits (a long answer in a small gap), it shrinks to at least 70 % of the local size,
    then wraps. Past that it says so and offers to place it next to the gap with an arrow, rather
    than writing tiny.
  - Tests (Linux): synthetic pages with writing at 3 sizes. The output's x-height is within ±15 %
    of the writing on the same line, a gap uses the same line's size, and the fallback order holds.
- **Layout.**
  - Wrap text to a width.
  - Line height = the page's ruling when the paper is ruled (`InkPaper.lines`), so writing **sits on
    the lines**. Otherwise it's 1.6× the x-height from the size rule above.
  - Maths gets its own layout: fractions stacked, superscripts raised. It is a small subset driven by
    `MathExpression`'s tree, so Math Assist answers like `x = 3/4` or `2.5×10⁴` look written.
- **Humaniser** (deterministic, seeded from the text, the page and the position, so every device
  makes identical strokes):
  - per-letter slant ±3°, size ±6 %, baseline drift (a slow random walk, ±4 % of the line height),
    and letter spacing ±8 %;
  - each glyph drawn from one of 3 slightly perturbed versions of itself, chosen pseudo-randomly, so
    repeated letters don't match exactly;
  - points resampled to the pen's spacing, plus a 1–2 % jitter along the normal;
  - pressure: a ramp at the start and end of each stroke, faster strokes thinner; timing t from a
    speed model (fast on straights, slow on curves). Replay ("Play from here") then looks like real
    writing;
  - pen-lifts: letters within a word may join when the style is script.
- **Output.**
  - `[InkLine]` in the user's current pen type, width and colour, unless the caller sets them (Math
    Assist sets light blue).
  - All strokes share a `group` id, so they move as one with the lasso and ungroup normally.
- **Tests (Linux):** deterministic output; fits its box; every point finite; stays on ruled lines
  ±10 %; no two consecutive letters overlap; 1 000 characters laid out in under 5 ms (bench test).
- **Cost:** zero tokens. The AI sends plain text or a diagram spec (words and structure). Everything
  visual is made on the device.

**A2. Math Assist answers in light-blue handwriting.**
- `MathAssistController.place` writes strokes from A1 instead of a text box.
- **Colour.** Assist blue, `#5AA9E6`, is a new constant `InkColors.assist`. On a dark page it is
  `#7CC4F5`, which keeps contrast (checked by a contrast test against both page colours, WCAG ≥ 3:1).
- **Width.** The current pen's width, scaled to the line's height. Pen type: ballpoint.
- **Erasable like ink, because it is ink.**
  - Rub out part of it and the rest stays.
  - Rub out all of it and Math Assist **won't write that answer again** until the line itself is
    changed. Keyed by the line's stroke key (`MathLine.key`).
- **Re-solve.** When the line changes, the controller deletes only the answer strokes it wrote that
  are untouched (same id, same version). If you've edited its answer, it's yours. It then writes the
  new one beside it.
- **Marked as AI-written.** A new optional stroke field, `by: "assist"` (PROTOCOL.md, with Swift and
  JS round-trip tests; older apps ignore unknown fields). Used for:
  - the "don't re-solve over my edits" rule;
  - "Remove all Math Assist answers on this page";
  - a later "show AI writing faintly" option.
- **Where it goes (R6).**
  - Right of the line's **rightmost ink**, not right of the `=`.
  - If you've written your own answer (`2+2=5`), the ✗ and the correct value come after it.
  - Free space is checked first. If there's no room on the line, the answer drops just below it,
    with a small arrow.
- **Undo (R6).** Answer strokes are linked to the `=` strokes that caused them. Undo or erase the
  `=`, and the untouched answer strokes go too.
- **Detection (R6).** Strokes with `by` set never feed `EqualsDetector` (Math Assist's own `=`
  can't trigger itself). They are still included by `MathLine.gather`, so chained `… = 48 = …` reads.
- **Memory of erased answers (R6).** Kept in a small per-item file in Caches
  (`math-dismissed.json`). It is local on purpose: Math Assist only runs for strokes written on this
  device.
- **"?" for unsure** stays, written in grey handwriting.
- **The ✗ check mark** is a handwritten cross plus the right value.
- **Old typed answers.** Text-box answers from before stay as they are. A one-tap "Rewrite old answers
  as ink" is in `⋯`.

**A3. Placing AI output: you choose where and how big.**

Used by diagrams, "write this on the page" answers, summaries, tables, labels and edits.

1. **The AI's reply comes back.** The Ask box shows a small preview with **Place**, **Tweak** and
   **Discard**.
2. **Place:** the Ask box shrinks out of the way, the canvas dims slightly, and a hint says "Drag
   where it should go".
   - Drag a rectangle: it's placed in that rectangle.
   - Tap: it's placed at a sensible default size at the tap.
   - With a lasso selection already made, "Place" offers "Next to the selection".
3. **Ghost preview.** The output appears as a translucent ghost **in the rectangle, laid out to fit
   it**. Text wraps, a diagram reflows: a wide box makes a flow left to right, a tall one top to
   bottom (`DiagramSpec.layout(in:)`, new).
   - Corner handles resize; the layout recomputes live (on the device, no tokens).
   - The ghost is drawn in handwriting from A1 with the chosen pen.
4. **Floating controls by the ghost** (placed by T4):
   - **Keep**;
   - **Tweak…** (type what to change; a cheap AI call returns a new spec, and the ghost updates in
     place);
   - **Pen** (pen type and colour, from your palette and favourites);
   - **Style** (handwriting / neat print / typed);
   - **Cancel**.
5. **Keep** writes everything as real strokes:
   - in **one group**;
   - as **one undo step**: a new `InkEditorModel.commitBatch(strokes:elements:)` that adds them
     through the editor's undo stack, replacing `keepDiagram`'s direct `library` calls;
   - with `by: "ai"`.
- **Edits to your own writing** ("fix the spelling", "label this") **never delete your ink.**
  - A correction is written as a strike-through plus the fix nearby, or as an arrow plus a label.
  - Deleting needs a separate "Remove the original" button on the ghost.
- **Diagrams in handwriting.**
  - Boxes and arrows are drawn as slightly imperfect hand lines: corners overshoot by 1–2 pt, edges
    bow by up to 0.5 %, arrowheads are two strokes.
  - Labels use A1.
  - Colours: the diagram spec may give each node a role (`main`, `accent`, `muted`). These map to
    your current pen colour, your second favourite colour and grey. The AI never picks hex values.

**A4. The floating Ask box.**
- **A panel over the canvas** (in `EditorHUD`), not an inspector.
- **Move:** drag by its header, anywhere. It snaps to edges and corners within 12 pt, and can be
  flung to a corner.
- **Resize:** from any edge or corner. Minimum 260×200 pt; maximum the canvas minus 24 pt.
  "Different shapes" are free: tall and narrow, short and wide, anything in between.
- **Compact / expanded:**
  - Double-tap the header to switch between your expanded size and a compact one-line bar (input
    only, with the last answer as a toast).
  - Minimise to a small "✦" bubble at the edge.
- **Remembered** per device, per orientation and per size class (`ask.frame.<class>`), as fractions
  of the canvas, so a rotation keeps it in the same place relative to the screen.
- **Writing under it (R7).**
  - The Pencil works everywhere outside the box.
  - With **Pencil hover** (M2-or-later iPads with Pencil 2 or Pro): while the Pencil hovers over the
    box and the box isn't being typed in, it fades to 30 % and stops taking touches
    (`allowsHitTesting(false)`), so you can write underneath. It comes back when the hover leaves.
  - Without hover, move or minimise it. SwiftUI can't pass a Pencil touch through to the canvas
    otherwise.
  - Drag it away with a finger at any time.
- **iPhone:** a sheet with detents (small / medium / large). A floating window is unusable on 390 pt.
- **Mac:** the same panel inside the window, plus "Open in separate window" (a `Window` scene),
  later.
- **The pages panel stays an inspector.** It is a list beside the pages, not something you'd float.
- **Accessibility:** move and resize also via buttons in the header's menu (VoiceOver: "Move to top
  right", "Make bigger").

**A5. The AI reads handwriting properly.**

The fixes, in the order of the findings:

1. **Signature next to the cache.**
   - The local `HandwritingPages` file stores the signature it was read at.
   - `Handwriting.read` trusts the synced `inkTextSig` only for the search text, never for the
     chat's pages.
   - Pages missing locally are re-read, page by page, by their own `pageSig` (already per page).
   - Test: a TroveCore-level model of the decision (`HandwritingFreshness.pagesToRead(local:sig:)`)
     with Linux tests for "cache cleared" and "read on another device".
2. **Context refreshed before every question.**
   - `send` calls a cheap `refresh()` that re-reads only pages whose stroke signature changed since
     the context was built (per-page signatures, as above).
   - It rebuilds `StudyContext` without re-reading the rest.
   - The prompt cache is keyed by the context text, so an unchanged notebook keeps its cache hit.
3. **Ink on PDFs and pictures** is read too. Its text goes in each page's lines next to the PDF's own
   text for that page (PDF text per page: `PDFPage.string`, also per page).
4. **The chat always uses Vision's accurate mode** for the pages it's about to send. Fast mode stays
   for background search indexing.
5. **The AI can look at a page** when text isn't enough.
   - When Vision's confidence for a page is low, or the page has a lot of non-text ink (strokes not
     inside any recognised line box: >25 % of ink length), that page is also sent as a picture.
   - 1092 px on the long side, JPEG.
   - **Cost:** images count about width × height ÷ 750 tokens. An A4 page at 772×1092 is
     ≈ 1 100 tokens; a 4:3 page ≈ 1 600. That is **$0.0001–0.0002 per page** at $0.10 per million.
     Cached in the prompt cache for the session. (R13)
   - Capped at 6 pictures per question (the pages nearest the question's scope).
   - **It asks first** (the user, 2026-11-03). The first time in a session a question would send
     page pictures, the Ask box shows:
     > "To answer this I'd look at 3 pages as pictures (≈ $0.0005). **Allow** · **Allow for this
     > session** · **Always allow** · **Not now**"
     - "Not now" answers from the text only, and says the answer may miss drawings.
     - The choices are remembered in Settings → AI → "Page pictures": **Ask each session**
       (default) · **Always** · **Never**. It can be changed there any time.
     - A temporary chat follows the same setting.
     - Test: the consent decision is a pure function (`PictureConsent`) in TroveCore, with Linux
       tests for session, forever and never.
- **"What the AI sees"** in the Ask box's menu shows the exact text per page, and which pages go as
  pictures. Transparency, and the user's own way to debug.
- **Scope chips in the Ask box:** "Whole notebook" · "This page" · "Selection" (enabled when a
  lasso selection exists). The scope trims the context, which is cheaper too.

**A6. "The AI is looking here."**
- **What it is.** A thin animated outline, drawn in the overlay layer, in the accent colour at 45 %
  opacity:
  - 1.5 pt, rounded corners;
  - a slow travelling dash (one loop in 2 s);
  - **stops** when the work ends, then fades out over 0.4 s.
- **When it shows:**
  - **While reading** (`prepare`/`refresh`): around each page as Vision reads it, then around each
    line box as the context is assembled. Fast, roughly a blink per page.
  - **While the AI thinks:** around the scope (the page, the selection, or for a whole notebook just
    a small chip "✦ Reading 12 pages" by the zoom cluster rather than outlines everywhere).
  - **When the answer cites lines** (`[p2.4]`): those line boxes keep a still, faint outline (the
    existing `studyHighlights`, restyled to match) until you tap away.
  - **When placing:** the ghost has the same outline style, so "where the AI is" reads consistently.
- **Non-intrusive.** No layout change, no dimming (except during Place), not over the Pencil's nib.
  - Reduce Motion → a static outline.
  - Low Power Mode → static, and only the scope.

**A7. What every AI action costs** (Haiku 5.5, $0.10 / $0.50 per million; a 20-page notebook is about
8 000 tokens of context, cached after the first question at 10 % of the input price):

| Action | Tokens in / out | Cost |
|---|---|---|
| First question about a 20-page notebook (includes the 1.25× cache write) | 8.5k / 300 | $0.0012 |
| Each follow-up (cache hit) | 0.8k + 8k cached / 300 | $0.0003 |
| Page pictures, when needed (each) | 1.1–1.6k / 0 | $0.0001–0.0002 |
| Diagram (spec only) | 1k / 250 | $0.0002 |
| Tweak a diagram | 0.6k / 250 | $0.0002 |
| Writing on the page (A1), placing (A3), Math Assist | 0 | $0 |

At 50 questions a day that is about $1 a month at most.

### V. Verification

- **V1. Linux tests (TroveCore):** `InkTessellator`, `InkPaper.lines`, `HUDPlacement`, `ToolbarFold`, `ZoomBase`,
  `InkHandwriting` (layout, humaniser determinism, ruled-line fit, maths layout),
  `DiagramSpec.layout(in:)`, `HandwritingFreshness`, `InkStressFixture`, and the `by` field round
  trip (with a JS test in `web/test`).
- **V2. CI simulator screenshots** (a new `ui-shots` job in `apps.yml`, on demand and on main).
  - The editor at iPad 13" landscape and portrait, iPad 11" in ½ Split View, iPhone 16 and the Mac
    window at 900×600.
  - States: tool tray open; selection bar; keyboard up (text box); Ask box floating; Place mode;
    the zoom menu.
  - Images go to `ci-logs/shots/`, and each run asserts **no HUD frames overlap and all lie inside
    the safe area** (the solver's output is logged and checked).
- **V3. CI perf guard:** `SketchScrollTests` (S1) on the simulator. It fails on a regression of more
  than 50 % against the stored baseline.
- **V4. The user's iPad checklist**, in NOTES.md:
  - pan and pinch the test notebook, with the hitch meter showing 0;
  - screen-record a pinch on a PDF and on ink, and check that nothing goes soft;
  - write `12×4=`: an answer appears in blue handwriting, and you can rub half of it out;
  - Ask about handwriting on a page;
  - place a diagram into a dragged box, then tweak it;
  - move and resize the Ask box;
  - the toolbar at full screen and in Split View.

---

## 3. Order of work

Each step is one or a few commits. Each builds on CI with all tests green, and NOTES.md is updated
as it lands.

Nothing in `App/` compiles on Linux. So each step:
- lands its pure logic in TroveCore first, with Linux tests;
- then batches its app changes into one CI run, to keep the build-fix loop short. (R14)

1. **S1** measurement: signposts, hitch meter, stress notebook, CI scroll test. *Nothing else is
   judged without it.*
2. **A5.1–A5.4**, the AI reads handwriting. Small, a clear bug, and a big user-visible win.
3. **S2.1–S2.6** iPad layers, then **S2-Mac**.
4. **T4 + T5**: the HUD solver, zoom cluster and custom 100 %. This fixes "hidden zoom pill" early.
5. **T1–T3** toolbar, tool tray, customise. **T6** new-sketch sheet (small; it can go any time after
   T4).
6. **A1** handwriting synthesis (glyph licence checked first, the Q2 style pick).
7. **A2** Math Assist in blue handwriting.
8. **A4** floating Ask box, **A6** looking outline, **A5.5** page pictures, plus "What the AI sees"
   and scope.
9. **A3** placement, ghost, tweak, one-undo commit, handwritten diagrams.
10. **S3** Metal renderer behind its setting: tessellator, then the iPad, then the Mac, then
    look-match tests.
11. **S4, S5**: opening speed and the app-wide lag sweep.
12. **Your own handwriting** (A8, below) once the rest is in the user's hands.

**A8. Later: "your handwriting".**
- A guided sheet: write a set of pangrams once. Vision's character boxes, plus stroke timing,
  segment them into glyphs.
- 3 or more samples per character are kept as a synced `handwriting-style` record (local-only if the
  user prefers).
- A1 then draws from your glyphs, with the same humaniser.
- Writing joins between letters are learned from your samples' entry and exit strokes.
- Not in this round's acceptance. Planned so A1's glyph table format already allows it (glyph =
  variants × polylines with pressure and timing).

## 4. Risks and fallbacks

| Risk | Fallback |
|---|---|
| The Metal ink doesn't match PencilKit's look (pencil grain) | Per-ink fallback to a PencilKit layer. The setting stays off by default until the user approves. |
| A hand-off flicker when a stroke moves from PencilKit to Metal | Remove the PK stroke on the presented handler. If it still flickers, keep the last 3 strokes in PK until the next idle frame. |
| Tile memory on older iPads | 64 MB cap. Far pages drop first. The coarsest level always stays. |
| The glyph licence is unsuitable | Hershey's original public NBS data, or draw our own 95 glyphs (a day's work with the stroke recorder in the app, saved as the same JSON). |
| Handwriting looks robotic | The humaniser's ranges are settings in the diagnostics view, so tuning on the iPad needs no new build. Then A8. |
| Simulator screenshots and perf don't match the device | They are guards, not targets. Device numbers come from the hitch meter. |
| Floating Ask box gets in the way of writing | Hover pass-through and fade (A4). Minimise to the bubble. No pass-through without hover (R7). |
| Context refresh costs on a big notebook | Per-page signatures: only changed pages are read; a 0-change refresh is about 1 ms. |

## 5. Questions for the user

1. **The new ink renderer (S3).** The user asked what it involves and why Apple Notes doesn't need
   it (answered in chat, 2026-11-03).
   - **Decision:** S1 and S2 come first. They remove the lag that is Trove's own fault.
   - Then the user tries it on the iPad and decides whether the remaining PencilKit re-sharpening
     is worth S3.
2. ~~Default handwriting style~~ **Answered:** natural, neat handwriting that looks real, sized like
   the writing around it (A1).
   - The glyphs' licence is still checked first. If it isn't OFL or public domain, the choice of
     source comes back to the user. (R14)
3. ~~Page pictures~~ **Answered:** yes, but ask first. The first ask in each session offers Allow /
   for this session / always / not now. "Ask each session" is the default and can be changed in
   Settings (A5.5).

Decided here without asking:
- the light-blue colour for Math Assist;
- the toolbar's grouping (customisable anyway);
- per-device storage of the custom 100 % and of the Ask box's position;
- AI edits never delete your ink without a separate tap;
- AI output is grouped and one undo step;
- iPhone gets a sheet, not a floating box.

## 6. Traceability

| # | Request | Plan items | Verified by |
|---|---|---|---|
| 1 | Sleek top, nothing hidden | T1, T2, T3, T4 | V2 screenshots plus overlap assert; V4 |
| 2 | Custom 100 % plus reset | T5 | `ZoomBase` tests; V2 (zoom menu); V4 |
| 3 | No lag, no resolution change | S1–S5 | S1 meter; V3; V4 screen recording |
| 4 | AI writing in light blue handwriting, erasable | A1, A2 | A1 tests; V4. "Auto complete" is read as Math Assist plus anything the AI writes; any future handwriting autocomplete uses A1 too. (R14) |
| 5 | Floating, movable, resizable Ask box | A4 | V2 (Ask floating); V4 |
| 6 | AI sees handwriting | A5 | `HandwritingFreshness` tests; "What the AI sees"; V4 |
| 7 | Live "AI is looking" outline | A6 | V2 shot mid-read; V4 |
| 8 | Choose where AI output goes and its size | A3 | `DiagramSpec.layout(in:)` tests; V4 |
| 9 | Handwriting style with your pens and colours by default; human-like later | A1, A3, A8 | A1 tests; V4 |
| 10 | Natural handwriting sized like the writing around it (fill in the gaps) | A1 (size rule) | `sizeNear` tests; V4 |
| 11 | Ask before sending page pictures; per session, forever or never; editable in Settings | A5.5 | `PictureConsent` tests; V4 |
| 12 | A new sketch asks for page settings first | T6 | V2 screenshot plus UI test |
