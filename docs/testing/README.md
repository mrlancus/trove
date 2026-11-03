# Trove test checklist

The checklists in this folder are what we run; `RESULTS.md` is what happened each time. Written from
what the code does on `main` (2026-11-03). A feature that's planned but not built has a `planned`
heading in its file and no tests yet; its tests come in the same commit as the feature.

## How to use it
1. After every reinstall (every 7 days with a free Apple ID) run **`SMOKE.md`**: at most 25 critical
   tests, under 30 minutes.
2. Before a release build, run **`regression.md`**.
3. When a test is run, add **one row to `RESULTS.md`** (never edit old rows): date, test ID, build
   (commit, plus the CI run for app builds), device and OS, who ran it, result, notes or bug link.
4. A failing test keeps its coverage level; its RESULTS row links to the bug (a GitHub issue or a
   line in NOTES.md "Known bugs").

## Evidence words (exactly these)
Coverage of a test or feature:
- `implemented`: the code exists and nothing has been run yet.
- `auto-tested`: an automated test covers it and passes on Linux, in CI or in Playwright (the test is named).
- `manually tested`: a person ran it on a simulator or the website.
- `device-verified`: run on a physical device (device and OS in RESULTS.md).
- `not tested`

A run's result: `pass`, `fail` or `blocked` (couldn't run; say why). Never record a pass because the
code looks right. Anything that needs a physical device (Pencil, palm rejection, real iCloud between
your devices, installs, GoodNotes on the iPad, battery, the share sheet, keyboards, microphone and
camera permissions) is run by you, and each such test says so.

## Test format
`TEST-<CODE>-NNN` (never renumbered; retire a test with "Retired:" instead). Fields: Feature,
Priority (critical/high/medium/low), Coverage, Platforms, Preconditions, Steps, Expected, Failure
looks like, Automated by (a real test, or `manual`).

## Area codes
| File | Code | File | Code |
|---|---|---|---|
| `capture.md` | CAP | `curriculum.md` | CUR |
| `notes.md` | NOTE | `flashcards-anki.md` | CARD |
| `notebooks.md` (incl. handwriting) | NB, HW | `sync-privacy.md` | SYNC |
| `pdf-images.md` | PDF | `performance.md` | PERF |
| `graph.md` | GRAPH | `responsive.md` | RESP |
| `ai.md` | AI | `failure.md` | FAIL |
| `develop.md` | DEV | `regression.md` | REG |

## Device matrix
| Device | OS | Screen | Who runs it | Used for |
|---|---|---|---|---|
| iPhone 14 | iOS (read it from Settings → Battery → Export diagnostics) | 60 Hz, 6.1" | you | the slowest device: sets the bar |
| iPad Air (M-series) + Apple Pencil | iPadOS | 60 Hz, 10.9"/11" | you | Pencil, Apple Intelligence, Develop's first device |
| Intel MacBook Pro | macOS 15+ | laptop + external display | you | the Mac's worst case |
| iPhone SE, iPhone Pro Max, iPad mini, 13-inch iPad simulators | newest iOS on the CI runner | — | CI (`scripts/ci-app-tests.sh`) | UI tests, screenshots |
| macOS runner | newest macOS on GitHub | — | CI | Mac unit and performance tests |
| Linux (cloud session / CI) | Ubuntu 24.04 | — | Claude, CI | TroveCore, relay, web unit tests |
| Chromium (Playwright) | — | 360–1920 px | Claude, CI | website e2e |

## Test data
- **trove-gen** (`TroveGen.Size`): `tiny` (unit tests), `small` (2k items, 2k clips, 40-page notebook,
  2k-stroke whiteboard, 10 PDFs, a 60-page PDF; UI tests), `full` (50k items, 50k clips, 500 pages ×
  200 strokes, 10k-stroke whiteboard, 200 PDFs, a 500-page PDF; benchmarks). Debug builds open one
  with the launch argument `-TroveTestVault small` (never your vault). Seed 42 unless stated.
- Fixtures in `Packages/TroveCore/Tests/TroveCoreTests/Fixtures` (shared with the website).
- Things only you have: your vault, GoodNotes notebooks, real PDFs. Tests that need them say so.
