# Sketch 2: review of the plan

**What was reviewed:** `docs/plans/sketch-2-plan.md`, first draft. It was checked against the brief
(`sketch-2-prompt.md`) and the code it relies on.

**Method:**
- Every claim about the code was checked against the file it cites.
- Every request was traced to plan items.
- Every technique was checked for whether it would actually work on iPadOS and macOS.
- Each cost figure was recomputed.

Every issue below has been fixed in the plan. The **Fix** line says how.

## Verdict

**Sound after fixes.**
- The diagnosis is right and specific. Each lag source and the handwriting bug are confirmed in code.
- The order of work is right: measure, then the cheap root-cause fixes, then the big renderer behind
  a setting.
- Three technical mistakes would have broken things (R1–R3). Several claims were stronger than the
  techniques can deliver (R4, R5). A few edge cases were missing (R6–R14).

## Must-fix (the draft would not have worked)

**R1. "Layers in content space get scaled for free" is wrong for `PKCanvasView`.**
- A `UIScrollView` zooms only its `viewForZooming`. For `PKCanvasView` that view is PencilKit's
  private content view.
- Our own subviews (`paperView` and the rest) sit in content coordinates, but they **aren't
  scaled**. Adding layers into PencilKit's private view isn't safe.
- **Fix:**
  - Our layers live in one container layer whose `transform` we set to the zoom scale in
    `scrollViewDidZoom`, with implicit animations off.
  - That is one property write per frame and no repaint.
  - Plan S2.1 was rewritten; the step order changed so the container comes before the paper layers.

**R2. "One `MTKView` per visible page" would blow memory at high zoom.**
- At 400 % an A4 page is about 9 500×13 500 px. One drawable that size is about 500 MB.
- **Fix:**
  - **One** `MTKView`, screen-sized, pinned to the visible bounds, behind PencilKit's content.
  - It draws the visible pages with the zoom and offset as uniforms.
  - It is paused (`enableSetNeedsDisplay`) and drawn only when the view moves or the ink changes.
    That keeps the battery rule.
  - `presentsWithTransaction = true` keeps it in step with UIKit's scrolling in the same frame.
  - Plan S3 was rewritten.

**R3. Highlighter in "a separate multiply pass" breaks stacking order.**
- Strokes draw in `createdAt` order (PROTOCOL.md). A pen stroke written over a highlight must stay
  on top.
- **Fix:** one pass in `createdAt` order. Consecutive strokes with the same blend mode are batched
  into one draw call, and the pipeline state switches between batches.

## Over-claims, made honest

**R4. "PDFs never go soft from 25 % to 400 %" can't be promised.**
- PDFs and pictures are images by the time they're on screen.
- Prefetching the next level up and down covers a normal pinch. A very fast pinch from 100 % to
  400 % can outrun the renderer. Apple's own PDFKit behaves the same way.
- **Fix:** the bar now separates two kinds of content.
  - **Vector content** (ink with S3, paper, shapes, text up to 4×): truly never soft.
  - **Images and PDFs:**
    - rendered ahead, and rendered *during* the pinch as soon as a level is crossed;
    - never blank, never below half the screen's resolution;
    - sharp within one frame of the pinch ending in the normal range.
  - Pictures can't be sharper than their own pixels anyway.

**R5. "Text boxes at 2× headroom" was sharp only to 2×.**
- **Fix:** while idle, the visible boxes also prerender the next level (4×). There are few, and
  they're small. With S3 on, the text stays in layers; vector text in Metal isn't worth the
  complexity now. This is noted as a possible later step.

## Missing or wrong details

**R6. Math Assist answers in ink need rules the draft didn't have.**
- **Where the answer goes.** The draft put it right of the `=`. If you write your own answer there
  (`2+2=5`), the ✗ and the correct value would land on top of it.
  - **Fix:** place the answer right of the line's **rightmost ink**, and check for free space first.
- **Undo.** Undoing your `=` should take the answer away too.
  - **Fix:** answer strokes are linked to the `=` strokes. If either `=` stroke is deleted or
    undone, the untouched answer strokes go too.
- **Detection.** Math Assist's own strokes must never feed `EqualsDetector`. The `=` it writes in
  `x = 3/4` would trigger itself.
  - **Fix:** strokes with `by` set are excluded from detection. They are kept in `MathLine.gather`,
    so a chained `= … =` still reads.
- **Memory of erased answers.** It was "kept in the note's local state", which doesn't exist.
  - **Fix:** a small per-item file in Caches (`math-dismissed.json`). It is local on purpose:
    Math Assist only runs for strokes written on this device.

**R7. Pencil pass-through on the floating Ask box isn't possible the way it was written.**
- SwiftUI can't let Pencil touches fall through a view to the UIKit canvas underneath, and
  `hitTest` doesn't know a touch's type yet.
- **Fix:** use **Pencil hover**. When the Pencil hovers over the box and the box isn't focused, the
  box fades to 30 % and `allowsHitTesting(false)` until the hover leaves.
- Pencils and iPads without hover (before the M2 iPad Pro) don't get pass-through. You move or
  minimise the box. The plan says so.

**R8. The second toolbar row was swapped for a floating tray. It should go inline.**
- A floating tray over the top of the canvas still covers writing, and "fades while writing" needs
  the same pass-through trick as R7.
- GoodNotes' answer is sleeker: the selected tool's **few colours and sizes sit in the bar
  itself**, between the tools and the actions. The full options open under the tool on a second
  tap.
- **Fix:**
  - T1 and T2 were rewritten that way: no overlay row at all.
  - Favourites moved into the pen's tray, plus a ★ menu.
  - On narrow widths the inline options fold into the tray.

**R9. The custom 100 % was over-built.**
- Separate values per page kind, keyed by page width, is more than "set a new 100 % and reset to
  original" asks for, and harder to predict.
- **Fix:**
  - One value per device.
  - The pill shows zoom relative to it.
  - Reset puts it back to 1 pt = 1 pt.
  - A per-notebook override is listed as a possible later step, not built.

**R10. The corner inset rule was wrong.** iPads with rounded corners do have a bottom safe-area inset
(the home indicator).
- **Fix:** HUD controls never use `ignoresSafeArea`. They stay inside the safe area, plus 8 pt.

**R11. Things that don't exist yet were treated as if they did.**
- There's no Settings → Diagnostics section and no UI test target in `project.yml`.
- **Fix:** both are added explicitly in S1:
  - a `Diagnostics` section;
  - a `TroveUITests` target. It runs only on the simulator, so it needs no signing.

**R12. PDF rendering off the main thread.** `PDFKit`'s `PDFDocument` isn't safe to share across
threads.
- **Fix:** tiles render through the existing `InkRenderer` CGPDF path, which `InkBackdrop` already
  uses off the main thread. Each worker opens its own `CGPDFDocument`.

**R13. The image-token estimate was rough.** Claude counts images at about width × height / 750
tokens.
- At 1092 px on the long side:
  - an A4 page is about 772×1092, or **≈ 1 100 tokens ≈ $0.00011**;
  - a 4:3 picture is about 1 600 tokens.
- **Fix:** the cost table shows a range of $0.0001–0.0002 per page.
- The first question also pays the cache write (1.25×), so it's ≈ $0.0012, not $0.0010. Both fixed.

**R14. Smaller gaps:**
- **Thin paper lines when zoomed out.**
  - A scaled 0.5 pt line goes below a pixel at 25 %.
  - **Fix:** after each zoom ends, line layers get a thickness of max(nominal, 1 px ÷ zoom). That's
    a property change, not a repaint.
- **"Auto complete".** The user said "the auto complete / solve maths thing". Trove has no
  handwriting autocomplete today.
  - It's read as Math Assist, plus anything the AI writes. Both go through A1, so any future
    autocomplete gets it free.
  - Noted in traceability as an interpretation.
- **Present mode** hides the HUD except the end button. Stated in T4.
- **Hardware keyboard.** Every toolbar tool gets a shortcut (P, H, E, L, S, T; ⌘K for Ask). Added
  to T1.
- **CI turnaround.** Nothing in `App/` compiles locally, so each step batches its app changes into
  one CI run, and pure logic lands in TroveCore first with Linux tests. Added to §3.
- **Licence decision.** If the glyph font's licence isn't OFL or public domain, that's the user's
  call (CLAUDE.md). Added to Q2.

## Coverage check (after fixes)

| # | Request | Covered | Notes |
|---|---|---|---|
| 1 | Sleek top bar, nothing hidden | ✅ T1–T4 | Inline options (R8), no scrolling, priority folding, HUD solver |
| 2 | Custom 100 % plus reset | ✅ T5 | Simplified (R9) |
| 3 | Never lag, never soft | ✅ S1–S5 | Honest split between vector and image content (R4) |
| 4 | Light-blue handwriting, erasable | ✅ A1, A2 | Placement, undo and detection rules (R6) |
| 5 | Floating, resizable Ask box | ✅ A4 | Pass-through via hover only (R7) |
| 6 | AI sees handwriting | ✅ A5 | Five root causes, each fixed |
| 7 | Live "looking" outline | ✅ A6 | |
| 8 | Choose the area and size for AI output | ✅ A3 | |
| 9 | Handwritten with your pens and colours by default; human-like later | ✅ A1, A3, A8 | |

**Brief's required sections:**
- Findings with references ✅
- Workstreams with acceptance criteria ✅
- Performance budget, fixture, CI and device measurement, renderer decision ✅
- Mock-ups at four sizes ✅
- Handwriting synthesis: source, licence, layout, humaniser, cheapness, own-handwriting path ✅
- Order ✅
- Risks ✅
- Questions ✅
- Traceability ✅

## Still uncertain (confirmed only on the iPad)

- Which of the four causes hid the zoom pill for the user. The fix covers all four. V2's
  screenshots show the before and after.
- Whether the Metal ink can match PencilKit's pencil texture closely enough. It's gated behind a
  setting, with a per-ink fallback.
- How many CI iterations the renderer takes. It's the last big step, so the rest lands first.
