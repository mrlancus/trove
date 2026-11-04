# Curriculum and campaigns (CUR)

## Still planned
Concept mapping from specifications, required versus supplementary content, changing a campaign's
deadline and reassessing. Their tests are added here when they're built.

## Built: the paper catalogue (every board that can be read; docs/CATALOGUE.md)

### TEST-CUR-001: The catalogue is links on board sites only
- **Feature**: Catalogue
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: `catalogue/index.json` and `catalogue/specs/` (built by `scripts/catalogue/build.py`).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
  2. `python3 scripts/check-catalogue.py catalogue --sample 400`.
- **Expected**: every document URL of every spec is on its own board's site (AQA: aqa.org.uk or its file store cdn.sanity.io; OCR, WJEC/Eduqas, Cambridge: their own domains), never a mirror such as PMT; ids unique in each spec; the index carries no documents; each question paper finds its mark scheme and report (option papers by title); the source line reads "AQA 7408/2 June 2023 Q4.2"; the sample of links answers 200.
- **Failure looks like**: a third-party URL, a duplicate id, a missing companion, broken links.
- **Automated by**: `DevelopTests/theCatalogueIsLinksOnBoardSitesOnly`; links: `scripts/check-catalogue.py` (every Monday in `.github/workflows/catalogue.yml`).

### TEST-CUR-002: A campaign: diagnostic first, then what slips, never what's safe
- **Feature**: CampaignPlanner, Goals
- **Priority**: high
- **Coverage**: auto-tested (planner); app: implemented
- **Platforms**: core; all apps
- **Preconditions**: a few attempts on some skills.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter CampaignTests`.
  2. (You) Develop → New goal → Fill in myself → a name, a date 9 days ahead, a Physics course → Add; on its card tap "15 min".
  3. Practise the first day's skills (Start); reopen Develop.
- **Expected**: day 1 starts with skills not assessed yet ("first check"); at most 1 question a day at 15 minutes (about 8 minutes each); a proficient, remembered skill never appears; the sentence says how many skills are shown; after practising, the plan changes.
- **Failure looks like**: a skill you've shown repeatedly filling the plan, more problems than the time allows.
- **Automated by**: `CampaignTests/diagnosticFirstThenWhatSlipsAndNeverWhatsSafe`; app: manual.

### TEST-CUR-003: The catalogue rebuilds itself from the boards every week
- **Feature**: Catalogue finders
- **Priority**: high
- **Coverage**: implemented (CI)
- **Platforms**: CI
- **Preconditions**: none.
- **Steps**:
  1. GitHub → Actions → Catalogue → Run workflow.
  2. When it's done, look at the latest commit on main.
- **Expected**: the rebuild job reads AQA, OCR, Eduqas, WJEC and Cambridge and either says "No changes" or commits "Catalogue: weekly rebuild…" with only `catalogue/` changed; a board whose site was down keeps its previous files; the links job passes.
- **Failure looks like**: a board's specs vanishing after one bad week, a commit touching anything outside `catalogue/`.
- **Automated by**: `.github/workflows/catalogue.yml` (Mondays 04:17 UTC).

### TEST-CUR-004: Every board's real papers split into marked questions
- **Feature**: PaperSplitter (board layout or the generic one, whichever finds more marks)
- **Priority**: critical
- **Coverage**: auto-tested (fixtures); real papers: run on demand
- **Platforms**: core
- **Preconditions**: `pdftotext` (poppler) for the real-paper run.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter "GenericSplitTests|DevelopTests"`.
  2. `python3 scripts/catalogue/split-sample.py /tmp/papers aqa-7408 aqa-8300 aqa-8463 ocr-h556 ocr-j249 eduqas-a420 wjec-1420 wjec-3420 cie-9702 cie-0625`
  3. `TROVE_SPLIT_LINES=/tmp/papers swift test --filter RealPaperSplitTests` and read the SPLIT lines.
- **Expected**: "1 (a) (i)", "1(b)(ii)", "2. (a)" and AQA's "0 1 . 1" all become questions (1.1.1, 1.2.2, 2.1, 1.1) with their marks; each part carries the stem above it; page numbers and "5.6 × 10⁻³" at the margin stay text; each paper's marks add up to (or close to) its total.
- **Failure looks like**: a paper giving a handful of huge questions, keys out of order, totals far off.
- **Automated by**: `GenericSplitTests`, `RealPaperSplitTests` (needs the folder; the papers are never committed).

### TEST-CUR-005: Courses: choose them once, they're on every device
- **Feature**: Develop → Your courses
- **Priority**: critical
- **Coverage**: auto-tested (records); app: implemented
- **Platforms**: core; all apps
- **Preconditions**: two devices on the same trove.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter CourseTests`.
  2. (You) Device A: Develop → Add a course → A-level → search "chem" → pick one (e.g. OCR A-level Chemistry A).
  3. Pick a GCSE one too (e.g. AQA GCSE Physics), and an IGCSE one (Cambridge).
  4. Device B: open Develop after syncing.
  5. On A, long-press a course → Remove course.
- **Expected**: the picker lists subjects by level with board, spec code, number of papers and years; search finds by subject, board or code; Pearson Edexcel and CCEA are named as not listed yet, with uploads offered instead; the courses appear on B with no papers downloaded there ("0 of N papers on this device"); removing on A removes on B.
- **Failure looks like**: a course only on one device, the picker empty (catalogue not bundled), a crash on a spec with no papers.
- **Automated by**: `CourseTests/coursesSyncAndRemovingKeepsTheRecord`; app: manual.

### TEST-CUR-006: A goal made by talking it through: the AI asks until it's sure
- **Feature**: Develop → New goal (with your AI)
- **Priority**: high
- **Coverage**: auto-tested (prompt and parsing); app: implemented
- **Platforms**: core; all apps
- **Preconditions**: your AI set up (Settings → AI); a course or two added.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter GoalTests`.
  2. (You) Develop → New goal → type something vague: "physics next summer".
  3. Answer its questions, by tapping an option or typing.
  4. When it shows the goal, check it; tap Not quite once and correct something; then Add goal.
- **Expected**: one short question at a time with 2–4 tappable answers (board, which papers, the date…); it never fills in a date you didn't give (a "ready" goal without a date turns back into "When is it?"); at most 6 questions; the proposal names the course from your courses (or one from the catalogue, which is then added to your courses), papers, target and a one-line summary saying what it assumed; Settings → AI → Activity shows one small "Setting up a goal" row per answer.
- **Failure looks like**: it proposes straight away from a vague sentence, invents a date, picks a course not in the catalogue, asks more than 6 questions.
- **Automated by**: `GoalTests/theAIAsksUntilItKnowsAndNeverGuessesTheDate`; app: manual.

### TEST-CUR-007: Goals can be edited and removed; time changes day to day
- **Feature**: goal card
- **Priority**: high
- **Coverage**: auto-tested (records, planning); app: implemented
- **Platforms**: core; all apps
- **Preconditions**: a goal with a course whose papers are downloaded (TEST-DEV-020).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter GoalTests`.
  2. (You) On the goal's card tap "1 h": Today's line changes (about 7 questions); tap Start.
  3. Tomorrow, open Develop: the card asks "How long have you got today?" again (yesterday's choice is the default for the plan).
  4. ⋯ → Edit goal: change the date and papers → Save. ⋯ → Remove goal.
  5. Check a second device after syncing.
- **Expected**: the card shows a readiness ring, the days left, papers and target chips; Start gives that many questions from the goal's courses only; edits and the removal appear on the other device.
- **Failure looks like**: a fixed "30 minutes a day" you can't change, Start picking questions from another subject, a removed goal coming back.
- **Automated by**: `GoalTests/todaysTimeSizesTodayAndBecomesTheUsual`; app: manual.
