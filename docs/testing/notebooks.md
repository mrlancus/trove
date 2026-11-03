# Notebooks and handwriting (NB, HW)

The sketch editor (`InkEditorModel`, `PencilCanvas` on iPad/iPhone, `MouseInkCanvas` on the Mac),
pages, tools, lasso, shapes, Math Assist, audio synced to ink, GoodNotes import and export. PROTOCOL.md §10.

### TEST-HW-001: Handwriting survives navigating away
- **Feature**: ink persistence
- **Priority**: critical
- **Coverage**: auto-tested (storage and reload); with the Pencil: not tested
- **Platforms**: iPad
- **Preconditions**: a notebook with at least one page.
- **Steps**:
  1. Open the notebook.
  2. Add a page.
  3. Write five lines with Apple Pencil.
  4. Open a different notebook.
  5. Close the app from the app switcher.
  6. Reopen the app and the first notebook.
  7. Go to the new page.
- **Expected**: every stroke is in the same place, with the same thickness and colour. Nothing is
  missing or duplicated. The page shows in under ~0.5 s.
- **Failure looks like**: missing or moved strokes, a changed stroke look, duplicates, or a blank
  page that fills in late.
- **Automated by**: manual (needs Apple Pencil); storage: `InkTests/sketchesAndStrokes`, `InkSafetyTests/reloadingAPageOfInkStaysCheap`.

### TEST-HW-002: Strokes written on the iPad reach the Mac
- **Feature**: ink sync and push batching
- **Priority**: critical
- **Coverage**: auto-tested (batching: `PowerPolicyTests/aThreeHourWritingSession`); devices: not tested
- **Platforms**: iPad → Mac
- **Preconditions**: the same notebook open on both.
- **Steps**:
  1. Write a line on the iPad and stop.
  2. Wait up to 3 minutes, or close the notebook on the iPad.
- **Expected**: the line appears on the Mac within ~3 minutes, at once after closing.
- **Failure looks like**: never arrives, arrives twice, the Mac's open notebook not updating.
- **Automated by**: manual; `PowerPolicyTests/waitsForAPauseButNotForever`.

### TEST-NB-001: Each pen, the erasers and undo
- **Feature**: tools
- **Priority**: critical
- **Coverage**: auto-tested (geometry, website e2e); iPad tools: not tested
- **Platforms**: iPad, Mac
- **Preconditions**: an empty page.
- **Steps**:
  1. Draw one line with each pen (fountain, ballpoint, brush, highlighter, …) in two thicknesses.
  2. Erase half of one line with the partial eraser and a whole line with the stroke eraser.
  3. Scribble over a word (scribble to erase).
  4. Undo four times, redo four times.
- **Expected**: each pen looks different and like its preview; erasing removes exactly what was
  touched; undo/redo restore each step.
- **Failure looks like**: the wrong width, an eraser removing more than touched, undo skipping steps.
- **Automated by**: `InkGeometryTests/pagesElementsLassoAndPartialErase`, `scribblesMatchTheWebsite`; website `ink.e2e.mjs`; iPad: manual.

### TEST-NB-002: Lasso copy, paste and move
- **Feature**: lasso
- **Priority**: high
- **Coverage**: auto-tested (core, website); iPad: not tested
- **Platforms**: iPad, Mac
- **Preconditions**: a page with writing.
- **Steps**:
  1. Lasso a word, drag it 3 cm right.
  2. Copy, paste, move the copy below.
  3. Close and reopen the notebook.
- **Expected**: the moved word and the copy are where you left them.
- **Failure looks like**: the word snapping back, the copy lost on reopening.
- **Automated by**: `InkEditingTests/lassoEditsInTheLibrary`; website `ink.e2e.mjs`.

### TEST-NB-003: Shapes snap to clean shapes
- **Feature**: shapes
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: iPad, Mac, web
- **Preconditions**: Shapes on.
- **Steps**:
  1. Draw a rough square, triangle and circle quickly and hold the pen at the end.
- **Expected**: a square, a triangle and a circle.
- **Failure looks like**: a circle for the square, a polygon for the circle.
- **Automated by**: `InkGeometryTests/shapesMatchTheWebsite`.

### TEST-NB-004: Opening a 500-page notebook doesn't hang
- **Feature**: B2/B4 (PERF_AUDIT)
- **Priority**: critical
- **Coverage**: auto-tested (page index: `RecordIndexTests/InkPageIndexTests`); app: implemented
- **Platforms**: iPad, iPhone, Mac
- **Preconditions**: a big notebook (yours, or the debug `-TroveTestVault full` "Generated notebook").
- **Steps**:
  1. Settings → Battery → Watch for lag on.
  2. Open the notebook; flick to page 250.
  3. Export diagnostics.
- **Expected**: the first page shows in under 0.5 s; no hang over 100 ms in "Notebook"; "Open
  Notebook" p90 under 200 ms.
- **Failure looks like**: a spinner or blank page for seconds, hangs in the export.
- **Automated by**: `InkPageIndexTests/matchesAScanThroughRandomEdits`; device: manual.

### TEST-NB-005: Zoom, pan and the endless canvas stay smooth
- **Feature**: canvas
- **Priority**: critical
- **Coverage**: not tested (budget: 0 hitches on your devices)
- **Platforms**: iPad, Mac
- **Preconditions**: the generated whiteboard (10k strokes) or a dense page of yours.
- **Steps**:
  1. Measure frames for 10 minutes.
  2. Pinch from 10 % to 1000 % and back; pan around for a minute.
  3. Stop and export.
- **Expected**: hitches near 0 in "Notebook"; the ink sharpens a moment after you stop.
- **Failure looks like**: stutter, blank tiles, blurry ink that never sharpens.
- **Automated by**: manual; website `ink.e2e.mjs` "panning 2,000 strokes through tiles".

### TEST-NB-006: A GoodNotes notebook imports with its handwriting
- **Feature**: GoodNotes import
- **Priority**: critical
- **Coverage**: auto-tested (`ink.goodnotes` fixture)
- **Platforms**: iPad, Mac, web
- **Preconditions**: a `.goodnotes` file of yours.
- **Steps**:
  1. Import it.
  2. Open it; open the pen and add a line.
- **Expected**: every page and its handwriting look like GoodNotes; Trove's line is added; GoodNotes'
  ink is editable as Trove's.
- **Failure looks like**: blank pages, missing writing, the cover only.
- **Automated by**: `GoodNotesInkTests/decodesTheSameAsTheWebsite`; website `ink.e2e.mjs` "a GoodNotes notebook opens…".

### TEST-NB-007: Export to GoodNotes and open it in GoodNotes
- **Feature**: G13
- **Priority**: high
- **Coverage**: auto-tested (round trip in TroveCore); in GoodNotes: not tested
- **Platforms**: iPad
- **Preconditions**: a notebook with Trove ink; GoodNotes installed.
- **Steps**:
  1. Editor → Export → GoodNotes notebook → open in GoodNotes.
- **Expected**: GoodNotes opens it; pages and ink as in Trove.
- **Failure looks like**: GoodNotes refuses the file, ink missing.
- **Automated by**: `GoodNotesWriterTests/roundTripReplacesGoodNotesInkWithTrovesAndKeepsTheRest`; GoodNotes: manual (yours).

### TEST-NB-008: Math Assist answers a handwritten line
- **Feature**: G7
- **Priority**: high
- **Coverage**: auto-tested (solver, candidates, cache)
- **Platforms**: iPad
- **Preconditions**: Settings menu in the sketch → Math Assist on.
- **Steps**:
  1. Write `12 × 3 =` and lift the Pencil.
- **Expected**: `36` appears as a text box after ~0.4 s.
- **Failure looks like**: nothing, a wrong answer, "?" for clear writing.
- **Automated by**: `MathAssistTests/testMessyHandwritingPicksTheMathsReading`, `testAnHourOfMathsReadsEachLineOnce`; Pencil: manual.

### TEST-NB-009: Audio synced to ink
- **Feature**: G4
- **Priority**: high
- **Coverage**: auto-tested (linking strokes to time)
- **Platforms**: iPad
- **Preconditions**: microphone allowed when asked.
- **Steps**:
  1. Record; speak while writing three words; stop.
  2. Recordings → play.
- **Expected**: each word is marked as the audio reaches the moment it was written.
- **Failure looks like**: no microphone prompt, no marks, marks out of step.
- **Automated by**: `InkRecordingTests/recordingsLinkStrokesToTheAudio`; device: manual.

### TEST-NB-010: Palm rejection and rotation mid-stroke
- **Feature**: PencilKit input
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPad
- **Preconditions**: "Only draw with Apple Pencil" on.
- **Steps**:
  1. Rest your palm on the screen and write a line.
  2. Rotate the iPad while writing another.
- **Expected**: no marks from the palm; the line completes; the page re-fits without losing ink.
- **Failure looks like**: palm marks, a broken or lost stroke.
- **Automated by**: manual (needs the Pencil).

### TEST-HW-003: Search finds handwriting and jumps to the line
- **Feature**: handwriting search (G6)
- **Priority**: high
- **Coverage**: implemented
- **Platforms**: iPad, Mac, iPhone
- **Preconditions**: a page with the word `pineapple` written clearly; a minute for reading.
- **Steps**:
  1. Search `pineapple`; open the hit.
- **Expected**: the notebook opens at that page, the line highlighted.
- **Failure looks like**: no hit, the wrong page.
- **Automated by**: manual.
