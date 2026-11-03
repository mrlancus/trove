# Test results (append-only)

One row per run. Never edit an old row; a re-run is a new row. Who: `Claude` (cloud session), `CI`
(GitHub Actions, with the run), or `you`.

| Date | Test | Build | Device and OS | Who | Result | Notes |
|---|---|---|---|---|---|---|
| 2026-11-03 | TroveCore suite (all `@Test`s, incl. every TroveCore test named in these files) | 678ea6c | Linux x86-64, Ubuntu 24.04, Swift 6.3.1 | Claude | pass | 211 tests |
| 2026-11-03 | TroveCore suite | f35b51d (local, before push) | Linux x86-64, Ubuntu 24.04, Swift 6.3.1 | Claude | pass | 219 tests (adds TroveGen, page index, ink-by-item) |
| 2026-11-03 | web unit + interop (`npm test`) | 7e79930 | Linux, Node | Claude | pass | 71 tests |
| 2026-11-03 | TEST-PERF-001 | bb65fc5 | Linux x86-64 VM, release | Claude | fail | p90 65.0 ms vs 5 ms budget (PERF_AUDIT B3); was 102.0 ms |
| 2026-11-03 | TEST-PERF-002 | bb65fc5 | Linux x86-64 VM, release | Claude | pass | 0.5 ms (was 113.0 ms) |
| 2026-11-03 | Apple apps build (TroveCore tests on macOS) | bb65fc5, run 132 | macOS 15 runner, Xcode 26.3 | CI | fail | a test expression too complex for Xcode's type checker; fixed in f35b51d |
| 2026-11-03 | website e2e `pdf.e2e.mjs` (TEST-PDF-002) | 3230952 and 7e79930, Tests runs 52–53 | ubuntu-latest, Chromium | CI | fail | flaky: Quote button not found within 30 s; failed on a NOTES-only commit too, passed at 678ea6c. Bug: NOTES.md "Known bugs" |
| 2026-11-03 | TroveCore suite incl. TEST-DEV-001–012, TEST-GRAPH-010–012, TEST-CUR-001, TEST-CARD-010 (`DevelopTests`, 14 tests) | Develop slice commit | Linux x86-64, Ubuntu 24.04, Swift 6.3.1 | Claude | pass | 233 tests |
| 2026-11-03 | web unit incl. `develop.test.mjs` (TEST-DEV-001, 003) | Develop slice commit | Linux, Node | Claude | pass | 73 tests |
| 2026-11-03 | catalogue links (TEST-CUR-001) | after 222109b | Linux, Python 3 | Claude | pass | 20 links, 0 broken (`scripts/check-catalogue.py`) |
| 2026-11-03 | relay tests (`server`, vitest on the Workers runtime) incl. metered tokens | after 9c1c8c9 | Linux, Node | Claude | pass | 59 tests; tsc clean |
| 2026-11-03 | TEST-PERF-001 | L1 commit | Linux x86-64 VM, release | Claude | fail | p90 28.1 ms (was 65.0); results identical (SearchEngineEquivalenceTests pass) |
