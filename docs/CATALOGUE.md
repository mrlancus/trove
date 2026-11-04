# The paper catalogue

Develop's past papers come from the exam boards' own websites. Trove keeps **links and facts only**
(board, qualification, subject, spec code, paper, tier, series, year, URL); it never hosts, copies or
syncs a board's paper. Each device downloads the papers you choose straight from the board's site,
on Wi-Fi only, into a local cache. Your **own uploads** (anything else: competition papers, other
boards, worksheets) are different: they're items in your trove and sync to every device.

## Coverage

GCSE, IGCSE and AS/A-level (and International AS & A Level), every subject each board lists:

| Board | Read from | What's public |
|---|---|---|
| AQA | the search service behind aqa.org.uk's past-paper finder (`/api/search`, scope `findPastPapers`) | every series AQA publishes; papers, mark schemes, examiner reports, inserts |
| OCR | each qualification's Assessment page on ocr.org.uk | the series OCR publishes; the newest are only on Teach Cambridge for teachers |
| Eduqas, WJEC | each qualification page's Past papers tab (`/umbraco/surface/TabSurface/GetpastpapersTab`) | papers and mark schemes on pastpapers.download.wjec.co.uk |
| Cambridge International | each IGCSE and International AS & A Level syllabus's past-papers page | one recent series and the specimen papers; the rest are on School Support Hub for schools |
| Pearson Edexcel | the hosted search behind Pearson's past-paper finder (the search-only key the finder page gives every visitor, read from the page on each run) | GCSE, International GCSE, AS/A level and International A level papers, mark schemes and examiner reports that are public on qualifications.pearson.com; the newest series need a Pearson login (`/content/dam/secure/`) and are left out, as are specs with nothing since 2019 |
| CCEA | not yet | its website blocks automated requests; not worked around |

Modified (large-print, braille) papers, sound files, transcripts and confidential instructions are left out.

## Files

- `catalogue/index.json`: boards (with AQA's own question-number layout), the boards not listed and
  why, and one summary per spec: id, board, qualification, subject, code, level (`gcse`, `igcse`,
  `alevel`), its page, how many question papers, first and last year. No documents.
- `catalogue/specs/<spec id>.json`: that spec's documents. Ids are stable
  (`aqa-7408-2-2023-06-qp`, `ocr-j249-1-h-2023-06-ms`); problems point at `cat:<doc id>`, so an id never
  changes once published. Papers sharing a number (History's options) get their title in the id.

The apps bundle the folder as a fallback and fetch newer copies from this repo
(`raw.githubusercontent.com/mrlancus/trove/main/catalogue/`) at most once a day, and a spec's file only
when you add that course.

## Building

```bash
python3 scripts/catalogue/build.py            # every board (~15 minutes; polite, one request at a time)
python3 scripts/catalogue/build.py aqa ocr    # just these
python3 scripts/check-catalogue.py catalogue --sample 400
```

`.github/workflows/catalogue.yml` rebuilds every Monday and commits `catalogue/` if anything changed,
then checks a sample of links. A board whose site fails keeps its previous files, so a bad week never
empties it.

## Splitting papers into questions

`PaperSplitter.splitBest` tries the board's own layout (AQA's sciences print "0 1 . 1") and the generic
one ("1 (a) (i)", "1(b)(ii)", "2. (a)", marks "[2]" or "[2 marks]") and keeps whichever finds more marks.
Parts on their own line belong to the question above; each part carries its stem; page numbers and
numbers inside the text ("5.6 × 10⁻³") stay text. Checked on real papers from AQA, OCR, Eduqas, WJEC and Cambridge
(TEST-CUR-004): totals match the paper's or come within a few marks. A paper with numbered questions but no marks printed (multiple choice: Cambridge's Paper 1, OCR's
section A) gets 1 mark a question. Papers with no numbered questions (essays, listening) are reported, not split. Your uploads with no readable text
(photos, scans) become one question per page.

## Terms

The user's call (2026-11-04): linking to the boards' public papers is fine, because Trove only links and
each device downloads from the board; terms are no longer a gate for adding a board. Before any public
launch, get legal advice and the boards' permission (NOTES.md decision 12).
