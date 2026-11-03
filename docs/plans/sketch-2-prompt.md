# Prompt: plan the next sketch round (Sketch 2)

This is the brief for writing `docs/plans/sketch-2-plan.md`. The plan comes first. Nothing gets built
until the plan has been reviewed (`docs/plans/sketch-2-review.md`) and the user has seen it.

---

You are planning the next round of work on **Trove's sketch editor**. Sketches are notebooks,
whiteboards and endless canvases, plus PDFs and pictures you write on. For now the user treats
sketches as the main part of the app. Read `CLAUDE.md`, `NOTES.md` and `docs/MASTER_PLAN.md` (G1–G14)
first. Then read the sketch code (`App/Sources/Drawing/`), the notebook chat
(`Packages/TroveCore/Sources/TroveCore/Enrich/StudyChat.swift`, `App/Sources/Drawing/StudyPanel.swift`),
and Math Assist (`Packages/TroveCore/Sources/TroveCore/Math/`, `App/Sources/Drawing/MathAssistController.swift`).

## What the user asked for (their words, then what it means)

1. **Sleek, uncluttered top bar.** "everything is so cluttered in the top and also some stuff is like
   hidden sometimes like the zoom pill … everything has to be sleek while still being able to access
   everything fairly quickly and intuitively."
   - Redesign the editor's controls.
   - No control may ever be hidden with no way to reach it: not scrolled off, not covered by
     another bar, panel or keyboard, not cut off by a rounded screen corner.
   - Everything stays at most two taps away.
2. **Your own 100 %.** "make a thing so u can set a new 100% zoom value and a reset to original one."
3. **No lag, ever.** "in sketch its so laggy to pan around and also when u zoom in and out the
   resolution is different and changed so it takes a bit to update – the user should NEVER see lag
   like this in any place in the app at all it simply must not exist."
   - Panning and pinching stay at the display's full frame rate, on both the iPad and the Mac.
   - Ink, paper, PDFs, pictures and text never visibly go soft and then sharpen.
   - Turn this into numbers the build can check.
4. **AI writing looks and acts like handwriting.** "make the writing it auto does with the auto
   complete / solve maths thing like a nice light blue and make it so it looks like handwriting and
   also so it behaves like normal handwriting as in you can rub it out normally."
   - Math Assist answers, and anything else the AI writes on the page, become real ink strokes in a
     handwriting style.
   - Math Assist answers are light blue.
   - The eraser and lasso treat them like any other ink.
5. **The Ask box floats.** "the ask thing should be like a box which u can move around anywhere
   easily and expand and make smaller and different shapes to your will."
6. **The AI must read handwriting.** "the ai doesn't seem to be able to see handwriting but it can
   see pdfs."
   - Find out why. Fix it at the root.
7. **A live outline of where the AI is looking.** "make it so there's like a non intrusive live
   outline ig that shows where the ai is looking."
8. **You choose where AI output goes.** "when u ask it to like edit or make a diagram whatever it
   should prompt u to like select an area where to make it and size etc."
9. **Handwriting by default.** "it should by default use handwriting style writing and the pens and
   colours available it should look almost handwritten."
   - Long term: "be able to write out stuff and look almost human like while still obv being cheap API."

## Constraints the plan must respect

- **No new device lab.** The user has a free Apple ID, an iPad (the only device with Apple
  Intelligence) and no Apple Silicon Mac. The apps are built on GitHub Actions. Swift on Linux runs
  only `TroveCore`. So:
  - Put everything that can be pure logic in TroveCore, with Linux tests.
  - Say how each claim gets checked: Linux test, CI build, CI simulator test, or the user on the iPad.
- **Keep costs low.** AI calls use the user's own key (Haiku 5.5 at $0.10 / $0.50 per million input
  and output tokens). Handwriting, layout, diagrams and writing on the page are done on the device.
  The AI sends words and structure, never stroke coordinates. Give a cost for every new AI call.
- **Battery comes first** (MASTER_PLAN). Nothing may run continuously. Animations must stop.
  Respect Low Power Mode and Reduce Motion.
- **Keep the format compatible.** Sync, the website (`web/`), GoodNotes export and PDF export must
  keep working. Any new record field goes in `docs/PROTOCOL.md`, with tests in both Swift and JS.
- **Swift 6 strict concurrency.** iOS 18 and macOS 15 are the minimums. Anything newer goes behind
  `#available`.
- **CLAUDE.md rules.** Ask the user before decisions that are theirs: design direction, anything
  that costs money, licences.

## What the plan must contain

1. **Findings.** What causes each problem today, with `file:line` references. Diagnose; don't guess.
   Say where a guess still has to be confirmed on a device.
2. **Workstreams.** For each: the design, the files touched, what's new in TroveCore and its tests,
   and acceptance criteria someone can check.
3. **Performance budget and measurement.**
   - Frame budget at 60 and 120 Hz, and how much main-thread work a pan or pinch frame may use.
   - A test notebook big enough to hurt.
   - How hitches are measured in CI and on the iPad.
   - A decision, with reasons, on whether committed ink keeps rendering through PencilKit's tiles
     or moves to Trove's own renderer.
4. **Interaction design** for:
   - the new toolbar, as an ASCII mock-up at iPad full width, iPad half width, iPhone and Mac;
   - the floating Ask box;
   - placing AI output;
   - the custom 100 %;
   - the "AI is looking here" outline.
5. **Handwriting synthesis.**
   - Glyph source and its licence.
   - Layout: wrapping, matching ruled lines, fitting a box.
   - The humaniser: seeded variation, pressure and timing.
   - Colours and pens.
   - How it stays cheap.
   - The path to "your own handwriting".
6. **Order of work**, in small commits that each build and keep tests green, starting with the
   biggest user-visible win.
7. **Risks**, each with a fallback.
8. **Questions for the user**, only the ones that are truly theirs. Everything else gets a decision.
9. **A traceability table:** every numbered request above, the plan items that answer it, and how
   it's verified.

The plan should be thorough but not padded: specific files, specific numbers, specific tests.
