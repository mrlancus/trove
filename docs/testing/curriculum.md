# Curriculum and campaigns (CUR)

## planned: specifications, the paper catalogue, past papers and mark schemes, campaigns
Not built yet (DEVELOP_PLAN §D phases 1–4). The catalogue's format and parser land in Develop's first
slice; their tests are added here in the same commit. When built, the tests must cover: choosing a
board and specification version; concept mapping; required versus supplementary content; importing
past papers (downloaded from the board, cancellable, on Wi-Fi); marking against a mark scheme;
creating a campaign, changing its deadline, re-planning after a diagnostic, reassessing; missing or
uncertain curriculum data (a broken link shows "Unavailable" and blocks nothing).

## Built: the paper catalogue's format (TroveCore)

### TEST-CUR-001: The catalogue is links on board sites only
- **Feature**: Catalogue
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: `catalogue/papers.json`.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: every document URL is on aqa.org.uk (never a mirror such as PMT); each question paper finds its mark scheme and examiner report; the source line reads "AQA 7408/2 June 2023 Q4.2"; ids unique.
- **Failure looks like**: a third-party URL, a missing companion.
- **Automated by**: `DevelopTests/theCatalogueIsLinksOnBoardSitesOnly`; links live: checked by HEAD on 2026-11-03 (and every week by `.github/workflows/catalogue.yml`, `scripts/check-catalogue.py`).
