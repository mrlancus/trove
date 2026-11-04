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
  2. (You) Develop → Prepare for… → a name, a date 9 days ahead, 16 minutes a day → Add.
  3. Practise the first day's skills; reopen Develop.
- **Expected**: day 1 starts with skills not assessed yet ("first check"); at most 2 problems a day at 16 minutes; a proficient, remembered skill never appears; the sentence says how many skills are shown; after practising, the plan changes.
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
