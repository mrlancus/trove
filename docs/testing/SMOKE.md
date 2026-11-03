# Device smoke run (after every reinstall, under 30 minutes)

You need: the iPad with the Pencil, the iPhone, the Mac, all on your vault and online. Run in order;
log one row per test in `RESULTS.md` (date, test ID, build, device and OS, you, pass/fail/blocked).
Each line points to the full test.

| # | Test | Device | What to do (short) | Pass when |
|---|---|---|---|---|
| 1 | TEST-SYNC-001 | all | a note titled with each device's name | all three everywhere within a minute |
| 2 | TEST-NOTE-001 | iPhone | new note `Smoke note` / `quantum walrus 42`, search `walrus` | top hit, word marked |
| 3 | TEST-NOTE-002 | Mac | heading, list, bold, checkbox; undo/redo ×3 | styles as you type, undo exact |
| 4 | TEST-NOTE-003 | Mac | `[[Beta]]` in Alpha | backlink on Beta |
| 5 | TEST-NOTE-005 | iPhone | delete `Smoke note`, restore | back with its body |
| 6 | TEST-CAP-001 | Mac | copy in TextEdit and Safari, ⌥Space | both on top with sources |
| 7 | TEST-CAP-002 | Mac | ⌥Space, `smoke`, ⏎ in TextEdit | pasted, palette closed |
| 8 | TEST-CAP-004 | Mac → iPhone | copy, quit and reopen, check iPhone | clip on both |
| 9 | TEST-CAP-005 | Mac | copy a password | masked, gone after 2 min |
| 10 | TEST-CAP-008 | iPhone | share a link and a PDF to Trove | both in the library |
| 11 | TEST-HW-001 | iPad | add a page, write 5 lines, switch, quit, reopen | every stroke as written, page < 0.5 s |
| 12 | TEST-HW-002 | iPad → Mac | write, close the notebook | on the Mac at once |
| 13 | TEST-NB-001 | iPad | each pen, erasers, scribble, undo/redo | as drawn, exact undo |
| 14 | TEST-NB-002 | iPad | lasso, move, copy, reopen | kept where left |
| 15 | TEST-NB-004 | iPad | open your biggest notebook, flick to the middle | first page < 0.5 s, no hang logged |
| 16 | TEST-NB-005 | iPad | measure frames; zoom 10–1000 %, pan | hitches near 0 |
| 17 | TEST-NB-006 | iPad | import a `.goodnotes`, add a line | looks like GoodNotes, line added |
| 18 | TEST-NB-008 | iPad | write `12 × 3 =` with Math Assist on | `36` appears |
| 19 | TEST-PDF-001 | iPad | Open a PDF, tap; Edit → Pen → line → Done; reopen | view-only taps do nothing, line kept |
| 20 | TEST-PDF-002 | Mac | find, highlight, quote | highlight on the text, quote item made |
| 21 | TEST-AI-001 | Mac | Ask the smoke question | 42 with a citation and a cost row |
| 22 | TEST-AI-003 | iPhone | note, search, notebook, study, clipboard | no new Activity rows |
| 23 | TEST-CARD-001 | iPhone | study 3 cards: Good, Again, Easy | times on the buttons, Again back in ~10 min |
| 24 | TEST-SYNC-004 | iPhone | Airplane Mode, 5 notes + a page, reopen, online | all kept and synced |
| 25 | TEST-PERF-005 | iPad | Settings → Battery → Export diagnostics | no hangs over 100 ms; send me the file |
