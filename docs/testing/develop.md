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

### TEST-DEV-031: A board paper downloaded on one device is on the others
- **Feature**: a course → Download every paper / a paper; "Sync downloaded papers to my other devices"
- **Priority**: high
- **Coverage**: auto-tested (`saveBoardPaper` across two devices); app: implemented, never run
- **Platforms**: core; all apps
- **Preconditions**: two devices on the same trove, both with the same course.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter aDownloadedBoardPaperSyncsLikeAnUpload`.
  2. (You) On device A, open the course and download two papers. Wait for sync.
  3. On device B, open Develop, then the course.
  4. Turn the switch off on A, download another paper; check B again.
- **Expected**: on B the two papers show as on this device and ready to practise without downloading (they come
  from your trove, also over mobile data); they appear once each in Practice papers → the board; the third paper
  stays on A only; the button says what it will do and shows Splitting… and a result on the course screen.
- **Failure looks like**: B downloads from the board again, duplicate items, the button doing nothing visible.
- **Automated by**: `DevelopTests/aDownloadedBoardPaperSyncsLikeAnUpload`; app: manual.

### TEST-DEV-032: A goal practises from your own papers; change it by chatting; upload from the goal
- **Feature**: a goal → Edit goal → Your own papers; Change it by chatting with your AI
- **Priority**: high
- **Coverage**: auto-tested (`GoalUploadsTests`: matching, picking, turning off, the chat's uploads and edits); app: implemented, never run
- **Platforms**: core; all apps (the chat needs your AI)
- **Preconditions**: uploads named e.g. "CCEA GCSE Physics Unit 1, June 2023", "AQA A-level Physics Paper 1, June 2023", a worksheet.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter GoalUploadsTests`.
  2. (You) New goal "CCEA GCSE Physics" (no course). Edit it: the CCEA physics upload is on with "Matches this goal".
  3. Turn on the worksheet; turn off the match; Save. Start: questions come only from the worksheet.
  4. In the goal, Upload papers… → From Files…; name it; Save: it's on in the goal.
  5. Change it by chatting: "add my chemistry paper and move it to 12 June"; Use these changes; check the form; Save.
  6. A goal with an AQA course: the AQA upload matches, the CCEA one doesn't.
- **Expected**: matches by board, level and subject (not CCEA GCSE for an AQA A-level goal); your choices are kept and sync; a goal with no course and nothing chosen practises from everything; uploading from the goal adds the paper to it; the chat changes only what you asked and nothing is saved until you Save.
- **Failure looks like**: uploads never offered, a match you turned off coming back, the chat overwriting the rest of the goal.
- **Automated by**: `GoalUploadsTests`; app: manual.


### TEST-DEV-033: Your papers: every upload in one list, searchable, renamable
- **Feature**: Develop → Your own papers → All your papers
- **Priority**: medium
- **Coverage**: app: implemented, never run
- **Platforms**: all apps
- **Preconditions**: a few uploads (one in a goal), and other PDFs in your trove.
- **Steps**:
  1. (You) Open All your papers. Search two words of one name in the other order ("physics ccea").
  2. Sort by Name, then Most questions. Swipe a paper → Rename; check the new name everywhere.
  3. Long-press a paper that isn't split → Split into questions. Tap a paper: it opens.
  4. Turn on Include every PDF in my trove. Delete a test paper; confirm.
  5. Edit an old goal (it froze before) and a new one with many PDFs in your trove; scroll the papers in it.
- **Expected**: every Develop upload and every paper a goal uses is listed with its questions, goals and date;
  search ignores word order; renames and deletes reach every device; Edit goal opens at once and scrolls smoothly.
- **Failure looks like**: a freeze, uploads missing, search needing the exact name.
- **Automated by**: `GoalUploadsTests/manyUploadsMatchQuickly` (the matching behind it); app: manual.

### TEST-DEV-034: Work a question out in a real sketch, then come back to it
- **Feature**: practice sketches (docs/prompts/practice-space-home.md)
- **Priority**: critical
- **Coverage**: auto-tested (folders, titles, the question's frame, `work` on the attempt); in the app: not tested
- **Platforms**: iPad (Pencil), Mac, iPhone
- **Preconditions**: a course with a downloaded, split paper.
- **Steps**:
  1. Develop → Practise. On the first question, tap the ⋯ menu and pick Whiteboard, then "Open a whiteboard".
  2. Check the question is on the board as a picture. Lasso-tap it, lock it, and write your working over and around it.
  3. Tap "Mark it" in the bar at the top, tick the scheme points, Done.
  4. Next question: "Open a whiteboard" is still the choice (remembered). Switch to Page for this one.
  5. Open Sketches → Practice → the course → the topic.
- **Expected**: each question gets its own sketch named "Q… · paper", in Practice/course/topic, with the
  question at the top and your working kept. Reopening the app shows them all; the attempt opens its working.
- **Failure looks like**: no question picture, the sketch lost or in the wrong folder, or the choice not remembered.
- **Automated by**: `PracticeWorkTests` (TroveCore); the flow: manual.

### TEST-DEV-035: The tutor sees the question, the scheme and your handwriting
- **Feature**: tutor in practice sketches
- **Priority**: high
- **Coverage**: auto-tested (the context order, the tutor's prompts); with your AI: not tested
- **Platforms**: iPad, Mac
- **Preconditions**: your AI set up; a practice sketch with some handwritten working, one line deliberately wrong.
- **Steps**:
  1. In the practice sketch, tap Tutor.
  2. Tap "Check my working", then "Where did I go wrong?", then "A hint".
  3. Back on the question, tap "A hint" there too.
- **Expected**: answers refer to what you actually wrote (quoting the wrong line), use the mark scheme
  without pasting it, never give the final answer unasked, and say nothing until you tap. The hint on the
  question screen also reflects your handwriting.
- **Failure looks like**: "nothing readable", generic answers that ignore your working, or the final answer given away.
- **Automated by**: `PracticeWorkTests/theTutorSeesTheQuestionAndSchemeFirst`; the replies: manual.

### TEST-DEV-036: Your work groups your attempts and opens them again
- **Feature**: Develop → Your work, the Up next card, three stats
- **Priority**: high
- **Coverage**: auto-tested (grouping, trend, tries, stats); the screen: not tested
- **Platforms**: iPad, Mac, iPhone
- **Preconditions**: a few marked questions from two papers, one question done twice.
- **Steps**:
  1. Open Develop. Look at the top: the Up next card, then this week / days in a row / recent average.
  2. In Your work, open a topic, then another; close the first.
  3. On an attempt, tap the working button, then go back and tap Try again.
- **Expected**: topics are folded until tapped, each with its average ring, count and when; the
  question done twice says "try 1 of 2" / "try 2 of 2"; the working opens; Try again starts that
  question on a fresh page. Nothing jumps or lags when a topic opens.
- **Failure looks like**: all attempts shown at once, wrong grouping, a working that won't open.
- **Automated by**: `PracticeWorkTests`, `PracticeStatsTests`; the screen: manual.

### TEST-HOME-001: The app opens on Home
- **Feature**: Home (docs/prompts/practice-space-home.md; changed 2026-11-05 by learn-pivot plan §4 B2)
- **Priority**: high
- **Coverage**: UI test `testLibraryScrollsAndShows` checks it opens on Home (Up next) and screenshots it
- **Platforms**: iPhone (Home tab), iPad and Mac (Home at the top of the sidebar)
- **Steps**:
  1. Launch the app.
  2. Tap Start in Up next; come back. Tap the due cards button if there is one.
  3. Tap Continue; tap a card under Jump back in; tap New note, New sketch and Import at the bottom.
- **Expected**: Home shows the greeting and the next goal date, Up next (one small session and due cards; with
  no course, "What are you learning?"), three numbers (after some practice), Continue, Jump back in, Pinned, and
  the three small buttons; each does what it says.
- **Failure looks like**: the app opens on Recent or notes, a button does nothing, or the shelf lags while scrolling.
- **Automated by**: `TroveUITests.testLibraryScrollsAndShows` (opening only), `testLearnComesSecond`; the rest: manual.

### TEST-DEV-037: A question shows only itself, with its context
- **Feature**: splitting v2 (tight crops, lead-ins, stems; PaperSplitter.version 2)
- **Priority**: critical
- **Coverage**: auto-tested (`TightSplitTests`, `DevelopTests` regions); on real papers: not tested
- **Platforms**: all
- **Preconditions**: a paper split before this change (it's split again on launch), e.g. a BPhO paper with
  "Question 1", parts "c)" and "(i)", marks "(10)".
- **Steps**:
  1. Open the app and wait a moment; Develop → Practise.
  2. Look at a part like 1 c): the picture, then the same part in its working sketch.
- **Expected**: the question's opening text (its stem) on top, then any paragraph that introduces this
  part, then the part itself down to its marks. No other parts, no previous part's end, no answer lines or
  blank space, no page margins. A diagram inside the part is kept.
- **Failure looks like**: the whole page, another part's text, a lost diagram, or the stem missing.
- **Automated by**: `TightSplitTests`, `DevelopTests/aPaperSplitsIntoQuestionsWithMarksAndMatchesItsScheme`.

### TEST-DEV-038: How everyone did, from the examiner report
- **Feature**: national-cohort comparison (study-with-friends prompt §1; `ExaminerReport`, `CohortLine`)
- **Priority**: normal
- **Coverage**: auto-tested (`ExaminerReportTests`, made-up text in each board's layout); on two real AQA
  reports (GCSE Physics 8463/1H, A-level Physics 7408/1, June 2025) by `TROVE_REPORTS`: 32 and 14 questions
  with figures, each checked by eye; real OCR, Pearson and Cambridge reports had no per-question figures.
  In the app: not tested.
- **Platforms**: all
- **Preconditions**: an AQA course with a paper and its examiner report downloaded (e.g. GCSE Physics 8463,
  June 2025 Paper 1 Higher).
- **Steps**:
  1. Learn → Practise a question from that paper; mark it (self-marked against the scheme, or by AI).
  2. Look under the result. Then do a part the report says nothing numeric about (e.g. 01.2 there), and a
     question from an OCR or Pearson paper.
- **Expected**: under "How everyone did", the report's own sentence ("Just over 50% of the students scored
  1 mark") with "AQA examiner report, June 2025"; for a part with no figure, "The AQA examiner report, June
  2025 gives no figure for this question."; nothing at all for a skipped question, an own course or a paper
  without a report. Never a number the report doesn't print.
- **Failure looks like**: a figure on the wrong part, a made-up average, or a pause after marking.
- **Automated by**: `ExaminerReportTests`.

### TEST-DEV-039: Study with friends: a challenge from start to results (with a friend)
- **Feature**: study groups in Learn (`FriendsCard`, `GroupScreen`, `ChallengeScreen`, `GroupFlow`)
- **Priority**: high
- **Coverage**: the flow is auto-tested in TroveCore against `wrangler dev` (`twoVaultsStudyTogether`: create,
  invite, challenge, no peeking, self/AI/peer marking, remove, leave); the screens: not tested.
- **Platforms**: iPhone, iPad, Mac (two people, each with their own vault on the same relay)
- **Preconditions**: both have added the same course (e.g. AQA GCSE Physics 8463) and downloaded a paper.
- **Steps**:
  1. You: Learn → Study with friends → Start a group; name it and yourself. Make an invite link; send it.
  2. Friend: tap the link (it opens the relay's page → Open in Trove), or paste it in Learn → Join with a link.
  3. You: New challenge → the paper → whole paper or a few questions → by a date → Send.
  4. Both: open the challenge → Start; mark one answer yourself against the scheme, one with AI (if set up),
     leave one unmarked; Hand in. Before your friend hands in, look at the challenge.
  5. After both hand in: compare answers per question; mark your friend's unmarked answer (Mark this answer).
  6. Friend: see "Marked by …" on that answer and tap Accept.
- **Expected**: before handing in you see only "1 handed in", never their answers. After: each question shows
  both answers with marks, time, hints and how each was marked; a total each; no ranking. The accepted mark
  shows in the friend's practice as a new attempt. Nothing of either person's uploads is shared.
- **Failure looks like**: answers visible before handing in, a mark with no "how marked", or a peer mark
  changing practice without Accept.
- **Automated by**: `StudyGroupTests` (flow), `groups.test.ts` (relay rules); the screens: manual.

### TEST-DEV-040: Study with friends: live mode
- **Feature**: live challenges (the group's socket while its screen is open)
- **Priority**: normal
- **Coverage**: relay socket auto-tested (`groups.test.ts` "tells members' open sockets…"); in the app: not tested.
- **Platforms**: two devices
- **Steps**: make a Live challenge; both open it; one taps "Start for everyone in 10 seconds".
- **Expected**: the other device shows the countdown within a couple of seconds without pulling to refresh, then Go.
- **Failure looks like**: the other device only sees it after reopening the group.
- **Automated by**: manual.
