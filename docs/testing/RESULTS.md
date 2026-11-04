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
| 2026-11-03 | Mac app tests (TroveTests: DiagnosticsTests 3, PerformanceTests 4) | 203fbfd, Apple apps run 137 | macOS 15 runner, Xcode 26.3 | CI | pass | 7 tests; perf.json: materialiseSmall 380 ms, searchKeyP90Small 17.1 ms (before L1), trovegenSmall 6.5 s |
| 2026-11-03 | UI tests (TroveUITests) on iPhone SE, iPhone 16 Pro Max, iPad mini, iPad Air 13-inch | 203fbfd, run 137 | iOS simulators, Xcode 26.3 | CI | fail | the app opened the generated vault (Notes 1,333, Sketches 2) and search worked, but the tests looked for the notebook on the first screen; testLaunchTime passed (iPhone SE). Tests fixed to navigate; UI_AUDIT U1–U7 from the screenshots |
| 2026-11-04 | TroveCore suite (incl. SearchEngineEquivalenceTests, DevelopMarkingTests) | 5b97c68 | Linux x86-64, Swift 6.3.1 | Claude | pass | 237 tests |
| 2026-11-04 | web unit + interop | 5b97c68 | Linux, Node | Claude | pass | 73 tests |
| 2026-11-04 | relay tests | 5b97c68 | Linux, Node (Workers runtime) | Claude | pass | 59 tests |
| 2026-11-04 | website e2e (`npm run test:e2e`, local relay + Chromium) | before the PDF fix | Linux, Chromium 1243 | Claude | fail | 24 of 25: pdf.e2e.mjs (TEST-PDF-002) fails here too, so not flaky but a real bug |
| 2026-11-04 | website e2e, all 25 incl. TEST-PDF-002 | PDF selection fix | Linux, Chromium 1243 | Claude | pass | 25/25 |
| 2026-11-04 | browser extension tests | 5b97c68 | Linux, Node | Claude | pass | 2 tests |
| 2026-11-04 | Apple apps build with Develop's screens | b85c164 | macOS 15 runner, Xcode 26.3 | CI | pass | macOS + iOS compiled first time |
| 2026-11-04 | TroveCore suite incl. AnkiPackageTests (TEST-CARD-011), DevelopHintTests (TEST-DEV-027) | before push | Linux x86-64, Swift 6.3.1 | Claude | pass | with 239 tests |
| 2026-11-04 | Apple apps build with Pencil answers, hints, .apkg, goals, your own PDFs, off-main search | d1961da, run 146 | macOS 15 runner, Xcode 26.3 | CI | pass | macOS + iOS; published as latest |
| 2026-11-04 | UI tests (TroveUITests) on 4 simulators | d1961da, run 146 | iOS simulators, Xcode 26.3 | CI | fail | 16 passed: Develop (3 devices), notes scrolling, notebook, rotation, search on iPhones; failed: search on iPads (toolbar field focus, test fixed), launch-time metric (test fixed), iPad mini simulator couldn't launch or stop the app (CI simulator, not Trove) |
| 2026-11-04 | Mac app tests (TroveTests) | d1961da, run 146 | macOS 15 runner | CI | pass | 7/7 |
