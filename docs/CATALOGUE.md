# The paper catalogue

Develop's past papers come from the exam boards' own websites. The catalogue is **links and facts only**
(board, qualification, subject, spec code, paper, tier, series, year, URL); Trove never hosts a board's
paper. A device downloads the papers you choose straight from the board's site, on Wi-Fi only. Since
2026-11-04 (your call: "can't it technically count as an upload") a paper you download is also kept in
your own trove, like an upload, so your other devices get it from there (PROTOCOL.md: `paper.<doc id>`
items); the switch "Sync downloaded papers to my other devices" on a course turns that off. Your **own
uploads** (anything else: competition papers, other boards, worksheets) are items in your trove too.

## Coverage

GCSE, IGCSE and AS/A-level (and International AS & A Level), every subject each board lists:

| Board | Read from | What's public |
|---|---|---|
| AQA | the search service behind aqa.org.uk's past-paper finder (`/api/search`, scope `findPastPapers`) | every series AQA publishes; papers, mark schemes, examiner reports, inserts |
| OCR | each qualification's Assessment page on ocr.org.uk | the series OCR publishes; the newest are only on Teach Cambridge for teachers |
| Eduqas, WJEC | each qualification page's Past papers tab (`/umbraco/surface/TabSurface/GetpastpapersTab`) | papers and mark schemes on pastpapers.download.wjec.co.uk |
| Cambridge International | each IGCSE and International AS & A Level syllabus's past-papers page | one recent series and the specimen papers; the rest are on School Support Hub for schools |
| Pearson Edexcel | the search service behind qualifications.pearson.com's past-paper finder, with the search-only key its page gives every visitor (read from the page each run; the user's choice, 2026-11-04) | GCSE, International GCSE, AS/A level, International AS & A Level: the series Pearson makes public (files under `/content/dam/pdf/`); the newest are under `/content/dam/secure/` behind a Pearson login and are left out. Legacy specs (no public paper since 2019, or replaced: 4CH0 → 4CH1, IAL 2013 → 2018) are left out |
| CCEA | not yet | tested 2026-11-04 with an honest request (Trove's own User-Agent): Cloudflare answers 403 "Your IP or Country has been blocked by CCEA" for the page and even robots.txt. It's an IP/country block on cloud machines (GitHub Actions would be the same), not a script filter, so it isn't worked around (no proxies). Open: ask CCEA, or an in-app browser on your own device |

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
numbers inside the text ("5.6 × 10⁻³") stay text. Checked on real papers from AQA, OCR, Eduqas, WJEC, Cambridge and Pearson
(TEST-CUR-004): totals match the paper's or come within a few marks. A paper with numbered questions but no marks printed (multiple choice: Cambridge's Paper 1, OCR's
section A) gets 1 mark a question. Papers with no numbered questions (essays, listening) are reported, not split. Pearson's papers need three things more, all in the splitter: the vertical "DO NOT WRITE IN THIS AREA" down each page edge is ignored, a page number at the foot is not a question, and a question with no part marks takes its "(Total for Question 3 is 1 mark)". Your uploads with no readable text
(photos, scans) become one question per page.

## Terms

The user's call (2026-11-04): linking to the boards' public papers is fine, because Trove only links and
each device downloads from the board; terms are no longer a gate for adding a board. Before any public
launch, get legal advice and the boards' permission (NOTES.md decision 12).
