# Develop (DEV)

## planned: the practice loop in the apps
Not built yet (DEVELOP_PLAN §D phase 2). When built, the tests must cover: start a session; solve with
no hints, with hints, and incorrectly; revisit a failed problem; the same skill through a different
problem; delayed scheduling; history kept; uncertain marks go to review; practise with AI switched
off from start to finish (questions, show the mark scheme, self-mark, evidence recorded, no AI call in
the activity log); the source line hidden until asked for, then right; AI marking includes the
matched mark scheme and says so when there isn't one.


## Built: Develop's first slice in TroveCore (2026-11-03)
No app screens yet; these run on Linux and in CI. Values are DEVELOP_PLAN Appendix B's worked examples.
TEST-DEV-004, 005, 006, 009 and 011 are filed in their areas as TEST-GRAPH-010, 011, 012, TEST-CUR-001 and TEST-CARD-010.

### TEST-DEV-001: The mastery model's worked examples come out exactly
- **Feature**: Mastery.evaluate
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core (Swift), web (JS)
- **Preconditions**: `Fixtures/mastery-cases.json` (6 cases).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`; `cd web && npm test`.
- **Expected**: one unaided standard success: ability 0.4000, mastery 0.5987, stability 3.1262, next practice in 5 days; after the approach hint: ability 0.0000, mastery 0.5000, next in 2 days; 100 easy problems: not assessed (all trivial); three hard problems from two+ sources: ability 1.4042, mastery 0.8029, proficient; a later AI-marked 25 %: ability 0.2225, mastery 0.5554; unmarked or uncertain: no evidence. Swift and JS identical.
- **Failure looks like**: any value off in the 4th decimal; Swift and JS disagreeing.
- **Automated by**: `DevelopTests/theWorkedExamplesComeOutExactly`; `web/test/develop.test.mjs` "the worked examples come out exactly as in Swift".

### TEST-DEV-002: One success is never mastery; failure routes to reassessment and prerequisites
- **Feature**: proficiency rule
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: one hard success: not proficient, and the sentence says how many more are needed; a failure after the full solution: due the next day; two failures a day or more after the last success: prerequisites flagged.
- **Failure looks like**: proficient after one success.
- **Automated by**: `DevelopTests/oneSuccessIsNeverMasteryAndWhySaysWhy`.

### TEST-DEV-003: Develop ids are stable across devices
- **Feature**: ids
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core, web
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`; `npm test`.
- **Expected**: the same name gives the same concept id; symmetric edges have one id either way; ids match between Swift and JS.
- **Failure looks like**: two ids for one concept.
- **Automated by**: `DevelopTests/idsAreStableAndSlugsFold`; web "ids and slugs match TroveCore".

### TEST-DEV-007: Practice picks: seeded, fresh, filtered, weighted to what's needed
- **Feature**: Practice.pick
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: 40 generated problems over two skills.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: the same seed gives the same questions; a different seed different ones; a problem done in the last 3 days isn't offered; marks and skill filters respected; the never-practised skill comes up in over half of 200 single picks.
- **Failure looks like**: repeats, ignored filters, the same picks for every seed.
- **Automated by**: `DevelopTests/practicePicksAreSeededFreshAndFiltered`.

### TEST-DEV-008: Hard means hard to solve, and AI routing never picks a dearer model
- **Feature**: Difficulty, DevelopAI.route
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: GCSE is never hard (even 12 marks); A-level only with a national average under 35 % or Trove's own estimate ≥ 1.0 from 5+ attempts; competition hard; routing: Haiku 5.5 low, medium only for hard or a re-check of an uncertain mark.
- **Failure looks like**: marks or length making a question hard; any route not Haiku.
- **Automated by**: `DevelopTests/hardMeansHardToSolveNotLongOrManyMarks`.

### TEST-DEV-010: A paper splits into questions with marks and diagrams, and matches its mark scheme
- **Feature**: PaperSplitter
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: a paper written for the test in AQA's layout (no board text).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: keys 1, 1.1, 1.2, 2.1 with marks –, 1, 3, 2 and parents; 1.2's region runs to the page's end so its figure comes with it; scheme entries 1.1, 1.2, 2.1 found by key.
- **Failure looks like**: merged or missing questions, marks on the wrong part.
- **Automated by**: `DevelopTests/aPaperSplitsIntoQuestionsWithMarksAndMatchesItsScheme`.

### TEST-DEV-012: The thin slice end to end with no AI
- **Feature**: photo → concepts → problem → attempt → mastery → card → Anki
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: the photo's text suggests Momentum and Conservation of momentum; the catalogue question is picked; a self-marked 2/3 gives mastery σ(0.8 × (2/3 − 0.5)); the gap and the card link back both ways; the TSV holds the card's GUID; nothing shows as a library item.
- **Failure looks like**: any link one-way; Develop records showing as notes.
- **Automated by**: `DevelopTests/photoToConceptsToPracticeToMasteryToAnki`.

## Built: Develop in the apps (phase 2, first version)
Not yet on a device. Pencil answers, hints and timed mocks aren't built yet.

### TEST-DEV-020: Download a course's papers and split them into questions
- **Feature**: Develop → Your courses → a course
- **Priority**: critical
- **Coverage**: implemented
- **Platforms**: iPad, iPhone, Mac
- **Preconditions**: On Wi-Fi. A course added (TEST-CUR-005).
- **Steps**:
  1. Open the course. Tap one paper: it downloads with its mark scheme and report, then splits.
  2. Tap Download every paper; watch the progress; tap Cancel halfway, then tap it again.
  3. For a GCSE course, switch the tier picker between Higher and Foundation.
- **Expected**: the paper's row turns to "Ready to practise" with a green tick; a message says how many questions are ready (dozens per paper); essay, listening or scanned papers are reported as "no questions Trove could find" rather than failing; Cancel stops after the current file; on mobile data nothing downloads and it says Wi-Fi only; the course's bar on Develop's home fills up.
- **Failure looks like**: a spinner for ever, 0 questions from a science or maths paper, the app freezing while splitting (Settings → Battery → Lag would show a hang in Develop).
- **Automated by**: manual; TroveCore `RealPaperSplitTests` (TEST-CUR-004), `DevelopTests/aPaperSplitsIntoQuestionsWithMarksAndMatchesItsScheme`.

### TEST-DEV-021: Practise with no AI: answer, show the mark scheme, tick, see the evidence
- **Feature**: practice loop
- **Priority**: critical
- **Coverage**: implemented
- **Platforms**: iPad, iPhone, Mac
- **Preconditions**: TEST-DEV-020 done; your AI may be on or off.
- **Steps**:
  1. Tap Practise anything.
  2. Read the question (the original page with its diagrams); type an answer.
  3. Tap Show mark scheme; tick the points you earned; Done.
  4. Open Settings → AI → Activity and costs.
- **Expected**: the page picture is sharp and complete; the scheme's points are tickable; the result line says "counted as self-marked against the mark scheme"; Skills shows that skill's mastery and a sentence saying why; **no new row** in Activity and costs.
- **Failure looks like**: a blank question, a scheme from another question, an AI row appearing.
- **Automated by**: manual; mastery maths: TEST-DEV-001.

### TEST-DEV-022: The source line is hidden until asked for
- **Feature**: source line
- **Priority**: high
- **Coverage**: implemented
- **Platforms**: all apps
- **Preconditions**: a question open.
- **Steps**:
  1. Look for the paper and year on screen.
  2. Tap ⓘ.
- **Expected**: nothing names the paper until ⓘ; then e.g. "AQA 7408/2 June 2023 Q4.2".
- **Failure looks like**: the source visible from the start, or the wrong paper.
- **Automated by**: manual; label format: TEST-CUR-001.

### TEST-DEV-023: Mark with AI quotes the mark scheme; unsure marks go to review
- **Feature**: AI marking
- **Priority**: high
- **Coverage**: implemented
- **Platforms**: all apps
- **Preconditions**: your AI set up (Settings → AI).
- **Steps**:
  1. Answer a question; tap Mark with AI.
  2. Open Activity and costs.
- **Expected**: each point marked ✓/✗ with the scheme's words; "AI marked against the mark scheme"; a Develop marking row with its cost (a fraction of a penny on Haiku); an unsure mark appears under To review and doesn't change mastery until you Confirm.
- **Failure looks like**: a mark with no points, an AI row with a big cost, uncertain marks counted.
- **Automated by**: manual; parsing and review rule: `DevelopMarkingTests/aiMarksQuoteTheSchemeOrGoToReview`.

### TEST-DEV-024: Concepts on an item, and No sticks
- **Feature**: concepts on items
- **Priority**: high
- **Coverage**: implemented
- **Platforms**: all apps
- **Preconditions**: a note mentioning "conservation of momentum".
- **Steps**:
  1. Open the note; look under Concepts.
  2. Tap ✓ on one suggestion and ✕ on another.
  3. Close and reopen the note; open it on another device.
- **Expected**: suggestions appear without any AI call; the accepted one shows as a chip; the rejected one never comes back, on either device.
- **Failure looks like**: a rejected suggestion returning.
- **Automated by**: manual; rule: TEST-GRAPH-011.

### TEST-DEV-025: Export cards for Anki
- **Feature**: Anki export
- **Priority**: medium
- **Coverage**: implemented
- **Platforms**: all apps
- **Preconditions**: some flashcards (TEST-AI-004).
- **Steps**:
  1. Develop → Export cards for Anki → Share → save the file.
  2. Import it in Anki Desktop (File → Import).
- **Expected**: Anki imports the cards into a deck called Trove; importing again updates them instead of doubling.
- **Failure looks like**: duplicates, broken text.
- **Automated by**: manual; file format: TEST-CARD-010.

### TEST-DEV-026: Answer with the Pencil, then Mark with AI
- **Feature**: Pencil answers
- **Priority**: critical
- **Coverage**: implemented
- **Platforms**: iPad (and iPhone with a finger)
- **Preconditions**: a question open; your AI set up.
- **Steps**:
  1. The answer pad is on by default on the iPad (✎); write your working with the Pencil.
  2. Tap Mark with AI.
- **Expected**: the ink appears as you write with no lag; marking quotes the scheme and reads your handwriting; Activity shows one Develop marking row; the attempt is recorded.
- **Failure looks like**: laggy ink, the pad scrolling instead of drawing, marking that ignores the writing.
- **Automated by**: manual (needs the Pencil); request building: `DevelopMarkingTests`.

### TEST-DEV-027: The hint ladder, and hints cost credit
- **Feature**: hints
- **Priority**: high
- **Coverage**: auto-tested (prompts); app: implemented
- **Platforms**: all apps
- **Preconditions**: your AI set up.
- **Steps**:
  1. Tap Hint five times, reading each.
  2. Tick full marks against the scheme.
- **Expected**: hint 1 is a nudge and none before 5 gives the answer; 5 is a full solution; the skill's sentence shows the success, but after a full solution it counts for nothing (independence 0) and the skill is due again tomorrow.
- **Failure looks like**: a hint giving the answer early; full credit after hints.
- **Automated by**: `DevelopHintTests/eachLevelAsksForOnlyThatMuch`, mastery rule TEST-DEV-002; app: manual.

### TEST-DEV-028: Upload your own paper from anywhere; it's on every device
- **Feature**: Develop → Your own papers → Upload
- **Priority**: high
- **Coverage**: auto-tested (numbering and splitting); app: implemented
- **Platforms**: core; all apps
- **Preconditions**: a worksheet or competition paper as a PDF (in Files, iCloud Drive, Downloads…) and a photo of a printed page.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter UploadSplitTests`.
  2. (You) Develop → Your own papers → Upload → From Files… → pick the PDF.
  3. Upload → From Photos… → pick the photo. On iPhone/iPad also Upload → Scan with the camera.
  4. Open Develop on another device of the same trove after syncing; Practise anything there.
- **Expected**: the PDF becomes questions (1, 1(b) → 1.2, Q2, 2 c → 2.3) with their marks; a photo or scan with no readable text becomes one question per page; each upload is an item in your trove (folder "Practice papers"), so on the other device the questions are there and practisable without uploading again; a stray number in the text ("3 kg of water") doesn't start a question.
- **Failure looks like**: only a dropdown of existing items, an upload only on one device, every line a question.
- **Automated by**: `UploadSplitTests/numberedWorksheetsSplitAndStrayNumbersStayText`; app: manual.

### TEST-DEV-029: Name an upload: suggested from the paper, yours to change
- **Feature**: Develop → Your own papers → Upload → the "Name this paper" sheet; Rename… on an upload
- **Priority**: medium
- **Coverage**: auto-tested (`PaperTitle`); app: implemented, never run
- **Platforms**: core; all apps (Apple Intelligence tidying: iPad only)
- **Preconditions**: a board paper saved as a PDF with an unhelpful file name (e.g. `GPH11_QP_S23.pdf`), a worksheet, a photo of a printed page.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter PaperTitleTests`.
  2. (You) Upload → From Files… → pick the board paper. Wait for "Suggested from the paper" (on the iPad, "Suggested with Apple Intelligence").
  3. Change the name, then tap Use suggestion; change it again and Save.
  4. Upload the worksheet and the photo together; Save without editing.
  5. Long-press (right-click on the Mac) an upload in Your own papers → Rename….
- **Expected**: the paper's name reads like "CCEA GCSE Physics Unit 1 Foundation, June 2023" (board, qualification, subject, paper, tier, series; "(mark scheme)" for a scheme), with the board spelt the board's way (Pearson Edexcel, CCEA, OCR) even after Apple Intelligence; typing while it's still reading keeps your text; the worksheet gets its PDF title or a tidy file name; the item in your trove has the name you saved; Rename changes it on every device; catalogue papers keep the board's names.
- **Failure looks like**: the file name only, a board renamed or invented, your typing overwritten, no way to change the name.
- **Automated by**: `PaperTitleTests`; app: manual.

### TEST-DEV-030: Add a paper from a board's website (CCEA, Pearson's newest)
- **Feature**: Develop → Your own papers → Upload → From a board's website
- **Priority**: medium
- **Coverage**: app: implemented, never run
- **Platforms**: all apps
- **Preconditions**: your own internet connection (CCEA blocks cloud machines, not people); for Pearson's newest series, a Pearson login.
- **Steps**:
  1. (You) Upload → From a board's website → CCEA… Find a subject's past papers; open a question paper.
  2. Tap Add to Trove; check the suggested name; Save. Add a mark scheme too.
  3. Done; check Your own papers. Repeat with Pearson Edexcel (newest papers) after signing in.
- **Expected**: CCEA's site loads and works like a browser (links that open new windows open in place, Back works); Add to Trove is enabled only on a PDF; the paper is named "CCEA …" and saved as one of your papers, split into questions, on every device; "N papers added" shows in the browser; a page that isn't a PDF says so; a Pearson login is remembered on that device.
- **Failure looks like**: CCEA's "Access Denied" page (tell Claude: then it's blocking people too), Add to Trove never enabled on a PDF, a saved file that isn't the paper.
- **Automated by**: manual.
